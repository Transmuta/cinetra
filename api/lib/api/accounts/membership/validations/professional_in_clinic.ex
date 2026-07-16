defmodule Api.Accounts.Membership.Validations.ProfessionalInClinic do
  @moduledoc """
  `professional_id` é um "UUID mole" (sem FK entre schemas). Esta validação impede pendurar
  no `Membership` (global) um profissional de OUTRA clínica: quando `professional_id` está
  presente, ele precisa ser um `Professional` da clínica do vínculo. Fecha o vetor de
  referência cross-tenant que o `Scope.professional_id` propagaria (auditoria bate-volta, D).

  A clínica vem do argumento `:clinic_id` (convite) ou do `clinic_id` do registro (update).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    professional_id = Ash.Changeset.get_attribute(changeset, :professional_id)
    clinic_id = clinic_id(changeset)

    if is_nil(professional_id) or
         Api.Directory.professional_in_clinic?(professional_id, clinic_id) do
      :ok
    else
      {:error, field: :professional_id, message: "profissional não pertence a esta clínica"}
    end
  end

  defp clinic_id(changeset) do
    Ash.Changeset.get_argument(changeset, :clinic_id) || changeset.data.clinic_id
  end
end
