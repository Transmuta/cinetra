defmodule ApiWeb.UserSocketTest do
  @moduledoc """
  A porta do WebSocket (Entrega 3). O socket é a **única** superfície autenticada do projeto
  que não passa pelo cookie de sessão nem pelo pipeline de plugs: quem entra é decidido aqui,
  pelo token efêmero de `GET /api/realtime/token` (09 §8).

  S2 (Onda 5): o token deixou de viajar na **query string** e passou ao subprotocolo
  (`Sec-WebSocket-Protocol`), onde o Phoenix o entrega em `connect_info.auth_token`.
  """
  use ApiWeb.ChannelCase, async: true

  alias ApiWeb.RealtimeToken

  @user_id "11111111-1111-1111-1111-111111111111"
  @clinic_id "22222222-2222-2222-2222-222222222222"

  defp token(opts \\ []) do
    RealtimeToken.sign(%{user_id: @user_id, clinic_id: @clinic_id}, opts)
  end

  defp conecta(auth_token),
    do: connect(ApiWeb.UserSocket, %{}, connect_info: %{auth_token: auth_token})

  test "token válido conecta e carrega user_id + clinic_id" do
    assert {:ok, socket} = conecta(token())
    assert socket.assigns.user_id == @user_id
    assert socket.assigns.clinic_id == @clinic_id
  end

  test "sem token não conecta" do
    assert :error = connect(ApiWeb.UserSocket, %{}, connect_info: %{})
  end

  test "token adulterado não conecta" do
    assert :error = conecta(token() <> "x")
  end

  test "token de outro salt não conecta" do
    forjado = Phoenix.Token.sign(ApiWeb.Endpoint, "outro salt", %{user_id: @user_id})
    assert :error = conecta(forjado)
  end

  test "token expirado não conecta — a vida curta é o ponto do token efêmero" do
    velho = token(signed_at: System.system_time(:second) - RealtimeToken.max_age() - 1)
    assert :error = conecta(velho)
  end

  test "o id do socket é por usuário — é o que permite derrubar sessões no sign-out" do
    {:ok, socket} = conecta(token())
    assert ApiWeb.UserSocket.id(socket) == "user_socket:#{@user_id}"
  end

  # O ponto do S2. Enquanto o param continuasse valendo, mover o cliente para o subprotocolo não
  # fecharia nada: um token colhido de log de proxy seguiria conectando pela porta antiga.
  test "token na QUERY STRING não conecta mais (S2) — o param antigo foi fechado, não duplicado" do
    assert :error = connect(ApiWeb.UserSocket, %{"token" => token()}, connect_info: %{})
  end

  # Regressão do achado ao vivo. Os testes acima passam **mesmo com o endpoint desligado**: o
  # `Phoenix.ChannelTest` injeta `connect_info` direto e nunca atravessa o transporte, que é onde
  # o subprotocolo é lido. Escrito como `websocket: [auth_token: true]`, o Phoenix anula a chave
  # (`put_auth_token/2` sobrescreve com o `opts[:auth_token]` de fora, ausente) e todo handshake
  # real vira 403 — com a suíte verde. Só o browser pegou; este teste é para não depender disso.
  test "auth_token é opção do SOCKET, não do `websocket:` (senão o Phoenix a anula)" do
    assert [{"/socket", ApiWeb.UserSocket, opts}] = ApiWeb.Endpoint.__sockets__()
    assert opts[:auth_token] == true
  end
end
