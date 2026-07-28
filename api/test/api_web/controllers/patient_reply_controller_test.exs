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
    [message] = mensagens(ctx, appt)

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
end
