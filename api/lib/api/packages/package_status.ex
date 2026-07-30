defmodule Api.Packages.PackageStatus do
  @moduledoc """
  O estado de um pacote (Fatia 3, doc 25/02 §1.5), verbatim do `status` do protótipo
  ([`:358`](../../../../interface/Movimento.dc.html#L358)):

    * `:ativo`     — em andamento, consumindo sessões (default);
    * `:pausado`   — sessões futuras seguradas (`pkg_hold`), fora da agenda (RN-23);
    * `:cancelado` — encerrado antes do fim; sessões futuras liberadas (RN-25);
    * `:concluido` — todas as sessões consumidas (RN-28 / `pkgDone`, [`:329`](../../../../interface/Movimento.dc.html#L329)).

  **Sem `:renovado`** (ADR-011): não há pacote-sucessor. Aumentar/diminuir o total é ajuste no
  mesmo registro, não renovação.
  """
  use Ash.Type.Enum, values: [:ativo, :pausado, :cancelado, :concluido]
end
