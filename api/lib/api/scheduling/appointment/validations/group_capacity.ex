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
         {:ok, capacidade} <- capacidade(changeset, to_string(clinic_id), type_id) do
      check(changeset, to_string(clinic_id), Enum.count(Enum.uniq(ids)), capacidade)
    else
      # Tipo individual, tipo inexistente, sem tenant, encaixe: nenhum desses é assunto daqui.
      # Quem recusa tipo inválido é `ComputeEndsAt`/`TypeAndProfessionalActive`.
      _ -> :ok
    end
  end

  # Num LOTE o tipo vem aquecido (`Api.Scheduling.Warm`): a capacidade da turma é a mesma para as
  # N sessões da massa. Fora do lote, `:miss` e a leitura de sempre.
  defp capacidade(changeset, clinic_id, type_id) do
    case Api.Scheduling.Warm.tipo(changeset, clinic_id, type_id) do
      {:ok, %{grupo: true, capacidade: capacidade}} when is_integer(capacidade) ->
        {:ok, capacidade}

      # Turma sem teto próprio cai no padrão da clínica — a mesma regra de
      # `Api.Scheduling.group_capacity/2`, e a clínica também está aquecida.
      {:ok, %{grupo: true}} ->
        {:ok, clinic_cap(changeset, clinic_id)}

      {:ok, _individual} ->
        :individual

      :miss ->
        Api.Scheduling.group_capacity(clinic_id, type_id)
    end
  end

  defp clinic_cap(changeset, clinic_id) do
    case Api.Scheduling.Warm.clinic(changeset, clinic_id) do
      {:ok, clinic} -> clinic.cap_turma_padrao
      :miss -> Api.Scheduling.load_clinic(clinic_id).cap_turma_padrao
    end
  end

  defp check(changeset, clinic_id, entrando, capacidade) do
    # Numa criação não há participante ainda; num `:add_participant` os que já estão contam.
    #
    # A contagem roda numa transação própria e o `manage_relationship` grava em **outra**, então
    # duas entradas concorrentes numa turma com uma vaga passam as duas: a turma pode fechar com
    # capacidade+1. O `identity :one_per_patient_per_appt` impede o MESMO paciente duas vezes, não
    # o estouro do teto.
    #
    # **Isso é aceito** (decisão de 2026-08-01, sobre o achado B-12 do doc 96). A capacidade é
    # orientação de sala, não invariante de dinheiro nem de segurança: um a mais numa turma é algo
    # que a recepção resolve na hora, remanejando. Serializar a escrita para isso custaria um
    # `before_action` com `FOR UPDATE` em todo `add_participant` — lock no caminho mais clicado da
    # agenda para evitar um caso raro e reversível.
    #
    # Registrado aqui, e não só no doc, porque o remédio "óbvio" é uma armadilha: um
    # `Ash.Query.lock(:for_update)` **a partir desta validação** não funciona — validação do Ash
    # roda ANTES da transação da ação, e o lock morreria no commit da transação da contagem, antes
    # da escrita. Quem for reabrir isso precisa de `before_action` ou constraint no banco.
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
