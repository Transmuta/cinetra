defmodule ApiWeb.UserSocket do
  @moduledoc """
  A porta do tempo real (ADR-004, Entrega 3). Autentica pelo token efêmero de
  `GET /api/realtime/token` — **não** pelo cookie de sessão: o WebSocket não atravessa o
  pipeline de plugs (`load_from_session` → `VerifyTokenSubject` → `LoadScope`), então nada do
  que protege o REST vale aqui por herança. O que entra é o que este módulo deixar entrar.

  O socket guarda apenas `user_id` e `clinic_id`. Papel e vínculo são relidos no `join` do
  canal, a cada entrada: o token vive 15 minutos e um acesso revogado nesse intervalo
  continuaria com token válido na mão.
  """
  use Phoenix.Socket

  channel "clinic:*", ApiWeb.AgendaChannel
  # Fila de espera (Entrega 5). Prefixo próprio: `clinic:*` já consome tudo que começa com
  # `clinic:`, então a fila usa `waitlist:<clinic_id>` para não colidir no roteamento.
  channel "waitlist:*", ApiWeb.WaitlistChannel
  # Notificações in-app (doc 31). Prefixo próprio pela mesma razão da fila — `clinic:*` consome
  # tudo que começa com `clinic:`. Tópico por clínica; o canal escuta o interno por-usuário.
  channel "notifications:*", ApiWeb.NotificationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case ApiWeb.RealtimeToken.verify(token) do
      {:ok, %{user_id: user_id, clinic_id: clinic_id}} ->
        {:ok, socket |> assign(:user_id, user_id) |> assign(:clinic_id, clinic_id)}

      _ ->
        :error
    end
  end

  @impl true
  def connect(_params, _socket, _connect_info), do: :error

  # Identifica o socket por usuário: permite `ApiWeb.Endpoint.disconnect/1` derrubar as
  # conexões vivas de quem faz sign-out (a revogação do cookie não alcança um WebSocket já
  # aberto). Ligar isso ao sign-out é da Entrega 4 — aqui só nasce o identificador.
  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
