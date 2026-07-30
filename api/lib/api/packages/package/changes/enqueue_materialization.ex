defmodule Api.Packages.Package.Changes.EnqueueMaterialization do
  @moduledoc """
  Enfileira `Api.Packages.Materializer` para o pacote recém-criado, **dentro da transação** da
  criação (`after_action`): o `Oban.insert` participa do mesmo commit, então nunca existe pacote
  sem job nem job apontando para um pacote que não foi gravado.

  Só enfileira quando o argumento `materialize?` é verdadeiro — a criação crua do recurso (teste,
  ou um caminho que não quer agendar) fica sem job. `forcar` viaja para o job e vira `encaixe`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_argument(changeset, :materialize?) == true do
      forcar = Ash.Changeset.get_argument(changeset, :forcar) == true

      Ash.Changeset.after_action(changeset, fn _changeset, package ->
        %{package_id: package.id, clinic_id: to_string(package.clinic_id), forcar: forcar}
        |> Api.Packages.Materializer.new(Api.Correlacao.opts())
        |> Oban.insert()
        |> case do
          {:ok, _job} -> {:ok, package}
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      changeset
    end
  end
end
