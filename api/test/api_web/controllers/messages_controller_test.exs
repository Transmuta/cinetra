defmodule ApiWeb.MessagesControllerTest do
  @moduledoc """
  A timeline e o disparo manual na fronteira (doc 52 §6).

  O teste que mais importa é o do **silêncio explicado**: a linha "nada enviado, e por quê" é o
  que separa esta tela de uma que parece funcionar. Sem ela a recepção supõe que a mensagem saiu.
  """
  use ApiWeb.ConnCase, async: true

  setup do
    ctx = clinica()

    # A recepção é quem opera a comunicação no balcão — é o papel certo para exercer a fronteira.
    sessao = as(sessao_de_membro!(ctx.owner, ctx.clinic, :recepcao))
    %{ctx: ctx, sessao: sessao}
  end

  describe "GET /api/appointments/:id/messages" do
    test "traz a mensagem automática do participante", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["paciente"] == paciente.nome
      assert linha["semEnvio"] == nil

      assert [%{"kind" => "confirmacao", "automatico" => true, "status" => "pendente"}] =
               linha["mensagens"]
    end

    test "cancelado dentro do silêncio, a linha para de prometer envio e diz por quê", %{
      ctx: ctx,
      sessao: sessao
    } do
      # O bug relatado ao vivo em 2026-07-29, e ele **só existe atravessando a fronteira**: era
      # aqui, nesta linha, que a recepção lia "Confirmação por e-mail · Na fila · sai qua., 08:00"
      # para uma sessão que já não ia acontecer. `agendadoPara` é o que vira aquela promessa na
      # tela, e depois do descarte ele não pode mais governar a linha.
      #
      # O caminho passa por **reabrir**, e não por acaso: o `carregar/2` só lista participante
      # **vivo**, então num bloco cancelado a timeline vem vazia e ninguém lê nada. Reabrir (o
      # desfazer do clique errado, D-E4.2) traz a presença de volta — e é exatamente aí que saber
      # que a confirmação nunca saiu decide o próximo passo da recepção.
      silenciar_agora(ctx)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [antes]} = get_json(sessao, appt)

      assert [%{"status" => "pendente", "agendadoPara" => quando} = confirmacao] =
               antes["mensagens"]

      assert quando != nil

      {:ok, cancelado} =
        Api.Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      {:ok, _} =
        Api.Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reopen,
          %{},
          cancelado.version
        )

      %{"participantes" => [depois]} = get_json(sessao, appt)
      linha = Enum.find(depois["mensagens"], &(&1["id"] == confirmacao["id"]))

      assert linha["status"] == "descartada"
      assert linha["descarteMotivo"] == "sessao_cancelada"
      assert linha["descartadaEm"] != nil
    end

    test "explica o silêncio de quem não tem contato", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_legado_sem_tel!(ctx, comunicacao: true, email: nil)
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["mensagens"] == []
      assert linha["semEnvio"] == "sem_contato"
    end

    test "explica o silêncio de quem não autorizou", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: false, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["semEnvio"] == "sem_consentimento"
    end

    test "explica o silêncio de quem pediu para parar", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: true, email: "parou@example.com")
      Api.Messaging.opt_out(:email, "parou@example.com", "link")
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["semEnvio"] == "opt_out"
    end

    test "uma linha por participante da turma", %{ctx: ctx, sessao: sessao} do
      turma = clinica_turma(ctx)
      um = paciente_com(ctx, comunicacao: true, email: "um@example.com")
      dois = paciente_legado_sem_tel!(ctx, comunicacao: true, email: nil)
      quando = Api.Generators.amanha_as(ctx, 15)

      appt = agendamento!(ctx, paciente: um, tipo: turma, quando: quando)
      _ = agendamento!(ctx, paciente: dois, tipo: turma, quando: quando)

      %{"participantes" => linhas} = get_json(sessao, appt)

      assert length(linhas) == 2
      # Numa turma, "confirmação enviada" no bloco mentiria para quem não recebeu (§3).
      assert Enum.any?(linhas, &(&1["semEnvio"] == "sem_contato"))
      assert Enum.any?(linhas, &(&1["mensagens"] != []))
    end

    test "o motivo do provider chega traduzido — inglês na tela vira chamado de suporte", %{
      ctx: ctx,
      sessao: sessao
    } do
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [message] = mensagens_do(ctx, appt)

      Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
        Api.Messaging.do_advance_message!(
          message,
          %{novo_status: :falhou, erro: "mailbox does not exist"},
          tenant: ctx.clinic.id,
          authorize?: false
        )
      end)

      %{"participantes" => [linha]} = get_json(sessao, appt)
      [m] = linha["mensagens"]

      # O cru continua disponível para o suporte investigar…
      assert m["erro"] == "mailbox does not exist"
      # …e o que a tela mostra é a AÇÃO, em português.
      assert m["erroTexto"] =~ "confira o endereço na ficha"
    end

    test "agendamento de outra clínica responde 404", %{sessao: sessao} do
      outra = clinica()
      appt = agendamento!(outra)

      conn = get(sessao, ~p"/api/appointments/#{appt.id}/messages")

      assert json_response(conn, 404)
    end

    test "sem sessão, 401" do
      conn = get(build_conn(), ~p"/api/appointments/#{Ash.UUID.generate()}/messages")

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/appointments/:id/messages" do
    test "reenvia e registra QUEM disparou", %{ctx: ctx, sessao: sessao} do
      sem_confirmacao_automatica(ctx)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      conn = post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{})

      assert %{"resultados" => [%{"enviado" => true}]} = json_response(conn, 201)

      %{"participantes" => [linha]} = get_json(sessao, appt)
      manual = Enum.find(linha["mensagens"], &(&1["automatico"] == false))
      assert manual
    end

    test "dentro do silêncio, a resposta diz que foi ADIADA", %{ctx: ctx, sessao: sessao} do
      # 201 sem esta informação vira "Mensagem enviada" na tela para algo que ainda está na fila —
      # o mesmo "Feito" que não enviava, agora por outra causa (§7). A janela é ancorada na hora
      # local corrente porque o envio lê o relógio por dentro; horas fixas passariam de manhã e
      # falhariam de madrugada.
      silenciar_agora(ctx)
      sem_confirmacao_automatica(ctx)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      conn = post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{})

      assert %{"resultados" => [%{"enviado" => true, "agendadoPara" => quando}]} =
               json_response(conn, 201)

      assert quando != nil

      # E a timeline devolve o mesmo instante — é dele que sai o "sai às 8h" da tela. Vale para
      # as duas linhas: a automática da criação do bloco caiu na mesma janela.
      %{"participantes" => [linha]} = get_json(sessao, appt)
      assert Enum.all?(linha["mensagens"], &(&1["agendadoPara"] == quando))
    end

    test "com uma confirmação já na fila, o segundo clique não empilha outra", %{
      ctx: ctx,
      sessao: sessao
    } do
      # O caso que motivou a trava, e ele é o COMUM: dentro da janela de silêncio a confirmação
      # automática da criação fica horas parada, quem clica não vê nada acontecer e clica de novo.
      # Medido no dev de 2026-07-28: quatro linhas idênticas para o mesmo paciente.
      silenciar_agora(ctx)
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      conn = post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{})

      assert %{"resultados" => [%{"enviado" => false, "motivo" => "ja_na_fila"}]} =
               json_response(conn, 201)

      # E a fila continua com UMA: a automática da criação.
      %{"participantes" => [linha]} = get_json(sessao, appt)
      assert length(linha["mensagens"]) == 1
    end

    test "quem já confirmou não recebe outra — e o motivo chega à tela", %{
      ctx: ctx,
      sessao: sessao
    } do
      # O par da regra de UI: o botão do rodapé fica desabilitado, mas na turma ele continua de pé
      # por causa dos outros participantes. Quando o clique alcança quem já confirmou, o servidor
      # recusa e o motivo é o que o toast escreve.
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      [confirmacao] = mensagens_do(ctx, appt)
      responder!(ctx, confirmacao, :confirmou)

      conn = post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{})

      assert %{"resultados" => [%{"enviado" => false, "motivo" => "ja_confirmou"}]} =
               json_response(conn, 201)
    end

    test "a terceira confirmação é recusada com `limite_de_envios`", %{ctx: ctx, sessao: sessao} do
      # O teto contra spam (duas por presença). A primeira é a automática da criação; a segunda é o
      # clique da recepção; a terceira é o paciente sendo cobrado três vezes pela mesma sessão.
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      [automatica] = mensagens_do(ctx, appt)
      entregar!(ctx, automatica)

      assert %{"resultados" => [%{"enviado" => true}]} =
               sessao
               |> post(~p"/api/appointments/#{appt.id}/messages", %{})
               |> json_response(201)

      ctx |> mensagens_do(appt) |> Enum.each(&entregar_se_pendente!(ctx, &1))

      assert %{"resultados" => [%{"enviado" => false, "motivo" => "limite_de_envios"}]} =
               sessao
               |> post(~p"/api/appointments/#{appt.id}/messages", %{})
               |> json_response(201)

      # E a tela vê exatamente duas — é delas que a regra do botão é derivada no cliente.
      %{"participantes" => [linha]} = get_json(sessao, appt)
      assert length(linha["mensagens"]) == 2
    end

    test "devolve o motivo quando não dá para enviar", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: false)
      appt = agendamento!(ctx, paciente: paciente)

      conn = post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{})

      assert %{"resultados" => [%{"enviado" => false, "motivo" => "sem_consentimento"}]} =
               json_response(conn, 201)
    end

    test "com patient_id, não dispara para os outros da turma", %{ctx: ctx, sessao: sessao} do
      # Reenviar para quem falhou não pode mandar de novo para os outros três.
      turma = clinica_turma(ctx)
      um = paciente_com(ctx, comunicacao: true, email: "um@example.com")
      dois = paciente_com(ctx, comunicacao: true, email: "dois@example.com")
      quando = Api.Generators.amanha_as(ctx, 16)

      appt = agendamento!(ctx, paciente: um, tipo: turma, quando: quando)
      _ = agendamento!(ctx, paciente: dois, tipo: turma, quando: quando)

      conn =
        post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{"patient_id" => um.id})

      assert %{"resultados" => [%{"patientId" => id}]} = json_response(conn, 201)
      assert id == um.id
    end
  end

  # ---- helpers ----

  # Põe a clínica DENTRO da janela de silêncio a partir da hora local de agora — o envio lê o
  # relógio por dentro, então a janela precisa ser relativa a ele.
  defp silenciar_agora(ctx) do
    hora = DateTime.utc_now() |> DateTime.shift_zone!(ctx.clinic.timezone) |> Map.fetch!(:hour)

    Api.Accounts.update_clinic_messaging!(
      ctx.clinic,
      %{msg_silencio_inicio: hora, msg_silencio_fim: rem(hora + 2, 24)},
      authorize?: false
    )
  end

  # Desliga a confirmação automática da CRIAÇÃO do bloco. Sem isto, a mensagem que o teste quer
  # disparar à mão esbarra na trava contra duplicata — que é o comportamento certo, e por isso
  # tem teste próprio; aqui o assunto é outro.
  defp sem_confirmacao_automatica(ctx) do
    Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_confirmacao_auto: false},
      authorize?: false
    )
  end

  defp get_json(sessao, appt) do
    sessao
    |> get(~p"/api/appointments/#{appt.id}/messages")
    |> json_response(200)
  end

  defp clinica_turma(ctx), do: Api.Generators.tipo!(ctx, grupo: true, capacidade: 4)

  defp mensagens_do(ctx, appt) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Messaging.list_messages_for_appointment!(appt.id,
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end

  # "Chegou ao paciente" — é o que gasta uma unidade do teto de confirmações. Pela ação do domínio,
  # não por `Ash.Seed`: é a própria máquina de entrega que o teto consulta.
  defp entregar!(ctx, message) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Messaging.do_mark_sent!(
        message,
        %{provider: "resend", provider_message_id: "prov-#{Api.Generators.unico()}"},
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end

  defp entregar_se_pendente!(ctx, %{status: :pendente} = message), do: entregar!(ctx, message)
  defp entregar_se_pendente!(_ctx, message), do: message

  defp responder!(ctx, message, resposta) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Messaging.do_record_reply!(message, %{resposta: resposta},
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end
end
