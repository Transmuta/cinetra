defmodule Api.Scheduling.Appointment.Validations.ReferencesActive do
  @moduledoc """
  Recusa agendar com **tipo arquivado** ou **profissional inativo** (doc 25 §7 → 422).

  ## Por que não bastava o que já havia

  O moduledoc de `ComputeEndsAt` afirmava que tipo "arquivado" já morria no lookup da duração —
  não morria: `get_appointment_type` não filtra `ativo`, e quando o corpo traz
  `duration_minutos` (A-D8) o lookup do tipo **nem acontece**. Eram dois caminhos abertos para
  agendar num tipo que a clínica tirou de circulação.

  O profissional inativo é o caso que a nota do bate-volta chamava de sorte: ele *tende* a cair
  em `CheckAvailability` porque a grade some junto — mas só se a grade sumir. Profissional
  desativado com `ProfessionalHours` ainda em pé agenda normalmente, e o 422 que ele daria
  ("não tem horário definido neste dia") descreveria a consequência, não a causa. Regra tácita
  é regra que volta como bug: aqui ela é explícita, com o campo certo no erro.

  ## Por que só na criação

  §7 é literal: *"existente continua válido"*. Arquivar um tipo tira-o do catálogo dali para a
  frente; a agenda da semana passada não pode sumir porque o catálogo mudou. Por isso esta
  validação está em `:schedule` e **não** em `:add_participant` — quem entra numa turma já
  existente não está escolhendo tipo nem profissional, e bloquear ali apagaria a turma em
  andamento por uma decisão de catálogo. O que `:add_participant` valida é o que ele de fato
  recebe: os pacientes (ver `PatientsActive`).
  """
  use Ash.Resource.Validation

  alias Api.Scheduling.CodedError

  @impl true
  def validate(changeset, _opts, _context) do
    case changeset.tenant do
      nil -> :ok
      tenant -> check(changeset, to_string(tenant))
    end
  end

  defp check(changeset, clinic_id) do
    type_id = Ash.Changeset.get_attribute(changeset, :appointment_type_id)
    professional_id = Ash.Changeset.get_attribute(changeset, :professional_id)

    cond do
      tipo_arquivado?(changeset, clinic_id, type_id) ->
        {:error,
         CodedError.invalid_attribute(
           :appointment_type_id,
           "este tipo de atendimento está arquivado"
         )}

      profissional_inativo?(changeset, clinic_id, professional_id) ->
        {:error, CodedError.invalid_attribute(:professional_id, "este profissional está inativo")}

      true ->
        :ok
    end
  end

  # Num LOTE, tipo e profissional vêm aquecidos (`Api.Scheduling.Warm`) — são os mesmos para as N
  # sessões da massa. `:miss` cai na leitura de sempre.
  defp tipo_arquivado?(changeset, clinic_id, type_id) do
    case Api.Scheduling.Warm.tipo(changeset, clinic_id, type_id) do
      {:ok, tipo} -> not tipo.ativo
      :miss -> Api.Directory.appointment_type_archived?(type_id, clinic_id)
    end
  end

  defp profissional_inativo?(changeset, clinic_id, professional_id) do
    case Api.Scheduling.Warm.profissional(changeset, clinic_id, professional_id) do
      {:ok, prof} -> not prof.ativo
      :miss -> Api.Directory.professional_inactive?(professional_id, clinic_id)
    end
  end
end
