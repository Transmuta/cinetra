defmodule Api.Scheduling.Appointment.Validations.GroupCapacity do
  @moduledoc """
  O teto de participantes de uma turma (A-D3) — **soft**, com `422 group_full`.

  ## Por que soft, e por que o encaixe fura

  Capacidade de turma é limite **operacional** ("cabe mais um no Pilates?"), não físico:
  enquanto sala e aparelho não estiverem modelados (GAP-15, v2), o teto é uma combinação da
  clínica, não uma lei da natureza. Por isso `encaixe: true` passa por cima dele — é o mesmo
  gesto que já isenta a não-sobreposição, e vem do papel que pode isentá-la (A9).

  ## O furo do protótipo que isto fecha

  Lá o teto existe só na UI (`overCap && !encaixe` desabilita o botão, [`:1998`]) e o merge de
  participantes é **incondicional** — nunca lê `cap` (`12:80`). Ou seja: validado num caminho e
  furado no outro. Aqui a mesma validação roda em `:schedule` **e** em `:add_participant`, que
  são os dois caminhos que criam `Attendance` — e o merge (A-D4) faz o primeiro cair no
  segundo, então não sobra caminho sem teto.

  ## Onde o teto mora

  `AppointmentType.capacidade` quando presente; senão `Clinic.cap_turma_padrao`. Hoje as ações
  do tipo exigem `capacidade` sse `grupo` (`appointment_type.ex:116`), então o fallback é
  defensivo — vale para linha escrita fora dessas ações. Tipo individual não tem teto nenhum:
  a validação sai calada.

  `409` **não** é opção: turma cheia é "seu pedido está errado", não "o mundo mudou" enquanto
  você pensava (`09:659`). O `409` fica exclusivo da concorrência.
  """
  use Ash.Resource.Validation

  alias Api.Scheduling.CodedError

  @impl true
  def validate(changeset, _opts, _context) do
    with false <- Ash.Changeset.get_argument(changeset, :encaixe) == true,
         ids when is_list(ids) <- Ash.Changeset.get_argument(changeset, :patient_ids),
         clinic_id when not is_nil(clinic_id) <- changeset.tenant,
         type_id when is_binary(type_id) <-
           Ash.Changeset.get_attribute(changeset, :appointment_type_id),
         {:ok, capacidade} <-
           Api.Scheduling.group_capacity(to_string(clinic_id), type_id) do
      check(changeset, to_string(clinic_id), Enum.count(Enum.uniq(ids)), capacidade)
    else
      # Tipo individual, tipo inexistente, sem tenant, encaixe: nenhum desses é assunto daqui.
      # Quem recusa tipo inválido é `ComputeEndsAt`/`TypeAndProfessionalActive`.
      _ -> :ok
    end
  end

  defp check(changeset, clinic_id, entrando, capacidade) do
    # Numa criação não há participante ainda; num `:add_participant` os que já estão contam.
    ja_dentro =
      case changeset.data do
        %{id: id} when is_binary(id) -> Api.Scheduling.count_participants(clinic_id, id)
        _ -> 0
      end

    if ja_dentro + entrando > capacidade do
      {:error,
       CodedError.invalid_changes(
         "A turma está cheia (#{capacidade} #{pluralize(capacidade)}).",
         "group_full"
       )}
    else
      :ok
    end
  end

  defp pluralize(1), do: "vaga"
  defp pluralize(_), do: "vagas"
end
