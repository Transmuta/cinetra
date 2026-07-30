defmodule Api.Waitlist.WaitlistEntry.Validations.PatientInClinic do
  @moduledoc """
  Recusa `patient_id` que não seja da clínica ativa (422) — o mesmo furo que
  `Api.Scheduling.Appointment.Validations.PatientsInClinic` fecha no agendamento.

  Sem isto, a `enqueue` aceitava um `patient_id` de **outra** clínica: o item nascia com
  `clinic_id` do escopo e um paciente alheio, que a RLS depois escondia na serialização
  (`patient: null`) — um item-fantasma, vazamento criado pela própria escrita, do lado de dentro
  do tenant que o recebeu (bate-volta E5). Benigno (sem disclosure), mas é a mesma causa-raiz do
  furo do `SlotHold` e fecha junto.

  Validação, não `change`: a pergunta é sobre a entrada, a resposta é 422. O lookup
  (`Api.Records.patients_outside_clinic/2`) abre a própria transação com a GUC — funciona sob RLS,
  onde o `mix test` (BYPASSRLS) não pegaria o furo. A mensagem não ecoa o id: de fora, id alheio é
  indistinguível de inexistente.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    with patient_id when is_binary(patient_id) <-
           Ash.Changeset.get_attribute(changeset, :patient_id),
         clinic_id when not is_nil(clinic_id) <- changeset.tenant,
         [_ | _] <- Api.Records.patients_outside_clinic([patient_id], to_string(clinic_id)) do
      {:error, field: :patient_id, message: "paciente não encontrado nesta clínica"}
    else
      _ -> :ok
    end
  end
end
