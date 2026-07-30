defmodule Api.Accounts.Clinic.Validations.ValidCnpj do
  @moduledoc """
  Valida o `cnpj` da clínica **quando presente** (o campo é opcional). Aceita alfanumérico
  ou numérico, com ou sem máscara — a autoridade do formato é `Api.Cnpj`. Um valor em branco
  (que normaliza para `nil`) é tratado como "não informado" e passa: é como se limpa o campo.

  Não é atômica: o cálculo do módulo 11 com aritmética por caractere não se expressa em SQL.
  Roda só quando o `cnpj` está mudando, então não pesa em updates que não o tocam.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :cnpj) do
      value = Ash.Changeset.get_attribute(changeset, :cnpj)

      cond do
        is_nil(value) or is_nil(Api.Cnpj.normalize(value)) -> :ok
        Api.Cnpj.valid?(value) -> :ok
        true -> {:error, field: :cnpj, message: "CNPJ inválido"}
      end
    else
      :ok
    end
  end
end
