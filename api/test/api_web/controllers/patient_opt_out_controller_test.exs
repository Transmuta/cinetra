defmodule ApiWeb.PatientOptOutControllerTest do
  @moduledoc """
  O descadastro pelo link do rodapé do e-mail (doc 52 §10).

  Duas coisas precisam estar provadas aqui, e nenhuma das duas é "o opt-out grava":

    * **o GET não descadastra.** Scanner de antivírus e pré-visualização de webmail abrem todo
      link de todo e-mail. Se o efeito estivesse no GET, o paciente seria descadastrado por um
      robô que ele nunca viu, e ninguém descobriria — o sintoma é a clínica parar de avisar;
    * **o opt-out nasce daquela clínica, não global.** Diferente do "SAIR" do WhatsApp, aqui se
      sabe de qual clínica veio a mensagem. Gravar global silenciaria as outras clínicas do mesmo
      paciente sem que ele tivesse pedido isso.
  """

  use ApiWeb.ConnCase, async: true

  alias Api.Messaging
  alias Api.Messaging.OptOutToken

  setup do
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com", nome: "Ana Beatriz")
    appt = agendamento!(ctx, paciente: paciente)
    message = confirmacao!(ctx, appt, paciente)

    %{ctx: ctx, message: message, token: OptOutToken.sign(message.id)}
  end

  describe "GET /api/opt-out/:token" do
    test "mostra de qual clínica se trata — e NÃO descadastra", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      body = conn |> get(~p"/api/opt-out/#{token}") |> json_response(200)

      assert body["clinica"] == ctx.clinic.nome
      assert body["descadastrado"] == false

      # A asserção que dá nome ao teste: abrir o link é inofensivo.
      refute Messaging.opted_out?(message.canal, message.destino, ctx.clinic.id)
    end

    test "não devolve o destino — o link pode ter sido encaminhado", %{conn: conn, token: token} do
      body = conn |> get(~p"/api/opt-out/#{token}") |> json_response(200)

      refute Map.has_key?(body, "destino")
      refute Map.has_key?(body, "email")
      refute Map.has_key?(body, "paciente")
    end

    test "token inválido responde 404, sem dizer se a mensagem existe", %{conn: conn} do
      assert conn |> get(~p"/api/opt-out/nao-e-um-token") |> json_response(404) == %{
               "error" => "link_invalido"
             }
    end

    test "token de resposta não vale como token de descadastro", %{conn: conn, message: message} do
      # Sais diferentes, finalidades diferentes. Um token assinado para responder não descadastra.
      outro = Api.Messaging.ReplyToken.sign(message.id)

      assert conn |> get(~p"/api/opt-out/#{outro}") |> json_response(404)
    end

    test "token vencido responde 410 com motivo acionável", %{conn: conn, message: message} do
      velho =
        OptOutToken.sign(message.id, signed_at: System.system_time(:second) - 60 * 60 * 24 * 400)

      body = conn |> get(~p"/api/opt-out/#{velho}") |> json_response(410)

      assert body["error"] == "link_expirado"
    end
  end

  describe "POST /api/opt-out/:token" do
    test "registra o pedido e passa a barrar o envio", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      body = conn |> post(~p"/api/opt-out/#{token}") |> json_response(200)

      assert body["descadastrado"] == true
      assert Messaging.opted_out?(message.canal, message.destino, ctx.clinic.id)
    end

    test "nasce GLOBAL — é o que a leitura do envio consegue enxergar", %{
      conn: conn,
      token: token,
      message: message
    } do
      conn |> post(~p"/api/opt-out/#{token}") |> json_response(200)

      # A asserção parece dizer "silenciou até quem não pediu", e o que ela prende é o contrário:
      # sob RLS, uma linha por-clínica é **invisível** para `opted_out?/3` (que roda fora do
      # `in_clinic`, por desenho), e o envio seguinte sairia como se ninguém tivesse pedido nada.
      # Medido no psql sob `cinetra_app`: com GUC 1 linha, sem GUC 0. Ver o moduledoc do
      # controller e `docs/50-debitos-tecnicos.md`.
      #
      # Este teste NÃO prova a RLS — a suíte roda como `postgres`. Ele prende a decisão de gravar
      # global, que é o que sobrevive à RLS.
      assert Messaging.opted_out?(message.canal, message.destino, Ash.UUID.generate())
    end

    test "dois cliques não viram dois registros", %{conn: conn, token: token, message: message} do
      conn |> post(~p"/api/opt-out/#{token}") |> json_response(200)
      conn |> post(~p"/api/opt-out/#{token}") |> json_response(200)

      vigentes =
        Messaging.list_opt_outs!(message.canal, message.destino, message.clinic_id,
          authorize?: false
        )

      assert length(vigentes) == 1
    end

    test "o GET seguinte já diz que está descadastrado", %{conn: conn, token: token} do
      conn |> post(~p"/api/opt-out/#{token}") |> json_response(200)

      body = conn |> get(~p"/api/opt-out/#{token}") |> json_response(200)

      assert body["descadastrado"] == true
    end

    test "token inválido não grava nada", %{conn: conn, message: message, ctx: ctx} do
      assert conn |> post(~p"/api/opt-out/nao-e-um-token") |> json_response(404)

      refute Messaging.opted_out?(message.canal, message.destino, ctx.clinic.id)
    end
  end
end
