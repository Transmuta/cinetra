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

  @doc """
  A massa por pacote em **uma** notificação por profissional afetado (doc 43 §5b).

  A massa remarca N sessões numa transação só. Sem isto, cada sessão reinserida disparava um
  `:appointment_scheduled` — *"Novo agendamento na sua agenda"* ×40 num pacote de 40, para o que é
  um evento só, e dizendo "novo" sobre sessão que foi **movida**. As notificações por sessão são
  suprimidas na origem (o `Api.Notifications.Notifier` reconhece a marca de lote no contexto do
  changeset); esta as substitui.

  `professional_ids` são as colunas tocadas — antes e depois, porque mudar de profissional mexe na
  agenda dos dois. Cada dono de coluna recebe uma linha; o autor segue suprimido, como em todo o
  fan-out.
  """
  def package_bulk_adjusted(clinic_id, professional_ids, pacote_nome, afetadas, actor) do
    massa(clinic_id, professional_ids, pacote_nome, afetadas, actor, :package_bulk_adjusted)
  end

  @doc """
  O mesmo para o **cancelamento** em massa (doc 66 §5, item 3).

  Existia só a metade de cima: as por-sessão eram suprimidas pela marca de lote e o `cancel` nunca
  teve o aviso único que o `adjust` tem. Cancelar um pacote de 40 sessões não punha nada na caixa
  do dono da coluna — a agenda dele esvaziava em silêncio.

  Ficou visível quando o paciente passou a ser avisado (doc 65): quem ia à sessão sabia, e quem ia
  atender, não.
  """
  def package_bulk_canceled(clinic_id, professional_ids, pacote_nome, afetadas, actor) do
    massa(clinic_id, professional_ids, pacote_nome, afetadas, actor, :package_bulk_canceled)
  end

  # As duas massas são o mesmo fan-out com outro verbo: mesmos destinatários (os donos das colunas
  # tocadas), mesma supressão de autor, mesma contagem no corpo. Separá-las em duas funções
  # inteiras deixaria duas cópias de "quem recebe" — e é justamente a regra de destinatário que
  # muda com o tempo.
  defp massa(clinic_id, professional_ids, pacote_nome, afetadas, actor, kind)
       when is_integer(afetadas) and afetadas > 0 do
    donos = professional_users(clinic_id)

    recipients =
      professional_ids
      |> Enum.uniq()
      |> Enum.map(&Map.get(donos, &1))
      |> Enum.filter(&deliver?(&1, actor))
      |> Enum.uniq()

    {title, verbo} = massa_texto(kind)

    for recipient_id <- recipients do
      notify(
        clinic_id,
        recipient_id,
        kind,
        title,
        "#{Api.Texto.sessoes(afetadas)} do pacote #{pacote_nome} " <>
          "#{Api.Texto.foram(afetadas)} #{verbo}.",
        %{afetadas: afetadas, pacote: pacote_nome, actor: actor_payload(actor)}
      )
    end

    :ok
  end

  defp massa(_clinic_id, _ids, _nome, _afetadas, _actor, _kind), do: :ok

  defp massa_texto(:package_bulk_adjusted), do: {"Sessões de pacote remarcadas", "remarcadas"}
  defp massa_texto(:package_bulk_canceled), do: {"Sessões de pacote canceladas", "canceladas"}

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

  # ---- Resposta do paciente (doc 65 §5) → recepção/admin/owner ----

  @doc """
  O paciente respondeu **"preciso remarcar"** no link da mensagem (doc 52 §5).

  Vai ao operacional, que é quem remarca — não ao profissional dono da coluna: ele não opera a
  agenda, e para ele isto seria aviso sem ação (o aviso dele vem depois, quando a recepção de fato
  remarcar, pelo `:appointment_rescheduled` que já existe).

  **Sem supressão de autor**, e é a única do fan-out assim: o autor é o paciente, que não tem
  login nem caixa. `deliver?/2` compararia o destinatário com um `nil` e deixaria passar — mas
  depender disso seria depender de acidente, então a lista de destinatários é montada direto.

  Best-effort e pós-commit como todo o resto: a resposta do paciente já está gravada, e ela não
  pode cair porque a caixa de alguém falhou.
  """
  def patient_wants_reschedule(%{clinic_id: clinic_id} = message) do
    tz = clinic_timezone(clinic_id)
    paciente = patient_name(message)

    # O bloco é lido **uma vez** — dele saem o texto e a data do payload. Lê-lo por campo abriria
    # duas transações para responder a mesma pergunta, no caminho de uma rota pública.
    #
    # E é do bloco que o horário sai, não de `vars`: aquilo guarda o horário renderizado no envio,
    # e se a sessão tiver sido remarcada nesse meio-tempo o aviso apontaria para um horário que
    # não existe mais.
    {quando, data} =
      case load_appointment(message) do
        %{starts_at: starts_at} -> {when_str(starts_at, tz), local_date_iso(starts_at, tz)}
        _ -> {"uma sessão", nil}
      end

    for recipient_id <- Enum.uniq(role_user_ids(clinic_id, @operacional)) do
      notify(
        clinic_id,
        recipient_id,
        :patient_wants_reschedule,
        "Paciente pediu remarcação",
        "#{paciente} pediu para remarcar a sessão de #{quando}.",
        %{
          appointment_id: message.appointment_id,
          patient_id: message.patient_id,
          date: data
        }
      )
    end

    :ok
  end

  # ---- Lembretes por relógio (#51) ----

  @doc """
  "Você tem N atendimentos amanhã" (#51, doc 31 §3d).

  Sem supressão de autor: não há autor — o evento é o relógio. E sem notificação quando `n` é
  zero: o valor do resumo é dizer que **há** dia; "você não tem nada amanhã" é ruído diário.
  """
  def daily_digest(clinic_id, recipient_id, %Date{} = data, quantos) when quantos > 0 do
    notify(
      clinic_id,
      recipient_id,
      :daily_digest,
      "Sua agenda de amanhã",
      "Você tem #{quantos} #{atendimentos(quantos)} amanhã, #{fmt_date(data)}.",
      %{date: Date.to_iso8601(data), total: quantos}
    )

    :ok
  end

  def daily_digest(_clinic_id, _recipient_id, _data, _quantos), do: :ok

  @doc """
  "Sua próxima sessão começa às HH:MM" (#51, doc 31 §3d).

  O texto diz a **hora**, não "em 15 minutos", e isso é de propósito: o cron roda a cada 5
  minutos sobre uma janela, então "15 minutos" seria uma imprecisão escrita na cara do usuário
  enquanto o horário é sempre exato.
  """
  def session_soon(clinic_id, recipient_id, %{id: id, starts_at: %DateTime{} = starts_at}, tz) do
    hora = LocalTime.from_minutes(LocalTime.to_local_minutes(starts_at, tz))

    notify(
      clinic_id,
      recipient_id,
      :session_soon,
      "Sessão começando",
      "Sua próxima sessão começa às #{hora}.",
      # Recebe o BLOCO, não só o instante, porque o `appointment_id` é o que deixa o sino abrir a
      # sessão de que ele fala — e não a agenda do dia, onde ela ainda tem de ser procurada. É o
      # aviso mais imediato do conjunto: quem o lê está a 15 minutos de atender.
      %{appointment_id: id, date: local_date_iso(starts_at, tz), hora: hora}
    )

    :ok
  end

  defp atendimentos(1), do: "atendimento"
  defp atendimentos(_), do: "atendimentos"

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

  @doc """
  Avisa **o próprio membro** que o papel dele mudou (#50, doc 31 §3c).

  É o único evento da caixa cujo destinatário é o alvo da ação, e não um terceiro: mexer no papel
  mexe no que a pessoa pode fazer, e ela descobriria sozinha só ao esbarrar num botão que sumiu.
  O autor segue suprimido — quem se promove já sabe.
  """
  def role_changed(membership, papel_anterior, actor) do
    if papel_anterior != membership.papel and deliver?(membership.user_id, actor) do
      notify(
        membership.clinic_id,
        membership.user_id,
        :role_changed,
        "Seu acesso mudou",
        "Seu papel nesta clínica agora é #{papel_label(membership.papel)}.",
        %{
          papel: to_string(membership.papel),
          papel_anterior: to_string(papel_anterior),
          actor: actor_payload(actor)
        }
      )
    end

    :ok
  end

  @doc """
  Avisa owner/admin que alguém **saiu da equipe** (#50) — o par de `member_joined/1`.

  O removido não recebe nada, e isso é estrutural, não esquecimento: a caixa é por-tenant e só se
  lê com vínculo ativo na clínica. Assim que o vínculo cai, aquela caixa fica inalcançável para
  ele — avisar por lá seria escrever numa gaveta trancada. Dar essa notícia a quem saiu é
  trabalho de e-mail, que o doc 31 §5 deixou fora da v1 de propósito.
  """
  def member_removed(membership, actor) do
    clinic_id = membership.clinic_id
    nome = user_name(membership.user_id)

    recipients =
      role_user_ids(clinic_id, @governanca) -- ([membership.user_id] -- suppress(actor))

    for recipient_id <- Enum.uniq(recipients) do
      notify(
        clinic_id,
        recipient_id,
        :member_removed,
        "Membro removido da equipe",
        "#{nome} não faz mais parte desta clínica.",
        %{user_id: membership.user_id, actor: actor_payload(actor)}
      )
    end

    :ok
  end

  @doc """
  Avisa o operacional que entrou na fila alguém marcado **`urgente`** (#48, doc 31 §3b).

  O limiar é só o topo da prioridade — decisão de 2026-07-26 sobre o gate #3 do doc 35. `alta`
  ficou de fora porque em clínica movimentada ela é frequente, e o custo de um sino que apita
  demais não é o volume: é o usuário parar de olhar para ele (doc 31 §4).
  """
  def waitlist_urgent(entry, actor) do
    recipients = role_user_ids(entry.clinic_id, @operacional) -- suppress(actor)
    paciente = patient_name(entry)

    for recipient_id <- Enum.uniq(recipients) do
      notify(
        entry.clinic_id,
        recipient_id,
        :waitlist_urgent,
        "Paciente urgente na fila",
        "#{paciente} entrou na fila de espera como urgente.",
        %{
          entry_id: entry.id,
          patient_id: entry.patient_id,
          actor: actor_payload(actor)
        }
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

  @doc """
  `professional_id => user_id` de quem tem vínculo ativo — a pergunta barata que decide se vale
  a pena ler o bloco (ver `participant_missed/2`). Mapa vazio = ninguém para notificar.

  Público desde o #51: os lembretes por cron fazem a mesma pergunta antes de varrer a agenda,
  e tê-la em dois lugares seria ter duas definições de "dono da coluna".
  """
  def professional_users(clinic_id) do
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

  # `get_user/2` é code interface NÃO-bang: devolve `{:ok, %User{}}`. Casar contra `%{nome: nome}`
  # nunca dava match e o fallback virava o único caminho — todo aviso de equipe dizia "Um novo
  # membro" (doc 96, B-2). O `patient_name/1` logo acima já desembrulhava certo.
  defp user_name(user_id) do
    case Api.Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
      {:ok, %{nome: nome}} when is_binary(nome) -> nome
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
