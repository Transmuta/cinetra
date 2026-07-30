defmodule Api.Scheduling.FutureConflictsTest do
  @moduledoc """
  **A3 / D12** contra o banco: `Api.Scheduling.future_conflicts/2` e o **gate de escrita** nas
  quatro portas de edição de horário.

  O motor puro tem teste próprio (`ImpactAnalysisTest`); aqui prova-se o que só o banco responde:
  que a leitura pega os agendamentos certos (futuros, abertos, desta clínica), que o veredito
  chega às ações de escrita, e que **nada é gravado** quando há conflito — D12 é bloqueio, não
  aviso.
  """
  use Api.DataCase, async: false

  alias Api.Scheduling

  # Uma segunda-feira bem no futuro, para o teste não depender do dia em que roda.
  @segunda ~D[2027-03-15]

  defp at(date, hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(date, hhmm, "America/Sao_Paulo")
    dt
  end

  # Escopo com o relógio cravado numa sexta anterior à segunda de referência: tudo o que o teste
  # agenda é futuro, sem depender do relógio de parede.
  defp ctx_no_passado do
    ctx = clinica()
    %{ctx | scope: escopo_em(ctx, at(~D[2027-03-12], "08:00"))}
  end

  defp agendar(ctx, hhmm, opts \\ []) do
    attrs = %{
      starts_at: at(Keyword.get(opts, :date, @segunda), hhmm),
      professional_id: Keyword.get(opts, :professional_id, ctx.prof.id),
      appointment_type_id: ctx.tipo.id,
      patient_ids: [ctx.paciente.id],
      encaixe: Keyword.get(opts, :encaixe, false)
    }

    {:ok, appt} = Scheduling.schedule_appointment(attrs, scope: ctx.scope)
    appt
  end

  describe "future_conflicts/2 — a leitura" do
    test "acha o agendamento que deixaria de caber ao encurtar a semana da clínica" do
      ctx = ctx_no_passado()
      appt = agendar(ctx, "14:00")

      %{conflicts: [conflito], total: 1} =
        Scheduling.future_conflicts(ctx.scope, {:clinic_hours, %{1 => [["08:00", "12:00"]]}})

      assert conflito.appointment_id == appt.id
      assert conflito.reason == :fora_do_expediente
      assert conflito.hora == "14:00"
      # A lista é para uma pessoa decidir o que remarcar — precisa de nome, não de uuid.
      assert conflito.professional_nome == ctx.prof.nome
      assert conflito.patients == [ctx.paciente.nome]
    end

    test "não conta o que já foi cancelado" do
      ctx = ctx_no_passado()
      appt = agendar(ctx, "14:00")
      {:ok, _} = Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{})

      assert %{conflicts: []} =
               Scheduling.future_conflicts(
                 ctx.scope,
                 {:clinic_hours, %{1 => [["08:00", "12:00"]]}}
               )
    end

    test "não conta o passado — mudar o expediente não desfaz o que já aconteceu" do
      ctx = clinica()
      passado = %{ctx | scope: escopo_em(ctx, at(~D[2027-03-01], "08:00"))}
      _appt = agendar(passado, "14:00", date: ~D[2027-03-08])

      # Agora o relógio está DEPOIS daquele agendamento.
      depois = %{ctx | scope: escopo_em(ctx, at(~D[2027-03-12], "08:00"))}

      assert %{conflicts: []} =
               Scheduling.future_conflicts(
                 depois.scope,
                 {:clinic_hours, %{1 => [["08:00", "12:00"]]}}
               )
    end

    test "sem agendamento nenhum, nenhum conflito" do
      ctx = ctx_no_passado()

      assert %{conflicts: [], total: 0} =
               Scheduling.future_conflicts(ctx.scope, {:clinic_hours, %{1 => []}})
    end

    # #2 da rodada de decisões: o `total` é o número REAL, e a lista detalha só os primeiros —
    # uma tela com 80 linhas não ajuda a decidir; "10 de 80" ajuda.
    test "o total é exato mesmo quando a lista é cortada" do
      ctx = ctx_no_passado()

      # 12 sessões às 14h — uma por profissional, todas fora da janela 08–12 proposta.
      for n <- 1..12 do
        agendar(ctx, "14:00", professional_id: profissional!(ctx, "Dr. #{n}").id)
      end

      %{conflicts: conflitos, total: total} =
        Scheduling.future_conflicts(ctx.scope, {:clinic_hours, %{1 => [["08:00", "12:00"]]}})

      assert total == 12
      assert length(conflitos) == 10, "a lista detalha 10; a contagem não tem teto"
    end

    test "não enxerga a agenda de outra clínica" do
      ctx = ctx_no_passado()
      _appt = agendar(ctx, "14:00")

      outra = clinica()
      outra = %{outra | scope: escopo_em(outra, at(~D[2027-03-12], "08:00"))}

      assert %{conflicts: []} =
               Scheduling.future_conflicts(
                 outra.scope,
                 {:clinic_hours, %{1 => [["08:00", "12:00"]]}}
               )
    end
  end

  describe "o gate de escrita (D12): bloqueia, não avisa" do
    test "update_clinic_hours recusa enquanto houver futuro conflitante" do
      ctx = ctx_no_passado()
      agendar(ctx, "14:00")

      assert {:error, {:future_conflicts, %{conflicts: [_ | _]}}} =
               Scheduling.update_clinic_hours(ctx.scope, %{1 => [["08:00", "12:00"]]})

      # E NADA foi gravado: o expediente da segunda continua o de antes.
      segunda = Enum.find(Scheduling.list_clinic_hours(ctx.scope), &(&1.dow == 1))
      refute segunda.periods == [["08:00", "12:00"]]
    end

    test "sem conflito, salva normalmente" do
      ctx = ctx_no_passado()
      agendar(ctx, "09:00")

      assert {:ok, _rows} =
               Scheduling.update_clinic_hours(ctx.scope, %{1 => [["08:00", "12:00"]]})

      segunda = Enum.find(Scheduling.list_clinic_hours(ctx.scope), &(&1.dow == 1))
      assert segunda.periods == [["08:00", "12:00"]]
    end

    # Não existe "salvar mesmo assim": mudar horário por cima de agenda marcada não é uma opção
    # do produto. A lista existe para a recepção remarcar um a um e tentar de novo.
    test "não há como forçar — a segunda tentativa igual é recusada igual" do
      ctx = ctx_no_passado()
      agendar(ctx, "14:00")

      assert {:error, {:future_conflicts, _}} =
               Scheduling.update_clinic_hours(ctx.scope, %{1 => [["08:00", "12:00"]]})

      assert {:error, {:future_conflicts, _}} =
               Scheduling.update_clinic_hours(ctx.scope, %{1 => [["08:00", "12:00"]]})
    end

    test "update_professional_hours recusa quando fecha o dia de quem tem sessão marcada" do
      ctx = ctx_no_passado()
      agendar(ctx, "14:00")

      assert {:error, {:future_conflicts, %{conflicts: [_ | _]}}} =
               Scheduling.update_professional_hours(ctx.scope, ctx.prof.id, [
                 %{dow: 1, modo: :fechado, periods: []}
               ])
    end

    test "create_clinic_exception recusa um feriado com agenda marcada no dia" do
      ctx = ctx_no_passado()
      agendar(ctx, "14:00")

      assert {:error, erro} =
               Scheduling.create_clinic_exception(ctx.scope, %{
                 data: @segunda,
                 nome: "Feriado",
                 tipo: :fechado,
                 periods: []
               })

      # A recusa vem de DENTRO da ação (`CheckFutureConflicts`), então é erro do Ash com o
      # código e a lista em `vars` — a fronteira o promove a 409.
      assert %{conflicts: [_ | _], total: 1} = ApiWeb.TenantScope.future_conflicts_error(erro)
      assert Scheduling.list_clinic_exceptions(ctx.scope) == []
    end

    test "create_professional_exception recusa a folga com sessão marcada" do
      ctx = ctx_no_passado()
      agendar(ctx, "14:00")

      assert {:error, erro} =
               Scheduling.create_professional_exception(ctx.scope, ctx.prof.id, %{
                 data: @segunda,
                 nome: "Folga",
                 tipo: :fechado,
                 periods: []
               })

      assert %{total: 1} = ApiWeb.TenantScope.future_conflicts_error(erro)
    end

    test "a folga de UM profissional não é barrada pela agenda de OUTRO" do
      ctx = ctx_no_passado()
      outro = profissional!(ctx, "Dr. Outro")
      agendar(ctx, "14:00", professional_id: outro.id)

      assert {:ok, _} =
               Scheduling.create_professional_exception(ctx.scope, ctx.prof.id, %{
                 data: @segunda,
                 nome: "Folga",
                 tipo: :fechado,
                 periods: []
               })
    end
  end
end
