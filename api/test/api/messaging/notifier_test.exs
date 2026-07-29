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

    test "pacote materializado não manda uma confirmação por sessão — o caminho REAL" do
      # O teste acima prova que a **cláusula** suprime; este prova que a **marca chega nela**. São
      # coisas diferentes, e a diferença era o bug: o moduledoc do notifier dizia que a marca
      # existia para a "materialização de pacote", mas ela só era posta em `Api.Packages.Bulk`
      # (ajuste/cancelamento em massa). O caminho da **criação** —
      # `Api.Packages.Sessions.create_and_stamp/5` → `schedule_appointment/2` — ia sem contexto
      # nenhum, e um pacote de N enfileirava N confirmações para o mesmo paciente.
      #
      # Passava despercebido porque as mensagens saíam uma a uma; com a janela de silêncio (§7)
      # elas ficam paradas e chegam **todas juntas** às 8h. Num pacote de 40, no WhatsApp, são 40
      # mensagens pagas para o mesmo número em segundos — o §9.1.1 de novo.
      ctx = clinica(tipo: [nome: "Pilates #{unico()}"])
      paciente = paciente_com(ctx, comunicacao: true, email: "pacote@example.com")

      {:ok, pkg} = Api.Packages.create_series(ctx.scope, serie(ctx, paciente))

      Oban.drain_queue(queue: :housekeeping)

      sessoes = sessoes_do_pacote(ctx, pkg)
      assert length(sessoes) == 4, "a materialização precisa ter criado as 4 sessões"

      assert Enum.flat_map(sessoes, &mensagens(ctx, &1)) == [],
             "o pacote falou com o paciente uma vez por sessão: a marca `bulk_pacote` não chega " <>
               "à materialização"
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

  # A mesma grade do `Api.Packages.MaterializeTest`: 4 sessões em segundas e quartas.
  defp serie(ctx, paciente) do
    %{
      nome: "Pilates 4",
      total: 4,
      falta_punitiva: true,
      cor: "#0FB5A6",
      data_inicio: ~D[2026-07-20],
      patient_id: paciente.id,
      appointment_type_id: ctx.tipo.id,
      grade: %{
        dows: [1, 3],
        horarios: %{"1" => "08:00", "3" => "09:00"},
        professional_id: ctx.prof.id
      }
    }
  end

  # Os blocos que a materialização criou, pelo carimbo `package_id` da presença — o mesmo vínculo
  # que o `usadas` conta (D11).
  defp sessoes_do_pacote(ctx, pkg) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Scheduling.list_attendances!(
        tenant: ctx.clinic.id,
        authorize?: false,
        query: [filter: [package_id: pkg.id]],
        load: [:appointment]
      )
    end)
    |> Enum.map(& &1.appointment)
  end

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
