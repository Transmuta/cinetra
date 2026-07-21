defmodule Api.Scheduling.SlotHold.Validations.ProfessionalInClinic do
  @moduledoc """
  Recusa `professional_id` que não seja `Professional` da clínica ativa (422). Espelha
  `Api.Scheduling.Appointment.Validations.PatientsInClinic`.

  ## Por que a fila precisa disto e o agendamento "escapava"

  A exclusion constraint `slot_holds_no_overlap` é **global** (sem `clinic_id`, ADR-017 —
  `professional_id` já é único globalmente). Sem esta validação, a `offer` aceitava um
  `professional_id` de **outra** clínica: o hold nascia com `clinic_id` do escopo e um
  profissional alheio, e a constraint global permitia que uma clínica **negasse por 10 min** a
  reserva de vaga de outra para aquele profissional (bate-volta E5 — o único ponto do diff onde
  um id do cliente cruzava a fronteira de tenant sem validação). Sem disclosure (a RLS esconde o
  dado), mas é um vetor cross-tenant que a validação fecha na raiz.

  `professional_in_clinic?/2` abre a própria transação com a GUC (`Api.Repo.with_clinic`), então
  funciona sob RLS — o `mix test` (BYPASSRLS) não pegaria um furo de GUC aqui. A mensagem não
  ecoa o id: de fora, id alheio é indistinguível de inexistente.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    with professional_id when is_binary(professional_id) <-
           Ash.Changeset.get_attribute(changeset, :professional_id),
         clinic_id when not is_nil(clinic_id) <- changeset.tenant,
         false <- Api.Directory.professional_in_clinic?(professional_id, to_string(clinic_id)) do
      {:error, field: :professional_id, message: "profissional não encontrado nesta clínica"}
    else
      _ -> :ok
    end
  end
end
