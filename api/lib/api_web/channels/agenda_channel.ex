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

  Por isso o evento interno carrega só o **id**, e cada canal resolve com o **escopo do seu
  assinante**. Quem não pode ler não recebe nada, e a regra não é reimplementada aqui — sai de
  `Api.Scheduling.Preparations.OwnAgendaOnly`, a mesma autoridade da leitura HTTP e da escrita.

  ## `block` × `signal`: o que o assinante pediu no `join`

  Nem todo assinante quer o bloco. **Dia** e **Lista** desenham o bloco e o remendam no store;
  **Semana** e **Mês** desenham *contagem* — para elas o evento é um "recarregue a contagem
  daquele dia", e o bloco cheio era payload de outra ordem de grandeza para redesenhar uma
  barrinha (doc 25 §10).

  A versão anterior tratava isso só na saída: **todo** assinante pagava a releitura completa e
  o do Mês jogava o resultado fora — 6 queries para um sinal de dois campos (D-G/D-H do doc 30).
  Agora o `join` declara o modo (`params["mode"]`), e ele decide o caminho:

    * `block` — relê o bloco com o escopo do assinante (`load_visible_appointment/2`) e empurra
      o recurso serializado. A releitura resolve, de quebra, o **sidecar de pacientes**: um
      bloco novo pode citar um paciente que o cliente não tem no mapa da janela carregada, e sem
      o nome ele apareceria como "Paciente" genérico;
    * `signal` — não lê o bloco. Pergunta ao `OwnAgendaOnly` **se** este assinante enxerga
      aquele profissional (custo zero: a membership já veio carregada no `join`) e empurra
      `agenda_changed`.

  O default preserva o contrato antigo para cliente que não mande `mode`: tópico de mês é
  sinal, tópico de dia é bloco. O tópico do mês **ignora** `mode: block` — a resolução dele não
  tem bloco para empurrar, e aceitar o pedido seria devolver payload que o cliente não desenha.

  O recorte A7 vale igual nos dois modos: no `signal` o que se suprime é o aviso, não só o
  conteúdo — senão o profissional deduziria, pelo "recarregue o dia", que existe algo na agenda
  do colega.
  """
  use Phoenix.Channel

  alias Api.Scheduling
  alias Api.Scheduling.AgendaNotifier
  alias Api.Scheduling.Preparations.OwnAgendaOnly

  @impl true
  def join(topic, params, socket) do
    with {:ok, clinic_id, resolucao} <- parse_topic(topic),
         :ok <- same_clinic(clinic_id, socket),
         {:ok, scope} <- scope_for(socket.assigns.user_id, clinic_id) do
      AgendaNotifier.subscribe(internal_topic(clinic_id, resolucao))

      socket =
        socket
        |> assign(:scope, scope)
        |> assign(:resolucao, resolucao)
        |> assign(:mode, mode(resolucao, params))

      {:ok, socket}
    else
      :invalid_topic -> {:error, %{reason: "invalid_topic"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  # Sinal: nada de releitura. Só a pergunta do recorte, respondida da membership que o `join`
  # já carregou — e um `agenda_changed` com o dia a recarregar.
  @impl true
  def handle_info({:agenda_event, evento}, %{assigns: %{mode: :signal}} = socket) do
    if visivel?(socket.assigns.scope, evento) do
      push(socket, "agenda_changed", %{day: Date.to_iso8601(evento.date), change: "count"})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agenda_event, evento}, socket) do
    case Scheduling.load_visible_appointment(socket.assigns.scope, evento.appointment_id) do
      nil -> {:noreply, socket}
      visivel -> {:noreply, push_event(socket, evento, visivel)}
    end
  end

  # A7 no caminho do sinal. `:sem_vinculo` não acontece por aqui (o `join` exigiu membership
  # ativa e o escopo a carregou do banco), mas se acontecer é **fail-closed**: sem vínculo
  # resolvível, nada é empurrado. É o oposto do default de `prepare/3`, onde a mesma resposta
  # significa "chamada interna, sem fronteira a guardar".
  defp visivel?(scope, evento) do
    case OwnAgendaOnly.recorte(scope.user, scope.clinic_id, %{context: %{scope: scope}}) do
      :clinica_inteira -> true
      {:so_este_profissional, id} -> id in evento.professional_ids
      _ -> false
    end
  end

  # O tópico do mês é sinal por definição — a célula mostra contagem e ocupação, não bloco.
  # Pedir `block` nele não é erro do cliente a ponto de recusar o `join`; é pedido que não se
  # aplica àquela resolução.
  defp mode({:month, _date}, _params), do: :signal
  defp mode(_resolucao, %{"mode" => "signal"}), do: :signal
  defp mode(_resolucao, _params), do: :block

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
