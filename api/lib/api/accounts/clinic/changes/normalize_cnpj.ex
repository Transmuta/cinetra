defmodule Api.Accounts.Clinic.Changes.NormalizeCnpj do
  @moduledoc """
  Guarda o `cnpj` na forma canônica (só `[0-9A-Z]`, maiúsculas — ver `Api.Cnpj`), descartando a
  máscara que chega do formulário. Um valor em branco vira `nil` (limpa o campo). Só age quando
  o `cnpj` está mudando; a validade em si é da `Validations.ValidCnpj`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :cnpj) do
      normalized = changeset |> Ash.Changeset.get_attribute(:cnpj) |> Api.Cnpj.normalize()
      Ash.Changeset.change_attribute(changeset, :cnpj, normalized)
    else
      changeset
    end
  end
end
