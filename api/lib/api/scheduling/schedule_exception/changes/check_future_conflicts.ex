defmodule Api.Scheduling.ScheduleException.Changes.CheckFutureConflicts do
  @moduledoc """
  **A3 / D12** na criação de uma exceção de data — o recheck **dentro da ação**.

  É o irmão de `Api.Scheduling.Appointment.Changes.CheckAvailability`: aquele confere o
  expediente no instante em que a recepção clica em "agendar"; este confere a agenda no instante
  em que alguém clica em "adicionar feriado". Os dois pela mesma razão — entre perguntar e
  gravar cabe uma escrita de outra pessoa, e quem responde tarde responde sobre um mundo que já
  mudou.

  Roda em `before_action`, ou seja **dentro da transação da própria ação**: se acusar conflito, o
  erro sobe pelo caminho normal do Ash e nada é escrito.

  O erro carrega `code: "future_conflicts"` e a análise inteira em `vars` — é o canal que
  `Api.Scheduling.CodedError` documenta, e é dali que a fronteira monta o 409 com a lista.
  """
  use Ash.Resource.Change

  alias Api.Scheduling.CodedError

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case scope_de(changeset) do
        nil -> changeset
        scope -> conferir(changeset, scope)
      end
    end)
  end

  defp conferir(changeset, scope) do
    attrs = %{
      data: Ash.Changeset.get_attribute(changeset, :data),
      tipo: Ash.Changeset.get_attribute(changeset, :tipo),
      periods: Ash.Changeset.get_attribute(changeset, :periods) || []
    }

    case Api.Scheduling.future_conflicts(scope, mudanca(changeset, attrs)) do
      %{total: 0} ->
        changeset

      analise ->
        Ash.Changeset.add_error(changeset, CodedError.future_conflicts(analise))
    end
  end

  # A exceção é polimórfica pelo dono (doc 22 §2): sem `professional_id` é da clínica e vale
  # para todos; com ele é folga de uma pessoa só, e o recorte da análise é por profissional.
  defp mudanca(changeset, attrs) do
    case Ash.Changeset.get_attribute(changeset, :professional_id) do
      nil -> {:clinic_exception, attrs}
      professional_id -> {:professional_exception, professional_id, attrs}
    end
  end

  # De onde sai o escopo da análise.
  #
  # O caminho normal é o `scope` que `Api.Scope` injeta no contexto da ação. Quando a ação é
  # chamada sem escopo (`tenant:` + `authorize?: false` — seed, job, teste de domínio), monta-se
  # um escopo **mínimo** a partir do `tenant` do changeset: `future_conflicts/2` só precisa do
  # `clinic_id` e do relógio. É o mesmo caminho que o `CheckAvailability` toma ao ler
  # `changeset.tenant` em vez de exigir sessão — a agenda tem de ser protegida venha o pedido de
  # onde vier.
  defp scope_de(changeset) do
    case changeset.context[:scope] do
      %Api.Scope{clinic_id: clinic_id} = scope when not is_nil(clinic_id) ->
        scope

      _ ->
        escopo_minimo(changeset)
    end
  end

  defp escopo_minimo(%{tenant: tenant} = changeset) when not is_nil(tenant) do
    %Api.Scope{
      user: nil,
      now: changeset.context[:now] || DateTime.utc_now(),
      clinic_id: to_string(tenant)
    }
  end

  defp escopo_minimo(_changeset), do: nil
end
