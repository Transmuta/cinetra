defmodule Api.Scheduling.ExceptionKind do
  @moduledoc """
  Tipo de exceção de data (doc 22 §2), verbatim do protótipo (`tipo` de `holidays`/`prof.exc`,
  [`:168`](../../../interface/Movimento.dc.html#L168)):

    * `:fechado` — o dia inteiro fecha (sem `periods`);
    * `:horario`  — expediente especial só nesse dia (com `periods`).

  Corrige o `09:463`, que grafou `feriado` no lugar de `fechado`.
  """
  use Ash.Type.Enum, values: [:fechado, :horario]
end
