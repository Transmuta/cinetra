defmodule ApiWeb.AccessMatrixControllerTest do
  @moduledoc """
  `GET /api/access-matrix` (AN-06): a matriz sai de `Api.Accounts.AccessMatrix` (que tem o
  tripwire contra as policies); aqui o contrato é só a serialização e a porta — qualquer
  membro lê, sem sessão é 401.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts

  setup %{conn: conn} do
    user = sign_in!(email_unico("mx"))

    {:ok, _clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: user)

    %{conn: authed(conn, user), base_conn: conn}
  end

  test "membro lê a matriz com papéis e áreas", %{conn: conn} do
    body = conn |> get(~p"/api/access-matrix") |> json_response(200)

    assert body["papeis"] == ["owner", "admin", "profissional", "recepcao"]

    anexos = Enum.find(body["areas"], &(&1["id"] == "anexos"))
    assert anexos["acesso"]["profissional"] == "nao"
    assert anexos["acesso"]["recepcao"] == "total"

    # Toda área serializa as quatro colunas — a tabela da tela não pode ter célula furada.
    for area <- body["areas"] do
      assert Map.keys(area["acesso"]) |> Enum.sort() ==
               ["admin", "owner", "profissional", "recepcao"]
    end
  end

  test "sem sessão é 401", %{base_conn: conn} do
    assert conn |> get(~p"/api/access-matrix") |> json_response(401)
  end
end
