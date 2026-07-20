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

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: name},
        data: %{} = appointment,
        actor: actor
      })
      when name in [:schedule, :add_participant] do
    date = local_date(appointment)

    payload = %{
      event: event_name(name),
      appointment_id: appointment.id,
      clinic_id: appointment.clinic_id,
      date: date,
      actor: actor_payload(actor)
    }

    broadcast(day_topic(appointment.clinic_id, date), payload)
    broadcast(month_topic(appointment.clinic_id, date), payload)

    :ok
  end

  @impl true
  def notify(_notification), do: :ok

  # O dia é o **local da clínica** (ADR-009): um bloco às 21h de São Paulo é 00:00Z do dia
  # seguinte, e publicá-lo no tópico do dia UTC o faria sumir da tela de quem está no dia certo.
  defp local_date(appointment) do
    clinic = Api.Scheduling.load_clinic(appointment.clinic_id)
    LocalTime.to_local_date(appointment.starts_at, clinic.timezone)
  end

  defp broadcast(topic, payload),
    do: Phoenix.PubSub.broadcast(Api.PubSub, topic, {:agenda_event, payload})

  # Os nomes são os do contrato 09 §7.2 — o cliente casa por eles.
  defp event_name(:schedule), do: "appointment_scheduled"
  defp event_name(:add_participant), do: "participant_added"

  defp actor_payload(%{id: id, nome: nome}), do: %{id: id, nome: nome}
  defp actor_payload(_), do: nil

  defp month_key(%Date{year: year, month: month}),
    do: "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"
end
