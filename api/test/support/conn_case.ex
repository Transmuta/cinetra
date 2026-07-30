defmodule ApiWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ApiWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ApiWeb.Endpoint

      use ApiWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ApiWeb.ConnCase

      # As mesmas fábricas do `Api.DataCase` (`clinica/1`, `sign_in!/1`, `sessao_de_membro!/4`…).
      import Api.Generators
    end
  end

  @doc """
  Uma `conn` com a sessão do usuário — o `authed/2` que catorze arquivos de teste copiavam (I67).

  Põe o token de sessão do `User` (que `sign_in!/1` deixou em `metadata`) na sessão assinada, que
  é o que o `LoadScope` lê na outra ponta.
  """
  def authed(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @doc "Uma `conn` nova já autenticada — `authed(build_conn(), user)`."
  def as(user), do: authed(Phoenix.ConnTest.build_conn(), user)

  setup tags do
    # Sandbox transacional: testes de controller que falam com o domínio (sign-in,
    # memberships) precisam do banco. `shared` fora de :async para que o processo da
    # requisição (dispatch síncrono no processo do teste) enxergue a mesma conexão.
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Api.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
