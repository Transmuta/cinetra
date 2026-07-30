defmodule Api.Scheduling.Preparations.HideExcluded do
  @moduledoc """
  Esconde de TODA leitura os agendamentos com soft-delete (doc 40): `is_nil(excluded_at)`.

  Global (uma preparation, não um filtro por leitor) para que agenda, relatório, `SlotFinder` e a
  releitura do canal cortem o excluído no mesmo lugar — é o que impede uma query nova de vazá-lo,
  no mesmo espírito do `pkg_hold: false` (RN-05).

  Módulo, e não `prepare build(filter: [excluded_at: nil])`, por uma pegadinha do Ash: a forma de
  keyword passa pelo caminho de **input**, onde `nil` vira `= NULL` (nunca verdadeiro) e zera toda
  leitura. `Ash.Query.filter(query, is_nil(excluded_at))` é o predicado correto. Rodou vermelho na
  suíte antes de virar módulo — 40 falhas de "sumiu tudo".
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.filter(query, is_nil(excluded_at))
  end
end
