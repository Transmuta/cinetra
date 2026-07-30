defmodule Api.Scheduling.Duration do
  @moduledoc """
  O teto de duração de um bloco de agenda, em um lugar só.

  O número já existia — `max: 480` — repetido nas duas fontes de duração
  (`Api.Directory.AppointmentType.duracao_minutos` e o override
  `Api.Scheduling.Appointment.duration_minutos`). Ele deixou de ser um limite de formulário e
  virou **premissa de leitura**: o `:in_range` corta a varredura por baixo em
  `starts_at > from − teto` (A2, [doc 36 §6.2](../../../../docs/36-agenda-comparada.md)), o que só
  é correto porque nenhum bloco dura mais que isso.

  Com quatro cópias do mesmo 480 — duas `constraints:`, o `check_constraint` e o corte da query —
  editar uma e esquecer as outras não dá erro de compilação nem teste vermelho: dá **linha
  invisível na agenda**. Por isso a constante mora aqui e todo mundo pergunta.

  ## Por que 8 horas

  É o expediente de um dia. Um bloco maior que isso não é sessão nem turma — é dado errado. O
  passo da grade (`clinic.slot_minutos`) não tem relação com o teto: D3 separa os dois, e o
  próprio protótipo tem slot de 15 com duração de 50.

  ## Por que o banco também precisa saber

  `constraints:` é invariante de **aplicação**: `Ash.Seed`, script de manutenção e `INSERT` à mão
  passam direto. Enquanto o teto só limitava formulário, isso era feio; depois que a leitura passou
  a depender dele, virou buraco — um bloco de 10h escrito por fora da ação sumiria do `:in_range`
  sem erro nenhum. Mesma lição do CHECK de duração positiva (commit `3a2f27c`).
  """

  @max_minutos 480

  @doc "Duração máxima de um bloco, em minutos."
  @spec max_minutos() :: pos_integer()
  def max_minutos, do: @max_minutos

  @doc "O mesmo teto em segundos — o corte da janela de leitura trabalha em `DateTime.add/3`."
  @spec max_segundos() :: pos_integer()
  def max_segundos, do: @max_minutos * 60
end
