defmodule Api.Scheduling.AttendanceStatus do
  @moduledoc """
  Presença de **um participante** num agendamento (doc 25 §4, D10/D11). Separado de
  `AppointmentStatus` de propósito: numa turma o bloco pode estar `:concluido` enquanto um
  participante específico `:faltou` — é exatamente o que o mapa `pkgOf` do protótipo não
  conseguia representar (GAP-07, *"a lacuna mais séria"*, `02:570`).

    * `:prevista`  — participante esperado (default);
    * `:concluida` — compareceu;
    * `:faltou`    — não compareceu (alimenta o agregado `Patient.faltas`);
    * `:cancelada` — saiu deste agendamento sem que o bloco fosse cancelado.

  Como em `AppointmentStatus`, só `:prevista` nasce nesta fatia; o resto é a Entrega 4.
  """
  use Ash.Type.Enum, values: [:prevista, :concluida, :faltou, :cancelada]
end
