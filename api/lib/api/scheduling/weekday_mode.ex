defmodule Api.Scheduling.WeekdayMode do
  @moduledoc """
  Modo de um dia da semana na grade do profissional (`ProfessionalHours.modo`, correção g,
  `01 §4.3`):

    * `:herda`   — herda o horário da clínica nesse dia;
    * `:custom`  — usa os próprios `periods` (dentro do horário da clínica);
    * `:fechado` — não atende nesse dia (o `null` explícito do protótipo, RN-10).
  """
  use Ash.Type.Enum, values: [:herda, :custom, :fechado]
end
