defmodule Api.Notifications.Fanout do
  @moduledoc """
  Resolve **quem** recebe cada notificação e a grava (doc 31 §2). É a regra de negócio da caixa,
  reunida num lugar em vez de espalhada pelos notifiers — o `Api.Notifications.Notifier` é só a
  cola Ash que chama daqui.

  Três invariantes do doc 31 §2 valem para todo caminho:

    * **Por usuário** — cada notificação tem um `recipient_id`; nunca se escreve "para a clínica".
    * **Recorte por papel** — o `profissional` só é notificado da própria coluna (o destinatário
      da agenda é o usuário dono do `professional_id` do bloco); o operacional da fila e a
      governança vão para `recepcao`/`admin`/`owner`.
    * **Suprime o autor** — quem causou o evento não se notifica (ele já teve o toast). O
      `actor` vem do notifier; se for o próprio destinatário, pula.

  Tudo aqui é **best-effort e pós-commit**: roda depois que o evento de origem já persistiu, então
  uma falha ao notificar não desfaz nada (e é engolida no `Notifier`). As leituras de `Membership`
  são de sistema (`authorize?: false`) — a caixa é montada pelo servidor, não pela sessão.
  """
  require Logger

  alias Api.Notifications
  alias Api.Scheduling.LocalTime

  @operacional [:owner, :admin, :recepcao]
  @governanca [:owner, :admin]

  # ---- Ciclo de vida do agendamento → o profissional dono da coluna ----

  @doc """
  Notifica o profissional dono da coluna quando **outra pessoa** mexe num bloco dele
  (agendar/remarcar/cancelar). Sem profissional vinculado a um usuário, ou quando o autor é o
  próprio dono, não gera nada.
  """
  def appointment_touched(appointment, action_name, actor)
      when action_name in [:schedule, :reschedule, :cancel] do
    recipient_id = professional_user_id(appointment.clinic_id, appointment.professional_id)

    if deliver?(recipient_id, actor) do
      # A clínica (o fuso) é lida UMA vez por notificação — o título/corpo e o `date` derivam do
      # mesmo `tz`, sem reler `load_clinic` em cada um.
      tz = clinic_timezone(appointment.clinic_id)
      {title, body} = appointment_text(action_name, when_str(appointment.starts_at, tz))

      notify(appointment.clinic_id, recipient_id, kind_for(action_name), title, body, %{
        appointment_id: appointment.id,
        date: local_date_iso(appointment.starts_at, tz),
        actor: actor_payload(actor)
      })
    end

    :ok
  end

  def appointment_touched(_appointment, _action_name, _actor), do: :ok

  @doc """
  Notifica o profissional dono da coluna quando **um participante falta** (#46, doc 31 §3a; A2:
  a falta é da presença, não do bloco — numa turma um pode faltar e o outro não).

  Recebe a `Attendance` que acabou de virar `:faltou`; o bloco (coluna, horário) é lido a partir
  dela, `authorize?: false` como o resto do fan-out. Autor suprimido: na prática dispara quando a
  recepção marca a falta na agenda do profissional, que é o caso em que ele precisa saber.

  **A ordem das cláusulas é o conserto do bate-volta**: o teste barato (existe algum profissional
  com usuário nesta clínica? — 1 query) vem antes do caro (ler o bloco, que abre transação própria
  e custa 4). Numa clínica sem vínculo profissional↔usuário — o caso comum da clínica pequena —
  eram 4 idas ao banco jogadas fora **por clique**, no caminho mais clicado da agenda.
  """
  def participant_missed(attendance, actor) do
    with donos when donos != %{} <- professional_users(attendance.clinic_id),
         %{} = appointment <- load_appointment(attendance),
         recipient_id when not is_nil(recipient_id) <-
           Map.get(donos, appointment.professional_id),
         true <- deliver?(recipient_id, actor) do
      tz = clinic_timezone(attendance.clinic_id)
      paciente = patient_name(attendance)

      notify(
        attendance.clinic_id,
        recipient_id,
        :appointment_missed,
        "Falta registrada",
        "#{paciente} faltou na sessão de #{when_str(appointment.starts_at, tz)}.",
        %{
          appointment_id: appointment.id,
          patient_id: attendance.patient_id,
          date: local_date_iso(appointment.starts_at, tz),
          actor: actor_payload(actor)
        }
      )
    end

    :ok
  end

  @doc """
  Notifica o profissional dono da coluna quando alguém **entra numa turma** dele (#47, doc 31
  §3a). Uma notificação por escrita, não por participante: entrar com três de uma vez é um
  evento só para quem lê.
  """
  def participant_added(appointment, actor) do
    recipient_id = professional_user_id(appointment.clinic_id, appointment.professional_id)

    if deliver?(recipient_id, actor) do
      tz = clinic_timezone(appointment.clinic_id)

      notify(
        appointment.clinic_id,
        recipient_id,
        :participant_added,
        "Novo participante na turma",
        "Alguém entrou na turma de #{when_str(appointment.starts_at, tz)}.",
        %{
          appointment_id: appointment.id,
          date: local_date_iso(appointment.starts_at, tz),
          actor: actor_payload(actor)
        }
      )
    end

    :ok
  end

  # ---- Falta/cancelamento que abre vaga com fila casando → recepção/admin/owner ----

  @doc """
  Quando uma escrita abre a vaga `(professional_id, starts_at, ends_at)` e há paciente na fila que
  **cabe** (`who_fits`), avisa quem preenche vaga (operacional). Silencioso quando a fila está vazia
  ou ninguém casa — é o que separa o sinal de valor do ruído.

  **Quem** decide que a vaga abriu é o `Api.Notifications.Notifier` (só ele tem o changeset para
  comparar o status anterior); aqui a pergunta já está respondida.
  """
  def slot_maybe_opened(appointment, actor) do
    with %{} = scope <- system_scope(appointment.clinic_id, actor),
         count when count > 0 <- candidate_count(scope, appointment) do
      tz = clinic_timezone(appointment.clinic_id)
      recipients = role_user_ids(appointment.clinic_id, @operacional) -- suppress(actor)
      {title, body} = slot_opened_text(when_str(appointment.starts_at, tz), count)

      for recipient_id <- Enum.uniq(recipients) do
        notify(appointment.clinic_id, recipient_id, :slot_opened, title, body, %{
          appointment_id: appointment.id,
          professional_id: appointment.professional_id,
          date: local_date_iso(appointment.starts_at, tz),
          candidates: count
        })
      end
    end

    :ok
  end

  # ---- Convite aceito → owner/admin ----

  @doc "Avisa owner/admin da clínica que um convidado aceitou e entrou (menos o próprio recém-chegado)."
  def member_joined(membership) do
    clinic_id = membership.clinic_id
    nome = user_name(membership.user_id)
    recipients = role_user_ids(clinic_id, @governanca) -- [membership.user_id]

    for recipient_id <- Enum.uniq(recipients) do
      notify(
        clinic_id,
        recipient_id,
        :member_joined,
        "Novo membro na equipe",
        "#{nome} entrou na clínica como #{papel_label(membership.papel)}.",
        %{user_id: membership.user_id, papel: to_string(membership.papel)}
      )
    end

    :ok
  end

  # ---- Gravação ----

  defp notify(clinic_id, recipient_id, kind, title, body, data) do
    with {:ok, notification} <-
           Notifications.create_notification(
             %{recipient_id: recipient_id, kind: kind, title: title, body: body, data: data},
             tenant: clinic_id,
             authorize?: false
           ) do
      # Faz o badge do sino subir sem refresh (doc 31 §5). Pós-commit da própria criação.
      Api.Notifications.Feed.broadcast_new(notification)
      {:ok, notification}
    end
  rescue
    error ->
      Logger.error("Fanout: falha ao gravar notificação #{kind}: #{Exception.message(error)}")
      :error
  end

  # ---- Destinatários (leituras de sistema em Membership, que é global) ----

  # O usuário dono de um `professional_id` na clínica (o vínculo `Membership.professional_id`).
  defp professional_user_id(clinic_id, professional_id) when is_binary(professional_id) do
    active_memberships(clinic_id)
    |> Enum.find(&(&1.professional_id == professional_id))
    |> case do
      %{user_id: user_id} -> user_id
      _ -> nil
    end
  end

  defp professional_user_id(_clinic_id, _professional_id), do: nil

  # `professional_id => user_id` de quem tem vínculo ativo — a pergunta barata que decide se vale
  # a pena ler o bloco (ver `participant_missed/2`). Mapa vazio = ninguém para notificar.
  defp professional_users(clinic_id) do
    active_memberships(clinic_id)
    |> Enum.reject(&is_nil(&1.professional_id))
    |> Map.new(&{&1.professional_id, &1.user_id})
  end

  defp role_user_ids(clinic_id, roles) do
    active_memberships(clinic_id)
    |> Enum.filter(&(&1.papel in roles))
    |> Enum.map(& &1.user_id)
  end

  defp active_memberships(clinic_id) do
    Api.Accounts.list_memberships!(
      query: [filter: [clinic_id: clinic_id, status: :ativo]],
      authorize?: false
    )
  end

  # O bloco de uma presença, para saber de quem é a coluna e a que horas. `nil` se sumiu (o
  # fan-out é best-effort e pós-commit — não é ele que decide se a escrita valeu).
  defp load_appointment(%{clinic_id: clinic_id, appointment_id: appointment_id}) do
    Api.Repo.with_clinic(clinic_id, fn ->
      Api.Scheduling.get_appointment(appointment_id,
        tenant: clinic_id,
        authorize?: false,
        not_found_error?: false
      )
    end)
    |> case do
      {:ok, {:ok, %{} = appointment}} -> appointment
      _ -> nil
    end
  end

  defp patient_name(%{clinic_id: clinic_id, patient_id: patient_id}) do
    Api.Repo.with_clinic(clinic_id, fn ->
      Api.Records.get_patient(patient_id,
        tenant: clinic_id,
        authorize?: false,
        not_found_error?: false
      )
    end)
    |> case do
      {:ok, {:ok, %{nome: nome}}} when is_binary(nome) -> nome
      _ -> "Um paciente"
    end
  end

  defp user_name(user_id) do
    case Api.Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      %{nome: nome} when is_binary(nome) -> nome
      _ -> "Um novo membro"
    end
  end

  # ---- "quem cabe" para o slot_opened ----

  defp candidate_count(scope, appointment) do
    length(
      Api.Waitlist.who_fits(
        scope,
        appointment.professional_id,
        appointment.starts_at,
        appointment.ends_at
      )
    )
  rescue
    _ -> 0
  end

  # Escopo de sistema a partir do autor: o `who_fits` precisa de tenant + actor com autoridade de
  # membro. O autor do cancelamento é membro da clínica, então seu membership serve de escopo.
  defp system_scope(clinic_id, %{id: user_id} = actor) do
    case Api.Accounts.get_active_membership(user_id, clinic_id,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{} = membership} -> Api.Scope.with_membership(actor, membership)
      _ -> nil
    end
  end

  defp system_scope(_clinic_id, _actor), do: nil

  # ---- Textos ----

  defp appointment_text(:schedule, when_string),
    do: {"Novo agendamento na sua agenda", "Um agendamento foi adicionado em #{when_string}."}

  defp appointment_text(:reschedule, when_string),
    do:
      {"Agendamento remarcado", "Um agendamento na sua agenda foi remarcado para #{when_string}."}

  defp appointment_text(:cancel, when_string),
    do: {"Agendamento cancelado", "O agendamento de #{when_string} foi cancelado."}

  defp slot_opened_text(when_string, count) do
    {"Vaga livre na agenda",
     "Uma vaga abriu em #{when_string} — #{count} #{pluralize(count, "paciente da fila cabe", "pacientes da fila cabem")} aqui."}
  end

  defp kind_for(:schedule), do: :appointment_scheduled
  defp kind_for(:reschedule), do: :appointment_rescheduled
  defp kind_for(:cancel), do: :appointment_canceled

  # ---- Utilidades ----

  defp deliver?(nil, _actor), do: false
  defp deliver?(recipient_id, %{id: actor_id}), do: recipient_id != actor_id
  defp deliver?(recipient_id, _actor) when is_binary(recipient_id), do: true

  defp suppress(%{id: actor_id}), do: [actor_id]
  defp suppress(_actor), do: []

  defp when_str(%DateTime{} = starts_at, tz) do
    date = LocalTime.to_local_date(starts_at, tz)
    hora = LocalTime.from_minutes(LocalTime.to_local_minutes(starts_at, tz))
    "#{fmt_date(date)} às #{hora}"
  end

  defp local_date_iso(%DateTime{} = starts_at, tz) do
    starts_at |> LocalTime.to_local_date(tz) |> Date.to_iso8601()
  end

  defp clinic_timezone(clinic_id), do: Api.Scheduling.clinic_timezone(clinic_id)

  defp fmt_date(%Date{day: day, month: month}), do: "#{pad(day)}/#{pad(month)}"
  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  defp papel_label(:owner), do: "proprietário(a)"
  defp papel_label(:admin), do: "administrador(a)"
  defp papel_label(:profissional), do: "profissional"
  defp papel_label(:recepcao), do: "recepção"

  defp actor_payload(%{id: id, nome: nome}), do: %{id: id, nome: nome}
  defp actor_payload(_actor), do: nil
end
