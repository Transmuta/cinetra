defmodule Api.Scheduling.Attendance.RollupTest do
  @moduledoc "A regra pura do rollup do status do bloco (Frente 6/A2)."
  use ExUnit.Case, async: true

  alias Api.Scheduling.Attendance.Rollup

  describe "block_status/2 — desfecho quando tudo resolveu" do
    test "todos concluíram → :concluido" do
      assert Rollup.block_status(:agendado, [:concluida, :concluida]) == :concluido
    end

    test "todos faltaram → :faltou" do
      assert Rollup.block_status(:confirmado, [:faltou, :faltou]) == :faltou
    end

    test "alguém veio e alguém faltou → :concluido (a sessão aconteceu)" do
      assert Rollup.block_status(:em_atendimento, [:concluida, :faltou]) == :concluido
    end

    test "canceladas não contam no desfecho" do
      # 1 presença viva concluída, 1 cancelada → concluído
      assert Rollup.block_status(:agendado, [:concluida, :cancelada]) == :concluido
      # só faltas vivas, uma cancelada → faltou
      assert Rollup.block_status(:agendado, [:faltou, :cancelada]) == :faltou
    end
  end

  describe "block_status/2 — parcial ou não resolvido preserva a fase de agendamento" do
    test "todos prevista mantém a fase atual" do
      assert Rollup.block_status(:agendado, [:prevista, :prevista]) == :agendado
      assert Rollup.block_status(:confirmado, [:prevista]) == :confirmado
      assert Rollup.block_status(:em_atendimento, [:prevista, :prevista]) == :em_atendimento
    end

    test "parcial (um resolveu, outro não) mantém a fase, não antecipa o desfecho" do
      assert Rollup.block_status(:confirmado, [:concluida, :prevista]) == :confirmado
      assert Rollup.block_status(:em_atendimento, [:faltou, :prevista]) == :em_atendimento
    end

    test "reabrir um desfecho (voltar todas a prevista) reseta para :agendado" do
      assert Rollup.block_status(:concluido, [:prevista, :prevista]) == :agendado
      assert Rollup.block_status(:faltou, [:prevista]) == :agendado
    end

    test "desfecho ainda parcial após reabrir uma só volta a :agendado" do
      # estava concluído; reabri uma presença → agora parcial → sai do desfecho
      assert Rollup.block_status(:concluido, [:concluida, :prevista]) == :agendado
    end
  end

  describe "block_status/2 — bordas" do
    test "sem presença viva mantém o status atual" do
      assert Rollup.block_status(:cancelado, [:cancelada, :cancelada]) == :cancelado
      assert Rollup.block_status(:agendado, []) == :agendado
    end
  end
end
