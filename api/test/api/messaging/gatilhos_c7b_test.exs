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

  # Uma confirmação PENDENTE na fila, disparada à mão pela recepção — o que a criação do bloco
  # fazia sozinha até 2026-07-31 (doc 98). É o estado que os descartes existem para varrer, e ele
  # não nasce mais de graça: sem este disparo os três testes de descarte não teriam o que descartar
  # e ficariam verdes sem provar nada.
  defp confirmacao_na_fila!(ctx, appt, paciente) do
    [presenca] = appt.attendances

    {:ok, message} =
      Api.Messaging.Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)

    message
  end

  describe "ciclo de vida do bloco" do
    test "remarcar avisa o paciente QUANDO PEDIDO, com o horário NOVO" do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, _} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reschedule,
          %{starts_at: Api.Generators.proximo_dia_util_as(ctx, 16), avisar_paciente: true},
          appt.version
        )

      assert :remarcacao in kinds(ctx, appt)

      remarcacao = ctx |> mensagens(appt) |> Enum.find(&(&1.kind == :remarcacao))
      assert remarcacao.vars["hora"] == "16:00"
    end

    test "cancelar avisa QUANDO PEDIDO — e este é o que a cascata quase engoliu" do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, _} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :cancel,
          %{avisar_paciente: true},
          appt.version
        )

      assert :cancelamento in kinds(ctx, appt)
    end

    test "sem pedir, remarcar e cancelar NÃO falam com o paciente" do
      # O default é o silêncio (2026-08-01). A pergunta passou a ser da recepção, no modal — e o
      # default precisa ser `false` pelo mesmo motivo que a criação deixou de avisar: mensagem
      # enviada não volta, e no WhatsApp ela é paga.
      #
      # Um default `true` "para não mudar o comportamento" seria pior do que o automático de
      # antes: a tela passaria a prometer uma escolha que o servidor ignora quando o campo não
      # chega — que é exatamente como um checkbox some do FormData.
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, remarcado} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reschedule,
          %{starts_at: Api.Generators.proximo_dia_util_as(ctx, 16)},
          appt.version
        )

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, remarcado.version)

      assert kinds(ctx, appt) == []
    end

    test "numa TURMA, a escolha vale para o bloco — os quatro recebem ou nenhum recebe" do
      # O disparo sempre foi por bloco, e continua: remarcar move a turma inteira, então a
      # pergunta é uma só. O que mudou é que agora ela é feita.
      ctx = clinica(tipo: [grupo: true, capacidade: 4])
      pacientes = for _ <- 1..3, do: paciente_alcancavel(ctx)

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: Api.Generators.proximo_dia_util_as(ctx, 10),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: Enum.map(pacientes, & &1.id)
          },
          scope: ctx.scope
        )

      {:ok, _} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :cancel,
          %{avisar_paciente: true},
          appt.version
        )

      assert length(Enum.filter(kinds(ctx, appt), &(&1 == :cancelamento))) == 3
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

      # Nada: criar não fala com o paciente (desde 2026-07-31) e excluir também não.
      assert kinds(ctx, appt) == []
    end

    test "reabrir NÃO avisa" do
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)

      {:ok, cancelado} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :cancel,
          %{avisar_paciente: true},
          appt.version
        )

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :reopen, %{}, cancelado.version)

      # Só o cancelamento. Reabrir não acrescenta nada: quase sempre é um clique errado sendo
      # desfeito segundos depois.
      assert kinds(ctx, appt) == [:cancelamento]
    end

    test "cancelar descarta a confirmação que ainda estava na fila" do
      # A janela de silêncio (§7) **adia**: uma confirmação disparada às 22h fica parada até as 8h.
      # Se o bloco for cancelado às 22h45, nada tirava aquela linha da fila — e às 8h o paciente
      # recebia "sua sessão está marcada para 28/07 às 12:00" de uma sessão que já não existe,
      # seguida do cancelamento. Mensagem enviada não volta.
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)
      confirmacao = confirmacao_na_fila!(ctx, appt, paciente)

      assert confirmacao.status == :pendente

      {:ok, _} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :cancel,
          %{avisar_paciente: true},
          appt.version
        )

      descartada = recarregar_mensagem(ctx, confirmacao)

      assert descartada.status == :descartada
      assert descartada.descarte_motivo == :sessao_cancelada
      assert descartada.descartada_em

      # E o cancelamento, esse sim, continua a caminho.
      assert :cancelamento in kinds(ctx, appt)
    end

    test "excluir descarta a confirmação que ainda estava na fila" do
      # Excluir é corrigir um lançamento errado (doc 40), e a decisão de não avisar o paciente
      # (acima) morria aqui: a confirmação que a recepção já tinha disparado seguia parada na fila
      # e saía às 8h. Quem apagou uma duplicata teria acabado de dizer a alguém que a sessão existe.
      ctx = clinica()
      paciente = paciente_alcancavel(ctx)
      appt = agendamento!(ctx, paciente: paciente)
      confirmacao = confirmacao_na_fila!(ctx, appt, paciente)

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
      confirmacao = confirmacao_na_fila!(ctx, appt, paciente)

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
          %{starts_at: Api.Generators.proximo_dia_util_as(ctx, 16), avisar_paciente: true},
          appt.version
        )

      {:ok, _} =
        Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reschedule,
          %{starts_at: Api.Generators.proximo_dia_util_as(ctx, 17), avisar_paciente: true},
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

    test "remarcar a série NÃO manda mensagem nenhuma ao paciente", %{
      ctx: ctx,
      pkg: pkg,
      paciente: paciente
    } do
      # Já mandou UMA — era o desenho até 2026-08-01, e existia para não mandar 40. O disparo saiu
      # inteiro: quem avisa o paciente de mudança em pacote é a recepção, pelo telefone que agora
      # vai dentro de toda mensagem. O template `pacote_remarcado_v1` continua no código, sem
      # gatilho, para renderizar histórico.
      {:ok, %{afetadas: afetadas}} =
        Packages.bulk_adjust(ctx.scope, pkg.id, %{
          escopo: :todas,
          aplicar_horario: true,
          hhmm: "09:00"
        })

      assert afetadas > 1
      assert mensagens_do_paciente(ctx, paciente, :pacote_remarcado) == []
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

    test "cancelar a série também não fala com o paciente", %{
      ctx: ctx,
      pkg: pkg,
      paciente: paciente
    } do
      # O par do teste acima. **Nem por sessão, nem em lote** — e o teste vizinho garante que a
      # caixa do profissional continua sendo avisada, que é a metade que ficou.
      {:ok, %{afetadas: afetadas}} = Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert afetadas > 1
      assert mensagens_do_paciente(ctx, paciente, :pacote_cancelado) == []
      assert mensagens_do_paciente(ctx, paciente, :cancelamento) == []
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
