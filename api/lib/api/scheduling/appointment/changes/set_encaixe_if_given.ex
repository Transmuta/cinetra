defmodule Api.Scheduling.Appointment.Changes.SetEncaixeIfGiven do
  @moduledoc """
  Grava `encaixe` a partir do argumento **só quando ele veio** (Entrega 4, remarcar).

  No `:schedule` o `encaixe` sempre entra (default `false`). Na remarcação ele é opcional: o
  fluxo comum (arrastar para um horário livre) não mexe na classificação do bloco, e só o
  caminho "Mover como encaixe" do modal de conflito manda `encaixe: true`. Argumento ausente
  (`nil`) preserva o valor atual — não reclassifica o bloco de ninguém sem pedido explícito.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :encaixe) do
      nil -> changeset
      value -> Ash.Changeset.change_attribute(changeset, :encaixe, value)
    end
  end
end
