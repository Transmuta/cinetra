defmodule ApiWeb.AgendaChannel do
  @moduledoc """
  O canal da agenda (contrato 09 §7, Entrega 3). Tópicos, verbatim do doc 04 §6.1:

      clinic:<clinic_id>:agenda:<YYYY-MM-DD>     # dia e semana — bloco cheio
      clinic:<clinic_id>:agenda:month:<YYYY-MM>  # mês — sinal leve de invalidação

  ## As duas guardas do `join`

  1. **O `clinic_id` do tópico é conferido contra o do token.** Sem isso, qualquer sessão
     autenticada pediria o tópico de outra clínica e receberia a agenda inteira dela — um
     vazamento que não passa nem pela policy do recurso nem pela RLS do Postgres, porque o
     WebSocket não atravessa nenhuma das duas.
  2. **O vínculo é relido do banco.** O token vale 15 minutos; quem teve o acesso revogado
     nesse intervalo ainda tem um token criptograficamente válido na mão.

  ## O recorte A7 acontece por assinante, não por tópico

  O tópico é da clínica inteira, mas o papel `profissional` só pode ver a própria agenda —
  é o que `Api.Scheduling.Preparations.OwnAgendaOnly` garante na leitura HTTP. Se o canal
  empurrasse o payload que veio do PubSub, o recorte valeria no REST e não valeria no
  WebSocket: a mesma regra com duas respostas, que é a classe de bug que o doc 26 achou entre
  leitura e escrita.

  Por isso o evento interno carrega só o **id**, e cada canal relê o bloco com o **escopo do
  seu assinante** (`load_visible_appointment/2`). Quem não pode ler não recebe nada, e a regra
  não é reimplementada aqui — é a mesma preparation, pelo mesmo caminho. Correto por
  construção, ao custo de uma leitura por assinante por escrita.

  A releitura resolve, de quebra, o **sidecar de pacientes**: um bloco novo pode citar um
  paciente que o cliente não tem no mapa da janela carregada, e sem o nome o bloco apareceria
  como "Paciente" genérico.
  """
  use Phoenix.Channel

  alias Api.Scheduling
  alias Api.Scheduling.AgendaNotifier

  @impl true
  def join(topic, _params, socket) do
    with {:ok, clinic_id, resolucao} <- parse_topic(topic),
         :ok <- same_clinic(clinic_id, socket),
         {:ok, scope} <- scope_for(socket.assigns.user_id, clinic_id) do
      AgendaNotifier.subscribe(internal_topic(clinic_id, resolucao))
      {:ok, socket |> assign(:scope, scope) |> assign(:resolucao, resolucao)}
    else
      :invalid_topic -> {:error, %{reason: "invalid_topic"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:agenda_event, evento}, socket) do
    case Scheduling.load_visible_appointment(socket.assigns.scope, evento.appointment_id) do
      nil -> {:noreply, socket}
      visivel -> {:noreply, push_event(socket, evento, visivel)}
    end
  end

  # Mês: sinal leve. A célula mostra contagem e ocupação, não bloco — mandar o agendamento
  # inteiro seria transportar payload de outra ordem de grandeza para redesenhar uma barrinha
  # (doc 25 §10). O cliente recarrega a contagem daquele dia.
  defp push_event(%{assigns: %{resolucao: {:month, _}}} = socket, evento, _visivel) do
    push(socket, "agenda_changed", %{day: Date.to_iso8601(evento.date), change: "count"})
    socket
  end

  # Dia e semana: evento semântico com o recurso serializado (doc 04 §6.2), pela **mesma**
  # serialização do `GET /api/appointments` — o cliente aplica patch no store sem saber por
  # qual porta o bloco chegou.
  defp push_event(socket, evento, %{appointment: appointment, patients: patients}) do
    push(socket, evento.event, %{
      appointment: ApiWeb.AgendaJSON.appointment(appointment),
      patients: Enum.map(patients, &ApiWeb.AgendaJSON.patient/1),
      actor: evento.actor
    })

    socket
  end

  defp parse_topic("clinic:" <> resto) do
    case String.split(resto, ":") do
      [clinic_id, "agenda", "month", mes] -> with_date(clinic_id, :month, "#{mes}-01")
      [clinic_id, "agenda", dia] -> with_date(clinic_id, :day, dia)
      _ -> :invalid_topic
    end
  end

  defp parse_topic(_topic), do: :invalid_topic

  defp with_date(clinic_id, resolucao, iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {:ok, clinic_id, {resolucao, date}}
      _ -> :invalid_topic
    end
  end

  defp same_clinic(clinic_id, %{assigns: %{clinic_id: clinic_id}}), do: :ok
  defp same_clinic(_clinic_id, _socket), do: :error

  # A mesma pergunta que o `LoadScope` faz na fronteira HTTP, feita ao mesmo lugar: existe
  # vínculo **ativo** deste usuário com esta clínica? O papel sai daqui, nunca do token.
  defp scope_for(user_id, clinic_id) do
    with {:ok, user} <- Api.Accounts.get_user(user_id, authorize?: false),
         {:ok, membership} <-
           Api.Accounts.get_active_membership(user_id, clinic_id, authorize?: false) do
      {:ok, Api.Scope.with_membership(user, membership)}
    else
      _ -> :error
    end
  end

  defp internal_topic(clinic_id, {:day, date}), do: AgendaNotifier.day_topic(clinic_id, date)
  defp internal_topic(clinic_id, {:month, date}), do: AgendaNotifier.month_topic(clinic_id, date)
end
