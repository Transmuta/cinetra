defmodule Api.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Api.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Api.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Api.DataCase

      # As fábricas compartilhadas (`clinica/1`, `paciente!/2`, `escopo_de_membro!/3`…). Estavam
      # copiadas em doze `defp setup_clinic` privadas até o bate-volta da Onda 3 (doc 43 §5e).
      import Api.Generators
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Api.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
