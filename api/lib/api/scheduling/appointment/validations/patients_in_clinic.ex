defmodule Api.Scheduling.Appointment.Validations.PatientsInClinic do
  @moduledoc """
  Recusa `patient_ids` que não sejam da clínica ativa (422).

  ## O acidente que isto substitui

  `professional_id` e `appointment_type_id` já eram barrados quando vinham de outra clínica —
  mas **por acidente**: quem os barra são `CheckAvailability` e `ComputeEndsAt`, que os
  carregam com tenant por outro motivo (expediente e duração) e falham ao não achar. O
  `patient_ids` não passa por lookup escopado nenhum: ia direto para o `manage_relationship`, e
  a `Attendance` nascia com `clinic_id` de uma clínica e `patient_id` de outra — um vazamento
  criado pela própria escrita, e do lado de dentro do tenant que o recebeu.

  Validação, e não `change`: a pergunta é sobre a entrada, e a resposta é 422, não uma
  transformação. O lookup abre a própria transação com a GUC (via
  `Api.Records.patients_outside_clinic/2`) — mesma razão documentada em `CheckAvailability`.

  A mensagem **não** ecoa os ids recusados: pertencem a outra clínica, e confirmar "este id
  existe, mas não é seu" é justamente o que o isolamento não deve responder. De fora, id alheio
  é indistinguível de id inexistente.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    with ids when is_list(ids) and ids != [] <-
           Ash.Changeset.get_argument(changeset, :patient_ids),
         clinic_id when not is_nil(clinic_id) <- changeset.tenant,
         [_ | _] <- Api.Records.patients_outside_clinic(ids, to_string(clinic_id)) do
      {:error, field: :patient_ids, message: "paciente não encontrado nesta clínica"}
    else
      _ -> :ok
    end
  end
end
