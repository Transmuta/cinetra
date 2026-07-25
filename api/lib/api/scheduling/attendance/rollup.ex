defmodule Api.Scheduling.Attendance.Rollup do
  @moduledoc """
  A regra pura do **rollup** do status do bloco a partir das presenças (Frente 6/A2, doc 41).

  A presença passa a ser por participante (D10): não há mais transição do bloco inteiro. O
  desfecho do `Appointment` (`:concluido`/`:faltou`) vira **derivado** das `Attendance` — e este
  módulo é essa derivação, sem tocar em banco (testável isolado).

  O rollup só sabe decidir o **desfecho**; a sub-fase de agendamento (`:agendado` vs `:confirmado`
  vs `:em_atendimento`) não está nas presenças, então é **preservada** quando as presenças ainda
  não resolveram. Regra:

    * presenças vivas = as não `:cancelada`;
    * **todas** resolvidas (`:concluida`/`:faltou`):
      * alguma `:concluida` → `:concluido` (a sessão aconteceu para pelo menos um — `attendance.ex:8`);
      * todas `:faltou`     → `:faltou`;
    * **parcial ou todas `:prevista`**:
      * se o bloco estava num desfecho (`:concluido`/`:faltou`) → volta a `:agendado` (espelha o
        `reopen` de bloco, que reseta para `:agendado`);
      * senão → mantém a fase atual (`:agendado`/`:confirmado`/`:em_atendimento`).

  Bloco sem presença viva (todas canceladas) mantém o status atual — não é caso do fluxo normal.
  """

  @outcome [:concluido, :faltou]

  @doc """
  Devolve o status do bloco dado o status **atual** e a lista de status das presenças.

  `attendance_statuses` são os `AttendanceStatus` de TODAS as presenças do bloco (inclusive
  canceladas — filtramos aqui).
  """
  @spec block_status(atom(), [atom()]) :: atom()
  def block_status(current, attendance_statuses) when is_atom(current) and is_list(attendance_statuses) do
    live = Enum.reject(attendance_statuses, &(&1 == :cancelada))

    cond do
      live == [] -> current
      Enum.all?(live, &(&1 in [:concluida, :faltou])) -> resolved_outcome(live)
      current in @outcome -> :agendado
      true -> current
    end
  end

  defp resolved_outcome(live) do
    if Enum.any?(live, &(&1 == :concluida)), do: :concluido, else: :faltou
  end
end
