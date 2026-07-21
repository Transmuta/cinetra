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
  """
  use Phoenix.Channel

  alias Api.Waitlist.WaitlistNotifier

  @impl true
  def join(topic, _params, socket) do
    with {:ok, clinic_id} <- parse_topic(topic),
         :ok <- same_clinic(clinic_id, socket),
         :ok <- active_member?(socket.assigns.user_id, clinic_id) do
      WaitlistNotifier.subscribe(WaitlistNotifier.internal_topic(clinic_id))
      {:ok, socket}
    else
      :invalid_topic -> {:error, %{reason: "invalid_topic"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:waitlist_event, evento}, socket) do
    push(socket, "waitlist_changed", %{change: evento.change, actor: evento.actor})
    {:noreply, socket}
  end

  defp parse_topic("waitlist:" <> clinic_id) when clinic_id != "", do: {:ok, clinic_id}
  defp parse_topic(_topic), do: :invalid_topic

  defp same_clinic(clinic_id, %{assigns: %{clinic_id: clinic_id}}), do: :ok
  defp same_clinic(_clinic_id, _socket), do: :error

  # Existe vínculo **ativo** deste usuário com esta clínica? A mesma pergunta do `LoadScope`, ao
  # mesmo lugar. Não guardamos escopo: a fila não é recortada, então o push não precisa dele.
  defp active_member?(user_id, clinic_id) do
    case Api.Accounts.get_active_membership(user_id, clinic_id, authorize?: false) do
      {:ok, %{}} -> :ok
      _ -> :error
    end
  end
end
