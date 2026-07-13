defmodule Api.Directory do
  @moduledoc """
  Domínio do quadro da clínica — recursos **por-tenant** por atributo (`strategy :attribute`
  sobre `clinic_id`, ADR-017). Por ora só `Professional`; `AppointmentType`/`PriceVersion`
  entram nas fatias seguintes.
  """
  use Ash.Domain, otp_app: :api

  resources do
    resource Api.Directory.Professional do
      define :create_professional, action: :create, args: [:nome]
      define :list_professionals, action: :read
      define :get_professional, action: :read, get_by: [:id]
    end
  end

  # `Professional` é por-tenant sob RLS (ADR-018): a leitura só enxerga as linhas do
  # `clinic_id` ativo quando o GUC `movimento.clinic_id` está setado, o que exige uma
  # transação (reads não abrem transação sozinhos). Estes wrappers centralizam o
  # `Api.Repo.with_clinic/2` aqui, na camada de domínio, para que controllers/changes não
  # precisem falar com o Repo (regra ash.md).

  @doc "Profissionais da clínica ativa do escopo (com o GUC de tenant setado)."
  def list_clinic_professionals(%Api.Scope{clinic_id: clinic_id} = scope)
      when is_binary(clinic_id) do
    {:ok, professionals} =
      Api.Repo.with_clinic(clinic_id, fn -> list_professionals!(scope: scope) end)

    professionals
  end

  @doc "Verdadeiro se `professional_id` é um `Professional` da clínica `clinic_id`."
  def professional_in_clinic?(professional_id, clinic_id)
      when is_binary(professional_id) and is_binary(clinic_id) do
    {:ok, found?} =
      Api.Repo.with_clinic(clinic_id, fn ->
        case get_professional(professional_id, tenant: clinic_id, authorize?: false) do
          {:ok, %Api.Directory.Professional{}} -> true
          _ -> false
        end
      end)

    found?
  end

  def professional_in_clinic?(_professional_id, _clinic_id), do: false
end
