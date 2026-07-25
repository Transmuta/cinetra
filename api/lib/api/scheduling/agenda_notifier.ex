defmodule Api.Scheduling.AgendaNotifier do
  @moduledoc """
  Publica as mutações de agenda no `Phoenix.PubSub` (RN-56, doc 04 §6.1). O `Ash.Notifier`
  roda **depois do commit** — é o próprio Ash quem segura a notificação até a transação do
  recurso fechar —, então nenhum assinante enxerga um bloco que a transação ainda vai desfazer.

  ## Dois broadcasts por escrita, e por quê

  A visão Mês assinaria 31 tópicos de dia para desenhar 31 barrinhas. Por isso toda escrita
  publica em **duas resoluções**: o tópico do dia e o tópico do mês. O que muda é o que o
  canal faz com cada um (bloco cheio × sinal leve), não o que este módulo publica — a mensagem
  é a mesma nos dois, e é o `ApiWeb.AgendaChannel` que sabe em qual resolução entrou.

  ## O que trafega é o id, não o bloco

  A mensagem interna carrega `appointment_id`, não o registro serializado. Quem resolve o
  bloco é o canal, **relendo com o escopo de cada assinante** — é o que faz o recorte A7 (o
  papel `profissional` só vê a própria agenda) valer também no push, sem reescrever o filtro
  de `OwnAgendaOnly` aqui. Ver `ApiWeb.AgendaChannel`.

  O contrato de wire (payload cheio no evento do dia) continua o do doc 09 §7.2: ele é montado
  no canal, na fronteira, como todo o resto do JSON do projeto.
  """
  use Ash.Notifier

  alias Api.Scheduling.LocalTime

  @doc "Tópico interno de um dia. Fonte única — o canal assina pelo mesmo caminho."
  def day_topic(clinic_id, %Date{} = date),
    do: "agenda_events:#{clinic_id}:#{Date.to_iso8601(date)}"

  @doc "Tópico interno de um mês."
  def month_topic(clinic_id, %Date{} = date),
    do: "agenda_events:#{clinic_id}:month:#{month_key(date)}"

  @doc "Assina um tópico interno (o canal chama no `join`)."
  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(Api.PubSub, topic)

  # As ações que viram evento de tempo real. O ciclo de vida (Entrega 4) entra aqui: o cliente
  # casa pelo nome do evento e ignora o que não conhece, então acrescentá-las não mexe no que a
  # Entrega 3 já fazia.
  @lifecycle [
    :schedule,
    :add_participant,
    :remove_participant,
    :reschedule,
    :cancel,
    :reopen,
    :exclude,
    # A2: presença por participante rola o desfecho pro bloco (doc 41). O cliente relê o bloco
    # (novo status + presenças) no mesmo evento de status.
    :apply_participant_rollup
  ]

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: name},
        data: %{} = appointment,
        changeset: changeset,
        actor: actor
      })
      when name in @lifecycle do
    # Só o fuso, e do cache (D-K): o notifier roda em TODA escrita da agenda, e era um PK-hit
    # na `clinics` por bloco criado/movido/fechado.
    tz = Api.Scheduling.clinic_timezone(appointment.clinic_id)
    new_date = local_date(appointment, tz)

    payload = %{
      event: event_name(name),
      appointment_id: appointment.id,
      clinic_id: appointment.clinic_id,
      date: new_date,
      # De quem é a agenda que mudou. Não vai para o cliente: é o que deixa o canal responder
      # o recorte A7 do modo `signal` sem reler o bloco (D-G/D-H). São **dois** quando uma
      # remarcação troca de profissional — a coluna de origem também mudou de contagem.
      professional_ids: affected_professionals(appointment, changeset),
      actor: actor_payload(actor)
    }

    # Remarcar entre dias emite em **dois** tópicos de dia (doc 25 §9, risco da Entrega 3):
    # o de destino recebe o bloco; o de **origem** também, senão o bloco fantasma fica lá até
    # um refresh (o cliente o remove ao ver que a data mudou). Os demais eventos afetam só o
    # dia atual do bloco.
    for date <- affected_dates(name, appointment, changeset, tz, new_date) |> Enum.uniq() do
      day_payload = %{payload | date: date}
      broadcast(day_topic(appointment.clinic_id, date), day_payload)
      broadcast(month_topic(appointment.clinic_id, date), day_payload)
    end

    :ok
  end

  @impl true
  def notify(_notification), do: :ok

  defp affected_dates(
         :reschedule,
         _appointment,
         %Ash.Changeset{data: %{starts_at: old}},
         tz,
         new_date
       )
       when not is_nil(old) do
    [local_date_from(old, tz), new_date]
  end

  defp affected_dates(_name, _appointment, _changeset, _tz, new_date), do: [new_date]

  # Mesma lógica dos dois dias, aplicada à coluna: remarcar entre profissionais tira o bloco de
  # uma agenda e põe na outra, então as duas mudaram de contagem.
  defp affected_professionals(appointment, %Ash.Changeset{data: %{professional_id: anterior}})
       when not is_nil(anterior),
       do: Enum.uniq([anterior, appointment.professional_id])

  defp affected_professionals(appointment, _changeset), do: [appointment.professional_id]

  # O dia é o **local da clínica** (ADR-009): um bloco às 21h de São Paulo é 00:00Z do dia
  # seguinte, e publicá-lo no tópico do dia UTC o faria sumir da tela de quem está no dia certo.
  defp local_date(appointment, tz),
    do: local_date_from(appointment.starts_at, tz)

  defp local_date_from(starts_at, tz),
    do: LocalTime.to_local_date(starts_at, tz)

  defp broadcast(topic, payload),
    do: Phoenix.PubSub.broadcast(Api.PubSub, topic, {:agenda_event, payload})

  # Os nomes são os do contrato 09 §7.2 — o cliente casa por eles.
  defp event_name(:schedule), do: "appointment_scheduled"
  defp event_name(:add_participant), do: "participant_added"
  defp event_name(:remove_participant), do: "participant_removed"
  defp event_name(:reschedule), do: "appointment_rescheduled"
  defp event_name(:cancel), do: "appointment_canceled"

  # Soft-delete (doc 40): o canal NÃO relê o bloco (o `prepare` o esconde) — empurra a REMOÇÃO
  # do id. Ver `ApiWeb.AgendaChannel`.
  defp event_name(:exclude), do: "appointment_excluded"

  defp event_name(name) when name in [:reopen, :apply_participant_rollup],
    do: "appointment_status_changed"

  defp actor_payload(%{id: id, nome: nome}), do: %{id: id, nome: nome}
  defp actor_payload(_), do: nil

  defp month_key(%Date{year: year, month: month}),
    do: "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"
end
