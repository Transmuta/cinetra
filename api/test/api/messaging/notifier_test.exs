defmodule Api.Messaging.NotifierTest do
  @moduledoc """
  A cola entre a agenda e a comunicação (doc 52 §7) — **depois** de 2026-07-31, quando a
  confirmação na criação foi removida.

  O teste que carrega o peso agora é o primeiro: **criar não fala com o paciente**. Era o gatilho
  mais visível da fatia, e o que sobrou no lugar dele é o lembrete por relógio
  (`Api.Messaging.ReminderJobTest`). Marcar uma sessão voltou a ser um gesto interno; o paciente
  só é procurado quando o combinado **muda** (remarcação, cancelamento) ou quando a sessão está
  perto.

  Os outros dois gatilhos (`:remarcacao`, `:cancelamento`) têm arquivo próprio —
  `Api.Messaging.GatilhosC7bTest`.
  """
  # `async: false`: o teste de falha de entrega troca o adapter do mailer por
  # `Application.put_env`, que é **global ao nó**. Rodando em paralelo, esta troca alcança outro
  # teste no meio do envio dele — e o sintoma é um `refute_email_sent` que falha uma vez a cada
  # tantas execuções, no arquivo errado. Mesmo motivo de `access_revoked_email_test.exs`.
  alias Api.Scheduling

  use Api.DataCase, async: false

  describe "criar um agendamento NÃO fala com o paciente" do
    test "agendamento novo não gera mensagem nenhuma" do
      # A regra de 2026-07-31. Antes disto, marcar uma sessão disparava a confirmação na hora — e
      # numa clínica de balcão a recepção marca por telefone, com o paciente do outro lado, o que
      # fazia a mensagem chegar durante a própria conversa que a tornava desnecessária.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")

      appt = agendamento!(ctx, paciente: paciente)

      assert [] = mensagens(ctx, appt)
    end

    test "entrar numa turma também não gera nada" do
      # Entrar num bloco existente dispara o notifier para o bloco INTEIRO. Enquanto a criação
      # confirmava, esta era a porta pela qual quem já estava na turma recebia a mesma confirmação
      # a cada colega novo — numa turma de 4, quatro vezes. Sem o gatilho não há o que deduplicar,
      # e é isso que este teste tranca: quem reintroduzir a confirmação na criação tem de
      # reintroduzir a dedupe junto.
      ctx = clinica(tipo: [grupo: true, capacidade: 4])
      primeiro = paciente_com(ctx, comunicacao: true, email: "um@example.com")
      segundo = paciente_com(ctx, comunicacao: true, email: "dois@example.com")

      quando = Api.Generators.proximo_dia_util_as(ctx, 9)
      appt = agendamento!(ctx, paciente: primeiro, quando: quando)

      # Mesmo horário, mesmo profissional, mesmo tipo de grupo: funde na turma existente.
      _ = agendamento!(ctx, paciente: segundo, quando: quando)

      assert [] = mensagens(ctx, appt)
    end
  end

  describe "a marca do LOTE continua suprimindo" do
    test "escrita de lote não dispara remarcação — nem aqui, nem na caixa do sino" do
      # A marca `bulk_pacote` é a mesma nos DOIS notifiers, em duas cláusulas idênticas. O
      # bate-volta apontou a duplicação; a extração piora o código (função não casa em head), então
      # a invariante fica presa aqui: quem trocar a marca em `Api.Packages.Bulk` e esquecer um dos
      # assinantes vê ESTE teste vermelho — e não 40 mensagens saindo, sem erro nenhum.
      #
      # **Ancorado em `:reschedule`, e não mais em `:schedule`**: desde que criar deixou de falar
      # com o paciente, uma notificação de criação não geraria mensagem nem sem a marca — o teste
      # ficaria verde com a supressão do lote quebrada, que é exatamente como ele nasceu decorativo
      # da primeira vez.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "lote@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      assert [] = mensagens(ctx, appt), "o setup precisa começar sem mensagem nenhuma"

      notificacao = %Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: :reschedule},
        data: appt,
        changeset: %{context: %{bulk_pacote: true}}
      }

      assert :ok = Api.Messaging.Notifier.notify(notificacao)
      assert :ok = Api.Notifications.Notifier.notify(notificacao)

      assert [] = mensagens(ctx, appt),
             "a escrita de lote gerou mensagem: a supressão do `bulk_pacote` quebrou"
    end

    test "sem a marca, a MESMA notificação gera a remarcação" do
      # O contraprova do teste acima: sem ele, um `notify/1` que parasse de funcionar por qualquer
      # outro motivo (cláusula fora de ordem, participante filtrado) deixaria o anterior verde
      # dizendo "o lote suprime" quando na verdade nada mais é enviado, nunca.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "solto@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      notificacao = %Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: :reschedule},
        data: appt,
        changeset: %{context: %{}}
      }

      assert :ok = Api.Messaging.Notifier.notify(notificacao)

      assert [%{kind: :remarcacao}] = mensagens(ctx, appt)
    end
  end

  test "falha ao comunicar não derruba a operação da agenda" do
    # O cancelamento é o fato; a mensagem é o aviso sobre ele. Inverter faria a agenda depender de
    # um provider externo estar de pé. Ancorado no `:cancel` porque é o gatilho que ainda fala com
    # o paciente — a criação deixou de falar.
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente)

    resultado =
      Api.Support.FailingMailer.with_failure(fn ->
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)
      end)

    assert {:ok, cancelado} = resultado
    assert cancelado.status == :cancelado
  end
end
