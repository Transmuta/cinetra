defmodule Api.Waitlist.TimeWindow do
  @moduledoc """
  Janela de preferência de horário na fila (doc 25 §1). Átomo **sem acento** (a UI exibe
  "Manhã"/"Tarde"/"Qualquer"); verificado no seed do protótipo
  ([`:163`](../../../interface/Movimento.dc.html#L163)-[`:165`](../../../interface/Movimento.dc.html#L165)).

  O motor `SlotFinder` usa a janela como corte (RN-39): `:manha` rejeita horários `>= 12:00`,
  `:tarde` rejeita `< 12:00`, `:qualquer` não corta.
  """
  use Ash.Type.Enum, values: [:manha, :tarde, :qualquer]
end
