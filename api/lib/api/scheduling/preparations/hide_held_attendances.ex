defmodule Api.Scheduling.Preparations.HideHeldAttendances do
  @moduledoc """
  Esconde de toda leitura a **presença segurada** por uma pausa de pacote: `pkg_hold == false`.

  Irmã da `HideHeld` do `Appointment`, e pela mesma razão de existir num lugar só: agenda, ficha,
  contagem de turma e o push do canal precisam concordar sobre quem está na sessão.

  ## Por que a presença também tem `pkg_hold`

  Pausar um pacote segura as sessões futuras (RN-23), e até o bate-volta da Onda 3 (doc 43 §5c) o
  `pkg_hold` era **só do bloco**. Numa turma isso tirava a sessão da agenda de **todos**: pausar o
  pacote da Maria fazia sumir o Pilates das terças do João e da Ana. Medido:
  `%{pkg_hold: true, bloco_visivel_antes: 1, bloco_visivel_depois: 0, participantes_do_bloco: 2}`.

  Com o hold na presença, a pausa segue a mesma regra de tudo o mais em pacote (a da massa, doc 41
  etapa 3): **sozinho no bloco**, segura o bloco — é a sessão dele e mais nada; **acompanhado**,
  segura só a presença, e os colegas nem percebem.

  A porta `include_held` é a mesma: o ciclo de vida do pacote precisa reler o que segurou para
  retomar (GAP-06), e só ele a abre, via `Ash.Query.set_context/2`.
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
