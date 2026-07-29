defmodule Api.Messaging.SendJobTest do
  @moduledoc """
  O transporte e a máquina de entrega (doc 52 §4).

  Dois testes carregam o peso: o de **não reenviar** (a retentativa do Oban não pode duplicar
  mensagem para o paciente) e o de **avanço monotônico** (webhook fora de ordem não pode fazer a
  timeline andar para trás).
  """
  # `async: false`: os testes de falha de entrega trocam o adapter do mailer por
  # `Application.put_env`, que é **global ao nó**. Rodando em paralelo, esta troca alcança outro
  # teste no meio do envio dele — e o sintoma é um `refute_email_sent` que falha uma vez a cada
  # tantas execuções, no arquivo errado. Mesmo motivo de `access_revoked_email_test.exs`.
  alias Api.Messaging

  use Api.DataCase, async: false

  import Swoosh.TestAssertions

  alias Api.Messaging.MessageStatus
  alias Api.Messaging.SendJob
  alias Api.Messaging.Templates

  describe "MessageStatus.avanca?/2" do
    test "só anda para a frente" do
      assert MessageStatus.avanca?(:pendente, :enviado)
      assert MessageStatus.avanca?(:enviado, :entregue)
      assert MessageStatus.avanca?(:entregue, :lido)
      refute MessageStatus.avanca?(:entregue, :enviado)
      refute MessageStatus.avanca?(:lido, :entregue)
    end

    test "o mesmo estado não é avanço" do
      refute MessageStatus.avanca?(:enviado, :enviado)
    end

    test "falha não sobrescreve o que já chegou ao destino" do
      # Um `bounce` tardio depois de `delivered` é ruído do provider, não a verdade sobre a
      # entrega. O contrário — falhar o que ainda está em trânsito — é o caso real.
      assert MessageStatus.avanca?(:pendente, :falhou)
      assert MessageStatus.avanca?(:enviado, :falhou)
      refute MessageStatus.avanca?(:entregue, :falhou)
      refute MessageStatus.avanca?(:lido, :falhou)
    end

    test "falha é terminal" do
      refute MessageStatus.avanca?(:falhou, :entregue)
      refute MessageStatus.avanca?(:falhou, :enviado)
    end
  end

  describe "Templates" do
    test "todo kind tem template, e todo template volta ao kind" do
      # O par existe para a timeline: ela renderiza a partir do template GRAVADO, e um kind sem
      # template (ou o contrário) seria uma linha que não se exibe.
      for kind <- [:confirmacao, :lembrete, :remarcacao, :cancelamento] do
        template = Templates.para(kind)
        assert template in Templates.conhecidos()
        assert Templates.kind_de(template) == kind
      end
    end

    test "o nome da clínica entra no assunto — é o §9.1.4, não enfeite" do
      {:ok, %{assunto: assunto, texto: texto}} =
        Templates.render_email("confirmacao_v1", vars())

      assert assunto =~ "Clínica da Ana"
      assert texto =~ "Clínica da Ana"
    end

    test "cumprimenta pelo primeiro nome" do
      {:ok, %{texto: texto}} = Templates.render_email("confirmacao_v1", vars())

      assert texto =~ "Olá, Maria!"
      refute texto =~ "Maria Aparecida"
    end

    test "sem link, a mensagem sai sem o bloco de resposta (e não quebra)" do
      {:ok, %{texto: texto}} =
        Templates.render_email("confirmacao_v1", Map.delete(vars(), "link"))

      refute texto =~ "confirmar ou pedir remarcação"
      assert texto =~ "10/08/2026"
    end

    test "variável que sumiu da ficha não vira 'Olá, !' nem derruba o render" do
      {:ok, %{texto: texto}} = Templates.render_email("confirmacao_v1", %{})

      assert texto =~ "Olá, —!"
    end

    test "template desconhecido devolve :error em vez de levantar" do
      # A timeline exibe linhas antigas; um template retirado do código não pode derrubar a
      # leitura da tela inteira.
      assert Templates.render_email("promocao_v7", vars()) == :error
    end
  end

  describe "perform/1" do
    setup do
      ctx = clinica()

      # A confirmação automática da criação do bloco fica na fila e a trava contra duplicata
      # recusaria o disparo à mão logo abaixo — que é o comportamento certo (`dispatch_test.exs`
      # o prova). Aqui o assunto é o job, e ele precisa de uma mensagem própria.
      Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_confirmacao_auto: false},
        authorize?: false
      )

      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      {:ok, message} =
        Messaging.Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)

      %{ctx: ctx, message: message}
    end

    test "envia e marca como enviada", %{ctx: ctx, message: message} do
      assert :ok = perform_job(ctx, message)

      assert_email_sent(fn email ->
        assert {_nome, "ana@example.com"} = hd(email.to)
        assert email.subject =~ ctx.clinic.nome
        # O link de resposta é montado no envio, a partir do id da mensagem (§5).
        assert email.text_body =~ "/confirmar/"
      end)

      assert %{status: :enviado, enviado_em: %DateTime{}} = recarregar_mensagem(ctx, message)
    end

    test "não reenvia mensagem que já saiu", %{ctx: ctx, message: message} do
      assert :ok = perform_job(ctx, message)
      assert_email_sent()

      # A retentativa do Oban roda o mesmo job de novo. Sem a guarda de estado, o paciente
      # receberia a mesma confirmação duas vezes.
      assert :ok = perform_job(ctx, message)
      refute_email_sent()
    end

    test "falha do transporte vira estado e motivo legível, sem levantar", %{
      ctx: ctx,
      message: message
    } do
      Api.Support.FailingMailer.with_failure(fn ->
        assert :ok = perform_job(ctx, message)
      end)

      recarregada = recarregar_mensagem(ctx, message)
      assert recarregada.status == :falhou
      assert recarregada.falhou_em
      assert is_binary(recarregada.erro)
    end

    test "o log da falha NÃO carrega o endereço do paciente", %{ctx: ctx, message: message} do
      # Doc 62 §7.3. O texto cru do provider é o que vai para a coluna `erro` (sob RLS, para a
      # clínica ler) — mas o LOG vai para a agregação, que tem retenção mais frouxa e público
      # mais amplo. Um bounce de e-mail embute o destinatário; logá-lo cru põe PII de titular
      # num sistema de terceiro.
      cru = "550 5.1.1 <ana@example.com>: Recipient address rejected: User unknown"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Api.Support.FailingMailer.with_failure(cru, fn ->
            assert :ok = perform_job(ctx, message)
          end)
        end)

      assert log =~ "falhou"
      refute log =~ "@", "o log carregou um endereço de e-mail: #{log}"
      refute log =~ "ana", "o log carregou o destinatário: #{log}"

      # E o texto cru continua onde deve estar: no registro da mensagem.
      assert recarregar_mensagem(ctx, message).erro =~ "ana@example.com"
    end

    test "mensagem que sumiu não derruba o job", %{ctx: ctx} do
      assert :ok =
               SendJob.perform(%Oban.Job{
                 args: %{"clinic_id" => ctx.clinic.id, "message_id" => Ash.UUID.generate()}
               })
    end
  end

  describe "advance (webhook fora de ordem)" do
    test "um `sent` atrasado não rebaixa uma mensagem já entregue" do
      ctx = clinica()

      # Ver a nota do `setup` acima: sem desligar a automática, a trava contra duplicata recusa
      # o disparo à mão e o teste não chega a ter mensagem para avançar.
      Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_confirmacao_auto: false},
        authorize?: false
      )

      paciente = paciente_com(ctx, comunicacao: true, email: "b@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, message} =
        Messaging.Dispatch.dispatch(ctx.clinic, hd(appt.attendances), paciente, :confirmacao)

      entregue = avancar(ctx, message, :entregue)
      assert entregue.status == :entregue

      # Chega agora o `sent`, que saiu antes mas trafegou mais devagar.
      depois = avancar(ctx, entregue, :enviado)

      assert depois.status == :entregue
      assert depois.entregue_em == entregue.entregue_em
    end
  end

  # ---- helpers ----

  defp vars do
    %{
      "clinica" => "Clínica da Ana",
      "paciente" => "Maria Aparecida",
      "data" => "10/08/2026",
      "hora" => "09:00",
      "link" => "https://exemplo/confirmar/abc"
    }
  end

  defp perform_job(ctx, message) do
    SendJob.perform(%Oban.Job{
      args: %{"clinic_id" => ctx.clinic.id, "message_id" => message.id}
    })
  end

  defp avancar(ctx, message, status) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Messaging.do_advance_message!(message, %{novo_status: status},
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end
end
