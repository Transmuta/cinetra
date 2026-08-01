defmodule ApiWeb.PatientReplyControllerTest do
  @moduledoc """
  A resposta do paciente pelo link assinado (doc 52 §5).

  É a única rota do projeto que fala com quem não tem sessão e não é autenticação, então o que
  precisa estar provado aqui é **o que o token não dá**: ele responde por uma mensagem e não abre
  acesso a mais nada.
  """

  use ApiWeb.ConnCase, async: true

  alias Api.Messaging.ReplyToken

  setup do
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com", nome: "Ana Beatriz")
    appt = agendamento!(ctx, paciente: paciente)
    # Disparada à mão: criar o bloco não fala mais com o paciente (doc 98).
    message = confirmacao!(ctx, appt, paciente)

    %{ctx: ctx, message: message, token: ReplyToken.sign(message.id)}
  end

  describe "GET /api/reply/:token" do
    test "mostra a sessão, e só o necessário", %{conn: conn, token: token, ctx: ctx} do
      body = conn |> get(~p"/api/reply/#{token}") |> json_response(200)

      assert body["clinica"] == ctx.clinic.nome
      # Primeiro nome, não o nome completo: quem abre é quem tem o link, e link se encaminha.
      assert body["paciente"] == "Ana"
      assert body["data"]
      assert body["hora"]
      # Nada de ficha, telefone, e-mail ou outros participantes.
      refute Map.has_key?(body, "email")
      refute Map.has_key?(body, "telefone")
      refute Map.has_key?(body, "participantes")
    end

    test "token inválido responde 404, sem dizer se a mensagem existe", %{conn: conn} do
      conn = get(conn, ~p"/api/reply/nao-e-um-token")

      assert json_response(conn, 404)["error"] == "link_invalido"
    end

    test "token vencido responde 410 com motivo acionável", %{conn: conn, message: message} do
      # 410 e não 404: a página precisa dizer "este link expirou", que é acionável.
      velho =
        ReplyToken.sign(message.id, signed_at: System.system_time(:second) - 60 * 60 * 24 * 40)

      conn = get(conn, ~p"/api/reply/#{velho}")

      assert json_response(conn, 410)["error"] == "link_expirado"
    end
  end

  describe "POST /api/reply/:token" do
    test "confirmar grava a resposta", %{conn: conn, token: token, ctx: ctx, message: message} do
      body =
        conn
        |> post(~p"/api/reply/#{token}", %{"resposta" => "confirmou"})
        |> json_response(200)

      assert body["resposta"] == "confirmou"
      assert recarregar_mensagem(ctx, message).resposta == :confirmou
    end

    test "pedir remarcação NÃO remarca — só registra", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})

      assert recarregar_mensagem(ctx, message).resposta == :quer_remarcar

      # O bloco continua onde estava: escolher horário pela pessoa exigiria conhecer regras
      # (expediente, conflito, encaixe) que um clique de fora não conhece.
      appt =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Scheduling.get_appointment!(message.appointment_id,
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)

      assert appt.status == :agendado
    end

    test "pedir remarcação cai na caixa do operacional (doc 65 §5)", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # É a lacuna que esta fatia fechou: até aqui, um paciente que pedia remarcação só era
      # descoberto por quem abrisse o drawer daquela sessão. E é a única notificação do sistema
      # cujo autor não tem login — por isso o teste tem de atravessar a rota pública, não chamar
      # o fan-out direto (a lição do doc 49: regra que atravessa a fronteira precisa de teste que
      # atravesse a fronteira).
      recepcao = escopo_de_membro!(ctx, :recepcao)

      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})

      assert [notificacao] = caixa(ctx, recepcao)
      assert notificacao.kind == :patient_wants_reschedule
      assert notificacao.title == "Paciente pediu remarcação"
      assert notificacao.body =~ "Ana Beatriz"
    end

    test "responder DUAS vezes não duplica a caixa (a rota é pública)", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # Medido no bate-volta: 5 POSTs do mesmo token criavam 10 notificações (2 destinatários ×
      # 5). A resposta em si já era idempotente — o instante da primeira é preservado —, e o
      # fan-out entrou por cima dela sem essa propriedade. Numa rota **pública e sem rate limit**,
      # isso é um amplificador: quem tem o link enche a caixa da clínica.
      recepcao = escopo_de_membro!(ctx, :recepcao)

      for _ <- 1..3 do
        build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})
      end

      assert [_uma] = caixa(ctx, recepcao)
      _ = conn
    end

    test "mudar de ideia avisa de novo — não é o replay que se está barrando", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # A guarda é sobre **transição**, não sobre "já avisou uma vez": quem confirmou e depois
      # pediu remarcação mudou de ideia, e a recepção precisa saber das duas vezes.
      recepcao = escopo_de_membro!(ctx, :recepcao)

      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})
      build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "confirmou"})
      build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})

      assert length(caixa(ctx, recepcao)) == 2
    end

    test "confirmar NÃO cai na caixa — seria ruído por sessão", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # Numa clínica com ~2.200 presenças/mês, uma linha por confirmação afogaria a caixa da
      # recepção. A confirmação já aparece no status do bloco e na timeline (doc 31 §4).
      recepcao = escopo_de_membro!(ctx, :recepcao)

      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "confirmou"})

      assert caixa(ctx, recepcao) == []
    end

    test "responder duas vezes mantém o primeiro instante e vale a última resposta", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "confirmou"})
      primeira = recarregar_mensagem(ctx, message)

      build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})
      segunda = recarregar_mensagem(ctx, message)

      assert segunda.respondido_em == primeira.respondido_em
      # Mudou de ideia; é a segunda que a recepção precisa ver.
      assert segunda.resposta == :quer_remarcar
    end

    test "resposta fora das duas opções é recusada", %{conn: conn, token: token} do
      conn = post(conn, ~p"/api/reply/#{token}", %{"resposta" => "talvez"})

      assert json_response(conn, 422)["error"] == "resposta_invalida"
    end
  end

  # ---- helpers ----

  defp caixa(_ctx, scope), do: Api.Notifications.list_inbox(scope).results
end
