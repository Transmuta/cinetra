defmodule Api.Scheduling.Appointment.Changes.BumpVersion do
  @moduledoc """
  Incrementa `version` a cada mutação de ciclo de vida (Entrega 4).

  `version` é o locking otimista (doc 25 §10): o cliente manda o `expected_version` que leu, e
  o domínio recusa a escrita com **409** se o valor no banco já não for esse — "seu pedido
  estava certo, o mundo mudou" (`09:659`). O guard da versão mora no wrapper do domínio
  (fetch-then-update), porque `SetTenantGuc` é `before_action` e força `require_atomic? false`
  em toda escrita por-tenant, o que é incompatível com o `atomic_update(:version, …)` que
  [`01:535`](01-dominio-ash.md) prescrevia — as duas coisas não coexistem como escritas. Este
  change só faz a outra metade: **avançar** o contador para que o próximo `expected_version`
  fique obsoleto. A constraint fecha a corrida que sobra entre o fetch e o update.

  Também é o campo que o cliente usa para descartar evento de tempo real atrasado
  (`agenda-live.ts`): versão menor não desfaz estado mais novo.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      Ash.Changeset.force_change_attribute(cs, :version, (cs.data.version || 1) + 1)
    end)
  end
end
