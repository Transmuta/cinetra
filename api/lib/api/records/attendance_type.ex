defmodule Api.Records.AttendanceType do
  @moduledoc """
  Como a clínica cobra o atendimento do paciente (`atend_tipo`), verbatim do protótipo
  (`atendTipos = ['particular','convenio','reembolso']`,
  [`:87`](../../../interface/Movimento.dc.html#L87); botões do form
  [`:2147`](../../../interface/Movimento.dc.html#L2147)):

    * `:particular` — pagamento direto (default);
    * `:reembolso` — o paciente paga e pede reembolso ao plano;
    * `:convenio` — cobrança via convênio.

  É a categoria **comercial** da clínica — não depende de o paciente possuir convênio (o bloco
  de convênio da ficha é registrado à parte, "mesmo em atendimento particular",
  [`:2156`](../../../interface/Movimento.dc.html#L2156)).
  """
  use Ash.Type.Enum, values: [:particular, :reembolso, :convenio]
end
