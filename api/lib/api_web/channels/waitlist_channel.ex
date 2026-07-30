defmodule ApiWeb.WaitlistChannel do
  @moduledoc """
  O canal da fila de espera (Entrega 5, D-E5.3). Tópico:

      waitlist:<clinic_id>

  Prefixo próprio (não `clinic:<id>:waitlist`) porque o `UserSocket` roteia `clinic:*` inteiro
  para o `AgendaChannel` — um prefixo separado evita o conflito de roteamento.

  ## As duas guardas do `join` (as mesmas do `AgendaChannel`)

  1. **O `clinic_id` do tópico é conferido contra o do token** — senão qualquer sessão
     autenticada assinaria a fila de outra clínica, um vazamento por fora da RLS (o WebSocket não
     a atravessa).
  2. **O vínculo é relido do banco** — o token vale 15 min; um acesso revogado nesse intervalo
     ainda traz um token válido na mão.

  Ao contrário da agenda, **não há recorte por papel**: a fila é da clínica inteira, então o
  canal não relê nada por assinante — só verifica o vínculo e empurra o sinal. O cliente recarrega
  a lista ao recebê-lo (a serialização acontece no `GET /api/waitlist`, como todo o JSON).

  ## "Alguém já está oferecendo esta vaga" (doc 39)

  Quando o modal de Oferecer abre, o cliente manda `offering` com o **id do item**; ao fechar,
  `stopped_offering`. O canal rastreia isso em `ApiWeb.Presence` e todo mundo na clínica vê.

  Três decisões que valem o registro:

    * **o nome vem do servidor**, do vínculo lido no `join` — nunca do corpo da mensagem. Aceitar
      o nome do cliente deixaria qualquer sessão dizer que é outra pessoa;
    * **não trava nada**. Dois atendentes podem oferecer o mesmo horário e os dois se veem; a
      colisão, se acontecer, morre na exclusion constraint do agendamento, com o 422 de sempre;
    * **morre com o socket**. Fechar a aba, cair a rede ou dar logout tira o aviso — que é
      exatamente o que a reserva no banco não fazia (doc 39).
  """
  use Phoenix.Channel

  alias Api.Waitlist.WaitlistNotifier
  alias ApiWeb.ChannelScope

  @impl true
  def join(topic, _params, socket) do
    with {:ok, clinic_id} <- ChannelScope.parse_topic(topic, "waitlist:"),
         {:ok, scope} <- ChannelScope.authorize(clinic_id, socket) do
      WaitlistNotifier.subscribe(WaitlistNotifier.internal_topic(clinic_id))
      send(self(), :after_join)
      # O nome vem do vínculo lido no servidor — nunca do corpo da mensagem (ver o moduledoc).
      {:ok, assign(socket, :nome, scope.user.nome)}
    else
      :invalid_topic -> {:error, %{reason: "invalid_topic"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  # Quem já estava oferecendo antes de eu entrar. Sem isto, quem chega depois só descobre no
  # próximo `presence_diff` — ou seja, nunca, se ninguém mexer.
  @impl true
  def handle_info(:after_join, socket) do
    push(socket, "presence_state", ApiWeb.Presence.list(socket))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:waitlist_event, evento}, socket) do
    push(socket, "waitlist_changed", %{change: evento.change, actor: evento.actor})
    {:noreply, socket}
  end

  # O cliente diz **em qual item** está trabalhando; quem ele é sai do socket (do vínculo lido no
  # `join`), não do corpo — senão qualquer sessão se passaria por outra pessoa.
  @impl true
  def handle_in("offering", %{"entry_id" => entry_id}, socket) when is_binary(entry_id) do
    {:ok, _ref} =
      ApiWeb.Presence.track(socket, entry_id, %{
        user_id: socket.assigns.user_id,
        nome: socket.assigns.nome
      })

    {:reply, :ok, socket}
  end

  @impl true
  def handle_in("stopped_offering", %{"entry_id" => entry_id}, socket)
      when is_binary(entry_id) do
    ApiWeb.Presence.untrack(socket, entry_id)
    {:reply, :ok, socket}
  end

  # Mensagem desconhecida (ou malformada) não derruba o canal — a fila continua funcionando.
  @impl true
  def handle_in(_event, _params, socket), do: {:noreply, socket}
end
