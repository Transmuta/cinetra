defmodule Api.Messaging.NotifierTest do
  @moduledoc """
  O gatilho automático (doc 52 §7): agendamento criado → confirmação ao paciente.

  O teste que mais importa aqui é o da **turma**: entrar num bloco existente dispara o notifier
  para o bloco inteiro, e sem a dedupe quem já estava lá receberia a confirmação de novo a cada
  colega novo.
  """
  # `async: false`: os testes de falha de entrega trocam o adapter do mailer por
  # `Application.put_env`, que é **global ao nó**. Rodando em paralelo, esta troca alcança outro
  # teste no meio do envio dele — e o sintoma é um `refute_email_sent` que falha uma vez a cada
  # tantas execuções, no arquivo errado. Mesmo motivo de `access_revoked_email_test.exs`.
  alias Api.Messaging

  use Api.DataCase, async: false

  describe "confirmação automática na criação" do
    test "agendamento novo gera a confirmação do participante" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")

      appt = agendamento!(ctx, paciente: paciente)

      assert [message] = mensagens(ctx, appt)
      assert message.kind == :confirmacao
      assert message.destino == "ana@example.com"
      # Automático: ninguém clicou.
      assert message.disparado_por_id == nil
    end

    test "paciente sem consentimento não gera mensagem nenhuma" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: false, email: "ana@example.com")

      appt = agendamento!(ctx, paciente: paciente)

      assert [] = mensagens(ctx, appt)
    end

    test "clínica com o automático desligado não dispara" do
      ctx = clinica()
      desligar_automatico(ctx)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")

      appt = agendamento!(ctx, paciente: paciente)

      assert [] = mensagens(ctx, appt)
    end

    test "entrar numa turma NÃO reconfirma quem já estava" do
      ctx = clinica(tipo: [grupo: true, capacidade: 4])
      primeiro = paciente_com(ctx, comunicacao: true, email: "um@example.com")
      segundo = paciente_com(ctx, comunicacao: true, email: "dois@example.com")

      quando = Api.Generators.amanha_as(ctx, 9)
      appt = agendamento!(ctx, paciente: primeiro, quando: quando)

      # Mesmo horário, mesmo profissional, mesmo tipo de grupo: funde na turma existente.
      _ = agendamento!(ctx, paciente: segundo, quando: quando)

      destinos = ctx |> mensagens(appt) |> Enum.map(& &1.destino) |> Enum.sort()

      assert destinos == ["dois@example.com", "um@example.com"]
    end

    test "escrita de LOTE não dispara confirmação — nem aqui, nem na caixa do sino" do
      # A marca `bulk_pacote` é a mesma nos DOIS notifiers, em duas cláusulas idênticas. O
      # bate-volta apontou a duplicação; a extração piora o código (função não casa em head), então
      # a invariante fica presa aqui: quem trocar a marca em `Api.Packages.Bulk` e esquecer um dos
      # assinantes vê ESTE teste vermelho — e não 40 e-mails saindo, sem erro nenhum.
      # O automático fica DESLIGADO na criação de propósito: com ele ligado, o agendamento já
      # nasceria confirmado e a dedupe (`ja_confirmada?/2`) suprimiria o segundo envio — o teste
      # ficaria verde mesmo com a supressão do lote quebrada. Foi exatamente assim que ele nasceu
      # decorativo, e a mutação da marca provou.
      ctx = clinica()
      desligar_automatico(ctx)
      paciente = paciente_com(ctx, comunicacao: true, email: "lote@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      assert [] = mensagens(ctx, appt), "o setup precisa começar sem mensagem nenhuma"

      # E religa: a partir daqui, o único motivo para NÃO sair mensagem é a marca do lote.
      religar_automatico(ctx)

      # Simula o que a materialização de pacote faz: a mesma ação, com a marca no contexto.
      notificacao = %Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: :schedule},
        data: appt,
        changeset: %{context: %{bulk_pacote: true}}
      }

      assert :ok = Api.Messaging.Notifier.notify(notificacao)
      assert :ok = Api.Notifications.Notifier.notify(notificacao)

      assert [] = mensagens(ctx, appt),
             "a escrita de lote gerou mensagem: a supressão do `bulk_pacote` quebrou"
    end

    test "falha ao comunicar não derruba o agendamento" do
      # O agendamento é o fato; a mensagem é o aviso sobre ele. Inverter faria a agenda depender
      # de um provider externo estar de pé.
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")

      appt =
        Api.Support.FailingMailer.with_failure(fn -> agendamento!(ctx, paciente: paciente) end)

      assert appt.id
    end
  end

  # ---- helpers ----

  defp religar_automatico(ctx) do
    Api.Accounts.update_clinic_messaging!(recarregar_clinica(ctx), %{msg_confirmacao_auto: true},
      actor: ctx.owner
    )
  end

  defp recarregar_clinica(ctx),
    do: Api.Accounts.get_clinic!(ctx.clinic.id, actor: ctx.owner)

  defp desligar_automatico(ctx) do
    Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_confirmacao_auto: false},
      actor: ctx.owner
    )
  end
end
