defmodule Api.Packages.Package.Changes.ReopenIfCompleted do
  @moduledoc """
  Somar sessão a um pacote **arquivado** o reabre (D4, doc 69 §10): `:concluido` volta a `:ativo`.

  Arquivar é a decisão de que a série acabou (D1); o `+` é a decisão contrária, e sem esta reabertura
  o pacote ficaria fechado com uma sessão nova pendurada — visível na agenda, invisível no cartão.

  **Cancelado não passa por aqui**: o wrapper do domínio (`Api.Packages.add_session/2`) recusa antes.
  Cancelar avisa o paciente e libera a agenda; ressuscitar isso por um clique de `+` seria surpresa.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_data(changeset, :status) == :concluido do
      Ash.Changeset.change_attribute(changeset, :status, :ativo)
    else
      changeset
    end
  end
end
