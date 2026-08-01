defmodule Api.Messaging.ReminderJobTest do
  @moduledoc """
  O lembrete por relógio (doc 52 §7) — o **único** disparo automático ao paciente desde
  2026-07-31, quando a confirmação na criação foi removida.

  Três testes carregam o peso:

    * **o padrão é 2 h** — clínica que ninguém configurou lembra o paciente duas horas antes;
    * **a janela ladrilha** (sem buraco e sem sobreposição), que é o que dispensa uma coluna
      "já avisei";
    * **o lembrete não é adiado pela janela de silêncio** — com 2 h de antecedência, adiar é
      entregar depois da sessão.
  """
  use Api.DataCase, async: false

  alias Api.Messaging.ReminderJob

  # O passo do cron, em segundos. Tem de bater com `@passo_minutos` do job e com o crontab do
  # `config.exs`: é o mesmo número em três lugares, e é o teste do ladrilhamento abaixo que
  # reprova quando um deles anda sozinho.
  @passo_segundos 15 * 60

  test "o padrão é 2 horas: ninguém configura nada e a sessão de daqui a 2 h é lembrada" do
    # A decisão de 2026-07-31. Antes o campo nascia `nil` (desligado) e a comunicação automática
    # era a confirmação da criação; removida ela, uma clínica sem configuração nenhuma ficaria
    # muda para o paciente.
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(2))

    rodar(agora())

    assert [%{kind: :lembrete, destino: "ana@example.com"}] = lembretes(ctx, appt)
  end

  test "clínica com o lembrete desligado não dispara nada" do
    ctx = clinica()
    desligar(ctx)
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(2))

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
    # Daqui a 30 h: cai numa rodada bem mais tarde, não nesta.
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(30))

    rodar(agora())

    assert [] = lembretes(ctx, appt)
  end

  test "a janela tem o TAMANHO DO PASSO: 20 min além do alvo cai na rodada seguinte" do
    # Com o passo de 1 h que a fatia tinha, "2 horas antes" entregava entre 2h00 e 2h59 — meio
    # prazo de erro num lembrete de duas horas. O passo curto é o que faz o número da tela dizer a
    # verdade, e é este teste que o prende.
    # 6 h de antecedência, e não as 2 h do padrão, só para a sessão cair à TARDE no fuso da
    # clínica: com 2 h ela cairia às 11h20 e terminaria depois do intervalo do almoço, e o
    # agendamento seria recusado por horário — nada a ver com o que este teste mede.
    ctx = clinica()
    ligar(ctx, 6)
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: minutos_daqui(6 * 60 + 20))

    rodar(agora())
    assert [] = lembretes(ctx, appt), "a janela pegou uma sessão que ainda não é dela"

    rodar(DateTime.add(agora(), @passo_segundos, :second))
    assert [%{kind: :lembrete}] = lembretes(ctx, appt)
  end

  test "a janela LADRILHA: a mesma sessão não cai em duas rodadas seguidas" do
    # É isto que dispensa uma coluna "lembrete_enviado_em". Se a largura da janela e o passo do
    # cron divergirem, ou some um lembrete ou o paciente recebe dois.
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(2))

    base = agora()
    rodar(base)
    rodar(DateTime.add(base, @passo_segundos, :second))

    assert [_um_so] = lembretes(ctx, appt)
  end

  test "o lembrete NÃO é adiado pela janela de silêncio" do
    # A decisão de 2026-07-31, e a razão dela é aritmética: adiar até o fim da janela entregaria um
    # lembrete de 2 h **depois** da sessão que ele anuncia (sessão às 7h30 → mensagem gerada às
    # 5h30 → sairia às 8h). O silêncio continua valendo para os outros tipos, que não têm prazo de
    # validade tão curto.
    ctx = clinica()
    silenciar_agora(ctx)
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(2))

    rodar(agora())

    assert [lembrete] = lembretes(ctx, appt)

    # Nulo é "sai agora" — é o que o Oban entende como imediato.
    assert lembrete.agendado_para == nil
  end

  test "presença cancelada não recebe lembrete" do
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente, quando: daqui(2))

    Api.Scheduling.cancel_appointment_slot!(appt, %{}, scope: ctx.scope)

    rodar(agora())

    assert [] = lembretes(ctx, appt)
  end

  # ---- helpers ----

  # Ancorado num instante fixo e distante para a janela não depender da hora em que a suíte roda.
  defp agora, do: ~U[2026-09-15 12:00:00Z]

  defp daqui(horas), do: minutos_daqui(horas * 60)

  defp minutos_daqui(minutos), do: DateTime.add(agora(), minutos * 60, :second)

  defp rodar(instante) do
    ReminderJob.perform(%Oban.Job{args: %{"agora" => DateTime.to_iso8601(instante)}})
  end

  defp ligar(ctx, horas) do
    Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_lembrete_horas: horas},
      actor: ctx.owner
    )
  end

  defp desligar(ctx) do
    Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_lembrete_horas: nil},
      actor: ctx.owner
    )
  end

  # A janela de silêncio **relativa ao relógio de agora**, e não horas fixas: o `Dispatch` lê o
  # relógio por dentro (não há injeção ali), então uma janela escrita à mão faria o teste passar de
  # manhã e falhar de madrugada. Mesmo recurso do `Api.Messaging.DispatchTest`.
  defp silenciar_agora(ctx) do
    hora = DateTime.utc_now() |> DateTime.shift_zone!(ctx.clinic.timezone) |> Map.fetch!(:hour)

    Api.Accounts.update_clinic_messaging!(
      ctx.clinic,
      %{msg_silencio_inicio: hora, msg_silencio_fim: rem(hora + 2, 24)},
      actor: ctx.owner
    )
  end

  defp lembretes(ctx, appt), do: Enum.filter(mensagens(ctx, appt), &(&1.kind == :lembrete))
end
