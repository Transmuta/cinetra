defmodule Api.Waitlist.RuleType do
  @moduledoc """
  Forma de uma regra de disponibilidade da fila (doc 25 §1, seed
  [`:163`](../../../interface/Movimento.dc.html#L163)):

    * `:semana` — recorrente por dias-da-semana (`dows`), com faixas de horário;
    * `:data`   — uma data específica, com faixas de horário. Expira quando a data já passou
      (`filaRegraExpirada`, [`:2516`](../../../interface/Movimento.dc.html#L2516)).
  """
  use Ash.Type.Enum, values: [:semana, :data]
end
