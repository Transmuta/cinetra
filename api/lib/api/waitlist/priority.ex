defmodule Api.Waitlist.Priority do
  @moduledoc """
  Prioridade de um item na fila de espera (doc 25 §1, `01 §4.5`). Quatro níveis, do mais
  urgente ao menos: `:urgente`, `:alta`, `:normal`, `:baixa` — o `<select>` de cadastro do
  protótipo ([`:2231`](../../../interface/Movimento.dc.html#L2231)) e `prioMeta`
  ([`:2512`](../../../interface/Movimento.dc.html#L2512)).

  A **ordem de exibição** (urgente primeiro) é de domínio, não `?sort` do cliente: a lista da
  fila e o "quem cabe" ordenam por esta prioridade. Como o Postgres ordena o enum pela string
  armazenada (alfabética), a ordenação por prioridade real é feita em Elixir via
  `Api.Waitlist.priority_rank/1`, não por `sort:` no banco.
  """
  use Ash.Type.Enum, values: [:urgente, :alta, :normal, :baixa]
end
