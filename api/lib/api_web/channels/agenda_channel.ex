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
  alias ApiWeb.ChannelScope

  @impl true
  def join(topic, params, socket) do
    with {:ok, clinic_id, resolucao} <- parse_topic(topic),
         {:ok, scope} <- ChannelScope.authorize(clinic_id, socket) do
      AgendaNotifier.subscribe(internal_topic(clinic_id, resolucao))

      modo = mode(resolucao, params)

      socket =
        socket
        |> assign(:scope, scope)
        |> assign(:resolucao, resolucao)
        |> assign(:mode, modo)

      if rastreia_presenca?(resolucao, modo), do: send(self(), :after_join)

      {:ok, socket}
    else
      :invalid_topic -> {:error, %{reason: "invalid_topic"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  # F5 — "quem está vendo este dia" (09 §7.4). Rastreia depois do `join`, não dentro dele: o
  # `Presence.track/3` precisa do processo do canal já registrado no tópico.
  #
  # A chave é o **usuário**, não o socket: duas abas da mesma pessoa são uma pessoa na tela, e é
  # o `Presence` que junta os metas sob a mesma chave. O nome sai do vínculo lido no `join` —
  # nunca do corpo do cliente, como na fila (doc 39).
  @impl true
  def handle_info(:after_join, socket) do
    %{user: user} = socket.assigns.scope

    {:ok, _ref} = ApiWeb.Presence.track(socket, user.id, %{user_id: user.id, nome: user.nome})

    # Quem já estava aqui antes de eu entrar. Sem isto, só se descobre no próximo `presence_diff`
    # — ou seja, nunca, se ninguém mexer.
    push(socket, "presence_state", ApiWeb.Presence.list(socket))
    {:noreply, socket}
  end

  # Sinal: nada de releitura. Só a pergunta do recorte, respondida da membership que o `join`
  # já carregou — e um `agenda_changed` com o dia a recarregar.
  @impl true
  def handle_info({:agenda_event, evento}, %{assigns: %{mode: :signal}} = socket) do
    entregue(:signal, false)

    if visivel?(socket.assigns.scope, evento) do
      push(socket, "agenda_changed", %{day: Date.to_iso8601(evento.date), change: "count"})
    end

    {:noreply, socket}
  end

  # Soft-delete (doc 40) no modo `block`: relê o bloco NÃO resolve — o `prepare` de
  # `excluded_at IS NULL` já o esconde, então `load_visible_appointment` devolveria `nil` e o
  # bloco ficaria fantasma na tela até um refresh (é o buraco que o `case nil` abaixo tem para
  # todo evento). Em vez de reler, empurra a REMOÇÃO do id — gated pelo mesmo recorte A7 do
  # sinal: quem não podia ver o bloco não recebe (e para quem nunca o teve seria no-op de
  # qualquer forma). Semana/Mês caem no clause de cima (`mode: :signal`) e recarregam a contagem.
  @impl true
  def handle_info({:agenda_event, %{event: "appointment_excluded"} = evento}, socket) do
    entregue(:block, false)

    if visivel?(socket.assigns.scope, evento) do
      push(socket, "appointment_excluded", %{appointment_id: evento.appointment_id})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agenda_event, evento}, socket) do
    entregue(:block, true)

    case medir_releitura(socket.assigns.scope, evento.appointment_id) do
      nil -> {:noreply, socket}
      visivel -> {:noreply, push_event(socket, evento, visivel)}
    end
  end

  # ---- a instrumentação do M6 (doc 101) ----
  #
  # O achado: o canal relê o bloco do banco **uma vez por assinante, por evento**, e o
  # `bloco_load()` traz subconsulta correlacionada e agregado com sort. Isso escala com
  # assinantes × eventos, não com o dado.
  #
  # A decisão registrada no plano foi **não mexer ainda, e medir** — e ela continua certa por uma
  # razão que o próprio desenho impõe: a releitura por assinante é o que faz o recorte A7 valer no
  # WebSocket (cada um lê com o próprio escopo). Trocá-la por uma leitura só, compartilhada, exige
  # reimplementar `OwnAgendaOnly` no canal — a segunda cópia da regra de vazamento, que é
  # exatamente o que o moduledoc deste arquivo existe para impedir. Só vale pagar esse preço com
  # número na mão.
  #
  # Os dois sinais que dão o número, e por que são dois:
  #
  #   * `[:api, :agenda, :broadcast]` (no `AgendaNotifier`) — quantas vezes o servidor publicou;
  #   * `[:api, :agenda_channel, :entrega]` — quantas vezes um canal tratou o evento, com `modo` e
  #     `releitura` como rótulos.
  #
  # A razão entre eles **é** a amplificação: entregas/broadcast = assinantes por tópico. Com um
  # contador só não dá para distinguir "muita gente na tela" de "muita escrita na agenda", e são
  # dois problemas com remédios opostos. O tempo da releitura vai em `[:api, :agenda_channel,
  # :releitura]` — é ele que diz se o `bloco_load()` custa 2 ms ou 60 ms sob carga real.
  @doc "Evento de telemetria: um canal tratou um evento de agenda (o numerador do M6)."
  def evento_entrega, do: [:api, :agenda_channel, :entrega]

  @doc "Evento de telemetria: o tempo de UMA releitura de bloco com o escopo do assinante."
  def evento_releitura, do: [:api, :agenda_channel, :releitura]

  defp entregue(modo, releitura?) do
    :telemetry.execute(evento_entrega(), %{count: 1}, %{
      modo: to_string(modo),
      releitura: to_string(releitura?)
    })
  end

  defp medir_releitura(scope, appointment_id) do
    inicio = System.monotonic_time()
    visivel = Scheduling.load_visible_appointment(scope, appointment_id)

    :telemetry.execute(
      evento_releitura(),
      %{duration: System.monotonic_time() - inicio},
      %{achou: to_string(not is_nil(visivel))}
    )

    visivel
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

  # Só quem está **olhando um dia** entra na presença — que é Dia e Lista, e é exatamente o que
  # `mode: :block` significa.
  #
  # A Semana assina os 5–7 tópicos de dia da janela (é a granularidade do notifier). Rastrear no
  # `join` sem este filtro colocaria uma pessoa como "vendo" sete dias ao mesmo tempo: o aviso
  # deixaria de significar "ela está com este dia na tela", que é a única coisa que ele serve
  # para dizer. O Mês é sinal por definição e cai aqui pelo mesmo caminho.
  defp rastreia_presenca?({:day, _date}, :block), do: true
  defp rastreia_presenca?(_resolucao, _modo), do: false

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

  defp internal_topic(clinic_id, {:day, date}), do: AgendaNotifier.day_topic(clinic_id, date)
  defp internal_topic(clinic_id, {:month, date}), do: AgendaNotifier.month_topic(clinic_id, date)
end
