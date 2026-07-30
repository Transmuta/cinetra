defmodule Api.Messaging.GatilhosC7bTest do
  @moduledoc """
  Os gatilhos que o C7(b) destravou (doc 65 §2): remarcação, cancelamento e exclusão avisam o
  paciente — e a massa por pacote avisa **uma vez**, não uma por sessão.

  Dois testes aqui valem por si:

    * **cancelar avisa** — a cascata do cancelamento derruba as presenças para `:cancelada`
      *antes* de o notifier rodar, então filtrar por "presença viva" (o que os outros gatilhos
      fazem) devolveria lista vazia e ninguém receberia a mensagem que mais importa;
    * **a massa manda uma** — 40 sessões remarcadas mandariam 40 mensagens de WhatsApp **pagas**
      para o mesmo telefone, em segundos. É assim que se perde um número por bloqueio.
  """
  use Api.DataCase, async: false

  require Ash.Query

  alias Api.Packages
  alias Api.Scheduling

  defp paciente_alcancavel(ctx),
    do: paciente_com(ctx, comunicacao: true, email: "p#{Api.Generators.unico()}@example.com")

  defp kinds(ctx, appt), do: ctx |> mensagens(appt) |> Enum.map(& &1.kind)

  describe "ciclo de vida do bloco" do
    test "remarcar avisa o paciente, com o horário NOVO" do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, _} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reschedule,
          %{starts_at: Api.Generators.amanha_as(ctx, 16)},
          appt.version
        )

      assert :remarcacao in kinds(ctx, appt)

      remarcacao = ctx |> mensagens(appt) |> Enum.find(&(&1.kind == :remarcacao))
      assert remarcacao.vars["hora"] == "16:00"
    end

    test "cancelar avisa — e este é o que a cascata quase engoliu" do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      assert :cancelamento in kinds(ctx, appt)
    end

    test "excluir NÃO avisa — é correção de lançamento, não desmarcação" do
      # Excluir (doc 40) é o gesto de apagar um lançamento feito por engano. Avisar o paciente
      # daria a ele efeito **fora** do sistema, que não volta: quem apagou uma duplicata teria
      # acabado de dizer a alguém que a sessão foi desmarcada. Quem quer desmarcar cancela.
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :exclude, %{}, appt.version)

      # Só a confirmação da criação; nada de cancelamento.
      assert kinds(ctx, appt) == [:confirmacao]
    end

    test "reabrir NÃO avisa" do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, cancelado} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :reopen, %{}, cancelado.version)

      # Uma confirmação (da criação) e um cancelamento. Reabrir não acrescenta nada: quase sempre
      # é um clique errado sendo desfeito segundos depois.
      assert Enum.sort(kinds(ctx, appt)) == [:cancelamento, :confirmacao]
    end

    test "cancelar descarta a confirmação que ainda estava na fila" do
      # A janela de silêncio (§7) **adia**: uma confirmação criada às 22h fica parada até as 8h.
      # Se o bloco for cancelado às 22h45, nada tirava aquela linha da fila — e às 8h o paciente
      # recebia "sua sessão está marcada para 28/07 às 12:00" de uma sessão que já não existe,
      # seguida do cancelamento. Mensagem enviada não volta.
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      assert [confirmacao] = mensagens(ctx, appt)
      assert confirmacao.status == :pendente

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      descartada = recarregar_mensagem(ctx, confirmacao)

      assert descartada.status == :descartada
      assert descartada.descarte_motivo == :sessao_cancelada
      assert descartada.descartada_em

      # E o cancelamento, esse sim, continua a caminho.
      assert :cancelamento in kinds(ctx, appt)
    end

    test "excluir descarta a confirmação que ainda estava na fila" do
      # Excluir é corrigir um lançamento errado (doc 40), e a decisão de não avisar o paciente
      # (acima) morria aqui: a confirmação da criação seguia parada na fila e saía às 8h. Quem
      # apagou uma duplicata teria acabado de dizer a alguém que a sessão dele existe.
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      assert [confirmacao] = mensagens(ctx, appt)

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :exclude, %{}, appt.version)

      descartada = recarregar_mensagem(ctx, confirmacao)

      assert descartada.status == :descartada
      assert descartada.descarte_motivo == :agendamento_excluido
    end

    test "o que JÁ SAIU não é descartado — descartar é tirar da fila, não reescrever a história" do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      assert [confirmacao] = mensagens(ctx, appt)

      enviada =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Messaging.do_mark_sent!(
            confirmacao,
            %{provider: "resend", provider_message_id: "x"},
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      assert recarregar_mensagem(ctx, enviada).status == :enviado
    end

    test "remarcar duas vezes avisa duas vezes" do
      # Diferente da confirmação, que é deduplicada: o segundo aviso de remarcação é tão
      # necessário quanto o primeiro, porque o horário mudou de novo.
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, uma} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reschedule,
          %{starts_at: Api.Generators.amanha_as(ctx, 16)},
          appt.version
        )

      {:ok, _} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reschedule,
          %{starts_at: Api.Generators.amanha_as(ctx, 17)},
          uma.version
        )

      assert Enum.count(kinds(ctx, appt), &(&1 == :remarcacao)) == 2
    end

    test "paciente sem consentimento não recebe nada, em nenhum gatilho" do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: false, email: "nao@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      assert mensagens(ctx, appt) == []
    end
  end

  describe "massa por pacote: uma mensagem, não N" do
    setup do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)

      segunda = Date.add(Date.utc_today(), 7 - Date.day_of_week(Date.utc_today()) + 1)

      pkg =
        Packages.create_package!(
          %{
            nome: "Pilates 10",
            total: 10,
            falta_punitiva: true,
            cor: "#0FB5A6",
            data_inicio: segunda,
            patient_id: paciente.id,
            appointment_type_id: ctx.tipo.id,
            grade: %{dows: [1], horarios: %{"1" => "08:00"}, professional_id: ctx.prof.id}
          },
          scope: ctx.scope
        )

      # As sessões são criadas à mão (e não pelo materializador) para o teste falar de três
      # sessões conhecidas, no futuro, sem depender do calendário do dia em que ele roda.
      for i <- 0..2 do
        {:ok, dt} =
          Scheduling.LocalTime.to_utc(Date.add(segunda, 7 * i), "08:00", ctx.clinic.timezone)

        {:ok, _} =
          Scheduling.schedule_appointment(
            %{
              starts_at: dt,
              professional_id: ctx.prof.id,
              appointment_type_id: ctx.tipo.id,
              patient_ids: [paciente.id],
              package_id: pkg.id
            },
            scope: ctx.scope
          )
      end

      %{ctx: ctx, pkg: pkg, paciente: paciente}
    end

    test "remarcar a série manda UMA mensagem com o número dentro", %{
      ctx: ctx,
      pkg: pkg,
      paciente: paciente
    } do
      {:ok, %{afetadas: afetadas}} =
        Packages.bulk_adjust(ctx.scope, pkg.id, %{
          escopo: :todas,
          aplicar_horario: true,
          hhmm: "09:00"
        })

      assert afetadas > 1

      lote = mensagens_do_paciente(ctx, paciente, :pacote_remarcado)

      assert length(lote) == 1
      assert hd(lote).vars["quantas"] == Api.Texto.sessoes(afetadas)
      assert hd(lote).vars["pacote"] == "Pilates 10"
    end

    test "e nenhuma mensagem por sessão junto", %{ctx: ctx, pkg: pkg, paciente: paciente} do
      Packages.bulk_adjust(ctx.scope, pkg.id, %{
        escopo: :todas,
        aplicar_horario: true,
        hhmm: "09:00"
      })

      assert mensagens_do_paciente(ctx, paciente, :remarcacao) == []
    end

    test "cancelar a série avisa o PROFISSIONAL na caixa, uma vez", %{ctx: ctx, pkg: pkg} do
      # O buraco que o bate-volta achou: as notificações por sessão são suprimidas pela marca de
      # lote, e o `cancel` nunca teve o aviso único que o `adjust` tem. Cancelar um pacote de 40
      # sessões não punha nada na caixa do dono da coluna — o paciente sabia, o profissional não.
      dono = escopo_de_membro!(ctx, :profissional, ctx.prof.id)

      {:ok, %{afetadas: afetadas}} = Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert afetadas > 1

      caixa = Api.Notifications.list_inbox(dono).results

      assert [notificacao] = Enum.filter(caixa, &(&1.kind == :package_bulk_canceled))
      assert notificacao.body =~ Api.Texto.sessoes(afetadas)
      assert notificacao.body =~ "Pilates 10"
    end

    test "cancelar a série também manda UMA", %{ctx: ctx, pkg: pkg, paciente: paciente} do
      {:ok, %{afetadas: afetadas}} =
        Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert afetadas > 1
      assert [uma] = mensagens_do_paciente(ctx, paciente, :pacote_cancelado)
      assert uma.vars["quantas"] == Api.Texto.sessoes(afetadas)
    end
  end

  defp mensagens_do_paciente(ctx, paciente, kind) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Messaging.Message
      |> Ash.Query.for_read(:read, %{}, tenant: ctx.clinic.id, authorize?: false)
      |> Ash.Query.filter(patient_id == ^paciente.id and kind == ^kind)
      |> Ash.read!(authorize?: false)
    end)
  end
end
