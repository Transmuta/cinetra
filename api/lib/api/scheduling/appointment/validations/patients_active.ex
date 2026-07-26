defmodule Api.Scheduling.Appointment.Validations.PatientsActive do
  @moduledoc """
  Recusa `patient_ids` de paciente **arquivado** (doc 25 §7 → 422).

  Irmã de `PatientsInClinic`, e separada dela de propósito: são duas perguntas com duas
  respostas diferentes. "Não é desta clínica" é isolamento e a mensagem **não** pode confirmar
  a existência do id; "está arquivado" é sobre um paciente que o operador conhece e vê na
  ficha, e a mensagem pode ser específica — é o que diz a ele para reativar antes de agendar.

  Vale nos **dois** caminhos que criam `Attendance` (`:schedule` e `:add_participant`, A-D4):
  o paciente é o único dado novo do merge, então é justamente ali que a checagem não pode
  faltar. Diferente de tipo e profissional (ver `ReferencesActive`), que a turma existente já
  escolheu no passado.

  Custa um `SELECT` a mais na criação — o preço de responder à pergunta certa com a mensagem
  certa, num caminho que roda uma vez por agendamento.
  """
  use Ash.Resource.Validation

  alias Api.Scheduling.CodedError

  @impl true
  def validate(changeset, _opts, _context) do
    with ids when is_list(ids) and ids != [] <-
           Ash.Changeset.get_argument(changeset, :patient_ids),
         clinic_id when not is_nil(clinic_id) <- changeset.tenant,
         [_ | _] <- arquivados(changeset, ids, to_string(clinic_id)) do
      {:error,
       CodedError.invalid_attribute(:patient_ids, "paciente arquivado não pode ser agendado")}
    else
      _ -> :ok
    end
  end

  # Num LOTE os pacientes vêm aquecidos (`Api.Scheduling.Warm`) — o mesmo paciente para as N
  # sessões da massa —, e o `ativo` sai do registro que já está em memória.
  defp arquivados(changeset, ids, clinic_id) do
    case Api.Scheduling.Warm.pacientes(changeset, clinic_id, ids) do
      {:ok, pacientes} -> pacientes |> Enum.reject(& &1.ativo) |> Enum.map(& &1.id)
      :miss -> Api.Records.inactive_patients(ids, clinic_id)
    end
  end
end
