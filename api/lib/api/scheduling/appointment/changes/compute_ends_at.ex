defmodule Api.Scheduling.Appointment.Changes.ComputeEndsAt do
  @moduledoc """
  Deriva `ends_at` de `starts_at` + duração (A3/A-D8).

  A duração é, em ordem: o `duration_minutos` do próprio agendamento quando informado (A-D8 —
  "esta sessão vai demorar mais" sem poluir o catálogo com um tipo novo), senão um **snapshot**
  de `AppointmentType.duracao_minutos`.

  Snapshot é o ponto: mudar a duração do tipo depois **não** mexe em agendamento já criado. É
  fiel ao protótipo, que copia `dur` do tipo no momento da criação ([`:150`]), e é o que
  impede uma edição de catálogo de reescrever silenciosamente a agenda da semana que vem.

  `ends_at` nunca vem do corpo: é derivado, e a fronteira HTTP não o aceita (doc 25 §5).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &put_ends_at/1)
  end

  defp put_ends_at(changeset) do
    case {Ash.Changeset.get_attribute(changeset, :starts_at), duracao(changeset)} do
      {%DateTime{} = starts_at, {:ok, minutos}} ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :ends_at,
          DateTime.add(starts_at, minutos * 60, :second)
        )

      {%DateTime{}, :error} ->
        # Tipo inexistente, arquivado ou de outra clínica. Sem isto o `ends_at` ficava nulo e
        # a falha aparecia como um 400 genérico lá na fronteira, sem dizer o que houve.
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :appointment_type_id,
            message: "tipo de atendimento não encontrado nesta clínica"
          )
        )

      _ ->
        # Sem `starts_at`: a validação de presença já reprova o changeset.
        changeset
    end
  end

  defp duracao(changeset) do
    case Ash.Changeset.get_attribute(changeset, :duration_minutos) do
      minutos when is_integer(minutos) and minutos > 0 -> {:ok, minutos}
      _ -> duracao_do_tipo(changeset)
    end
  end

  # A leitura do tipo precisa da GUC de tenant para atravessar a RLS, e **não dá para contar
  # com o `SetTenantGuc`**: os dois são `before_action` e a ordem entre eles não é garantida.
  # Sem a GUC o `SELECT` volta vazio, `ends_at` fica nulo e a criação morre em 400 — com a
  # suíte inteira verde, porque o sandbox conecta como `postgres` (BYPASSRLS). Foi assim que
  # o formulário quebrou no navegador enquanto 463 testes passavam.
  #
  # `with_clinic/2` abre transação (ou se junta à da ação, que é o caso aqui) e seta a GUC.
  #
  # Num LOTE (série de pacote, massa) o tipo é o MESMO para as N sessões e vem aquecido no
  # contexto (`Api.Scheduling.Warm`) — era a última leitura de `appointment_types` que sobrava por
  # sessão na materialização (doc 101 §4.5, B4). Estar no warm **é** existir nesta clínica: ele foi
  # montado por `list_appointment_types!` sob o tenant. Arquivado entra, e é o certo — a leitura
  # abaixo também não filtra `ativo`; quem recusa tipo arquivado é `ReferencesActive`, e trocar
  # isto aqui por um filtro faria a criação morrer com a mensagem errada.
  defp duracao_do_tipo(changeset) do
    with type_id when is_binary(type_id) <-
           Ash.Changeset.get_attribute(changeset, :appointment_type_id),
         tenant when not is_nil(tenant) <- changeset.tenant,
         {:ok, tipo} <- tipo(changeset, to_string(tenant), type_id),
         %{duracao_minutos: minutos} <- tipo do
      {:ok, minutos}
    else
      _ -> :error
    end
  end

  defp tipo(changeset, clinic_id, type_id) do
    case Api.Scheduling.Warm.tipo(changeset, clinic_id, type_id) do
      {:ok, tipo} ->
        {:ok, tipo}

      :miss ->
        with {:ok, {:ok, tipo}} <-
               Api.Repo.with_clinic(clinic_id, fn ->
                 Api.Directory.get_appointment_type(type_id,
                   tenant: clinic_id,
                   authorize?: false,
                   not_found_error?: false
                 )
               end) do
          {:ok, tipo}
        end
    end
  end
end
