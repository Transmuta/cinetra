defmodule Api.Directory.ContractType do
  @moduledoc """
  Tipo de vínculo contratual do profissional (`vinculo`), verbatim do protótipo
  (`['Autônomo','PJ','CLT']`, [`:3125`](../../../interface/Movimento.dc.html#L3125)):

    * `:autonomo` — profissional autônomo;
    * `:pj` — pessoa jurídica (habilita razão social / CNPJ no cadastro);
    * `:clt` — celetista.

  Nulável no recurso: o vínculo é opcional no cadastro (só o nome é obrigatório).
  """
  use Ash.Type.Enum, values: [:autonomo, :pj, :clt]
end
