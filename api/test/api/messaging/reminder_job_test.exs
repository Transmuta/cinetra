defmodule Api.Messaging.ReminderJobTest do
  @moduledoc """
  O lembrete por relógio (doc 52 §7).

  Dois testes carregam o peso: **nasce calado** (clínica sem o número configurado não dispara
  nada — é a decisão que impede um envio em massa acidental) e **a janela ladrilha** (sem buraco
  e sem sobreposição, que é o que dispensa uma coluna "já avisei").
  """
  use Api.DataCase, async: false

  alias Api.Messaging.ReminderJob

  test "clínica sem lembrete configurado não dispara nada" do
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(24))

    rodar(agora())

    assert [] = lembretes(ctx, appt)
  end

  test "com 24h configuradas, a sessão de amanhã recebe lembrete" do
    ctx = clinica()
    ligar(ctx, 24)
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(24))

    rodar(agora())

    assert [%{kind: :lembrete, destino: "ana@example.com"}] = lembretes(ctx, appt)
  end

  test "sessão fora da janela não recebe" do
    ctx = clinica()
    ligar(ctx, 24)
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    # Daqui a 30 h: cai na rodada de daqui a 6 h, não nesta.
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(30))

    rodar(agora())

    assert [] = lembretes(ctx, appt)
  end

  test "a janela LADRILHA: a mesma sessão não cai em duas rodadas seguidas" do
    # É isto que dispensa uma coluna "lembrete_enviado_em". Se a largura da janela e o passo do
    # cron divergirem, ou some um lembrete ou o paciente recebe dois.
    ctx = clinica()
    ligar(ctx, 24)
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(24))

    base = agora()
    rodar(base)
    rodar(DateTime.add(base, 3600, :second))

    assert [_um_so] = lembretes(ctx, appt)
  end

  test "presença cancelada não recebe lembrete" do
    ctx = clinica()
    ligar(ctx, 24)
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(24))

    Api.Scheduling.cancel_appointment_slot!(appt, %{}, scope: ctx.scope)

    rodar(agora())

    assert [] = lembretes(ctx, appt)
  end

  # ---- helpers ----

  # Ancorado num instante fixo e distante para a janela não depender da hora em que a suíte roda.
  defp agora, do: ~U[2026-09-15 12:00:00Z]

  defp daqui(horas), do: DateTime.add(agora(), horas * 3600, :second)

  defp rodar(instante) do
    ReminderJob.perform(%Oban.Job{args: %{"agora" => DateTime.to_iso8601(instante)}})
  end

  defp ligar(ctx, horas) do
    Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_lembrete_horas: horas},
      actor: ctx.owner
    )
  end

  defp lembretes(ctx, appt), do: Enum.filter(mensagens(ctx, appt), &(&1.kind == :lembrete))
end
