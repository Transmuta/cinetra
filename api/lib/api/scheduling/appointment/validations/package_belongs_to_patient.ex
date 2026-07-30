defmodule Api.Scheduling.Appointment.Validations.PackageBelongsToPatient do
  @moduledoc """
  Recusa (422) um `package_id` que não seja um pacote **do próprio participante** (contrato
  [`09 §3.1.1` ponto 2], doc 41 etapa 2).

  Espelha o `apptPkg` do protótipo, que só casa `pkgId` dentro de `patient.pacotes`: lá a
  consistência era mantida à mão num mapa `pkgOf`, e nada impedia carimbar o pacote do paciente A
  na presença do paciente B — o contador `usadas` do A passaria a debitar sessão que o B fez.

  Duas recusas, porque são erros diferentes:

    * **mais de um participante com `package_id`** — o pacote é por participante (D11); um único
      `package_id` para uma lista de pacientes não tem dono definido. É erro de chamada, não de
      dado, e recusar é mais honesto do que escolher um dos pacientes;
    * **pacote que não é daquele paciente** (de outro paciente, de outra clínica, ou inexistente)
      — todos com a **mesma** mensagem, pela razão que `PatientsInClinic` documenta: confirmar
      "existe, mas não é seu" é o que o isolamento não deve responder.

  O lookup abre a própria transação com a GUC (`Api.Packages.package_of_patient?/3`), como as
  validações irmãs — sem ela a leitura volta vazia sob RLS no servidor real e a validação
  reprovaria tudo em produção enquanto passa no `mix test` (sandbox `postgres`, BYPASSRLS).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :package_id) do
      nil -> :ok
      package_id -> validate_owner(changeset, package_id)
    end
  end

  defp validate_owner(changeset, package_id) do
    ids = changeset |> Ash.Changeset.get_argument(:patient_ids) |> List.wrap()

    case ids do
      [patient_id] -> check(changeset, package_id, patient_id, changeset.tenant)
      _ -> {:error, field: :package_id, message: "o pacote é de um participante só"}
    end
  end

  defp check(changeset, package_id, patient_id, tenant) when not is_nil(tenant) do
    clinic_id = to_string(tenant)

    case Api.Scheduling.Warm.pacote_do_paciente?(changeset, clinic_id, package_id, patient_id) do
      :ok -> :ok
      :nao -> nao_encontrado()
      :miss -> se_do_paciente(package_id, patient_id, clinic_id)
    end
  end

  defp check(_changeset, _package_id, _patient_id, _tenant), do: nao_encontrado()

  defp se_do_paciente(package_id, patient_id, clinic_id) do
    if Api.Packages.package_of_patient?(package_id, patient_id, clinic_id),
      do: :ok,
      else: nao_encontrado()
  end

  defp nao_encontrado,
    do: {:error, field: :package_id, message: "pacote não encontrado para este paciente"}
end
