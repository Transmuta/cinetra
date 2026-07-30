defmodule Api.Scheduling.Preparations.HideHeld do
  @moduledoc """
  Esconde de toda leitura as sessões **seguradas por pacote** (RN-05): `pkg_hold == false`. Global
  (uma preparation, não um filtro por leitor) para que agenda, relatório, `SlotFinder` e a
  releitura do canal cortem a segurada no mesmo lugar — no mesmo espírito do `HideExcluded`.

  ## Por que condicional, e não `build(filter: [pkg_hold: false])`

  A materialização/retomada do pacote (`Api.Packages`) **precisa** reler as próprias sessões
  seguradas para cancelá-las e reprojetá-las (GAP-06). Com o filtro incondicional isso é
  impossível: o pacote esconde de si mesmo o que segurou. Então o corte pula quando o contexto da
  query traz `include_held: true` — a porta que só as operações internas do pacote abrem, via
  `Ash.Query.set_context/2`. O caminho normal (sem o flag) continua cortando, como antes.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    if Map.get(query.context, :include_held) do
      query
    else
      Ash.Query.filter(query, pkg_hold == false)
    end
  end
end
