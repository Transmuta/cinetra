defmodule ApiWeb.UserSocketTest do
  @moduledoc """
  A porta do WebSocket (Entrega 3). O socket é a **única** superfície autenticada do projeto
  que não passa pelo cookie de sessão nem pelo pipeline de plugs: quem entra é decidido aqui,
  pelo token efêmero de `GET /api/realtime/token` (09 §8).
  """
  use ApiWeb.ChannelCase, async: true

  alias ApiWeb.RealtimeToken

  @user_id "11111111-1111-1111-1111-111111111111"
  @clinic_id "22222222-2222-2222-2222-222222222222"

  defp token(opts \\ []) do
    RealtimeToken.sign(%{user_id: @user_id, clinic_id: @clinic_id}, opts)
  end

  test "token válido conecta e carrega user_id + clinic_id" do
    assert {:ok, socket} = connect(ApiWeb.UserSocket, %{"token" => token()})
    assert socket.assigns.user_id == @user_id
    assert socket.assigns.clinic_id == @clinic_id
  end

  test "sem token não conecta" do
    assert :error = connect(ApiWeb.UserSocket, %{})
  end

  test "token adulterado não conecta" do
    assert :error = connect(ApiWeb.UserSocket, %{"token" => token() <> "x"})
  end

  test "token de outro salt não conecta" do
    forjado = Phoenix.Token.sign(ApiWeb.Endpoint, "outro salt", %{user_id: @user_id})
    assert :error = connect(ApiWeb.UserSocket, %{"token" => forjado})
  end

  test "token expirado não conecta — a vida curta é o ponto do token efêmero" do
    velho = token(signed_at: System.system_time(:second) - RealtimeToken.max_age() - 1)
    assert :error = connect(ApiWeb.UserSocket, %{"token" => velho})
  end

  test "o id do socket é por usuário — é o que permite derrubar sessões no sign-out" do
    {:ok, socket} = connect(ApiWeb.UserSocket, %{"token" => token()})
    assert ApiWeb.UserSocket.id(socket) == "user_socket:#{@user_id}"
  end
end
