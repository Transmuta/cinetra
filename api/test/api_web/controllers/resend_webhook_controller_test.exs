defmodule ApiWeb.ResendWebhookControllerTest do
  @moduledoc """
  O webhook do Resend (doc 52 §2.1/§10.2) — a primeira rota pública sem sessão fora do auth.

  Três coisas precisam estar provadas aqui, e nenhuma delas aparece em teste de domínio:

    * **a assinatura protege de verdade** — sem ela, qualquer um muda o estado de entrega de uma
      mensagem cujo id conheça;
    * **o corpo cru sobrevive ao `Plug.Parsers`** — se ele for reserializado, o HMAC não fecha e
      todo webhook legítimo é recusado;
    * **o evento resolve o tenant sozinho** — ele chega sem `clinic_id`, e é a busca por
      `provider_message_id` que descobre de quem é a linha.
  """
  alias Api.Messaging

  use ApiWeb.ConnCase, async: false

  @secret "whsec_" <> Base.encode64("segredo-de-teste")

  setup do
    anterior = Application.get_env(:api, Api.Messaging, [])
    Application.put_env(:api, Api.Messaging, resend_webhook_secret: @secret)
    on_exit(fn -> Application.put_env(:api, Api.Messaging, anterior) end)

    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
    appt = agendamento!(ctx, paciente: paciente)
    # Disparada à mão: criar o bloco não fala mais com o paciente (doc 98).
    message = confirmacao!(ctx, appt, paciente)

    # Simula o que o transporte grava quando o provider aceita.
    enviada =
      Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
        Messaging.do_mark_sent!(
          message,
          %{provider: "resend", provider_message_id: "prov-#{Api.Generators.unico()}"},
          tenant: ctx.clinic.id,
          authorize?: false
        )
      end)

    %{ctx: ctx, message: enviada}
  end

  describe "assinatura" do
    test "sem headers, recusa", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/resend", ~s({"type":"email.delivered"}))

      assert json_response(conn, 401)["error"] == "assinatura_invalida"
    end

    test "com assinatura errada, recusa", %{conn: conn, message: message} do
      corpo = evento("email.delivered", message)

      conn =
        conn
        |> assinar(corpo, "whsec_" <> Base.encode64("outro-segredo"))
        |> post(~p"/webhooks/resend", corpo)

      assert json_response(conn, 401)
    end

    test "com timestamp velho, recusa (replay)", %{conn: conn, message: message} do
      # Assinatura legítima capturada ontem não pode virar reentrega infinita.
      corpo = evento("email.delivered", message)
      ontem = DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.to_unix()

      conn =
        conn
        |> assinar(corpo, @secret, ontem)
        |> post(~p"/webhooks/resend", corpo)

      assert json_response(conn, 401)
    end

    test "sem segredo configurado, recusa tudo (fail closed)", %{conn: conn, message: message} do
      Application.put_env(:api, Api.Messaging, resend_webhook_secret: nil)
      corpo = evento("email.delivered", message)

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/resend", corpo)

      assert json_response(conn, 401)
    end
  end

  describe "eventos" do
    test "delivered avança o estado e resolve o tenant sozinho", %{
      conn: conn,
      ctx: ctx,
      message: message
    } do
      corpo = evento("email.delivered", message)

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/resend", corpo)

      assert json_response(conn, 200)["ok"]
      assert %{status: :entregue, entregue_em: %DateTime{}} = recarregar_mensagem(ctx, message)
    end

    test "bounced falha a mensagem e NÃO cria opt-out", %{conn: conn, ctx: ctx, message: message} do
      # Endereço inválido não é vontade de ninguém. Tratá-lo como opt-out silenciaria para
      # sempre um paciente cujo e-mail foi digitado errado.
      corpo = evento("email.bounced", message, %{"reason" => "mailbox does not exist"})

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/resend", corpo)

      recarregada = recarregar_mensagem(ctx, message)
      assert recarregada.status == :falhou
      assert recarregada.erro =~ "mailbox"
      refute Messaging.opted_out?(:email, message.destino, ctx.clinic.id)
    end

    test "complained vira opt-out imediato", %{conn: conn, ctx: ctx, message: message} do
      corpo = evento("email.complained", message)

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/resend", corpo)

      assert Messaging.opted_out?(:email, message.destino, ctx.clinic.id)

      # E vale para qualquer clínica: com remetente único, a pessoa marcou "a Cinetra" como spam.
      assert Messaging.opted_out?(:email, message.destino, Ash.UUID.generate())
    end

    test "o mesmo evento duas vezes é no-op (idempotência sem tabela)", %{
      conn: conn,
      ctx: ctx,
      message: message
    } do
      corpo = evento("email.delivered", message)

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/resend", corpo)
      primeira = recarregar_mensagem(ctx, message)

      build_conn() |> assinar(corpo, @secret) |> post(~p"/webhooks/resend", corpo)
      segunda = recarregar_mensagem(ctx, message)

      assert segunda.entregue_em == primeira.entregue_em
    end

    test "evento de mensagem desconhecida responde 200, não erro", %{conn: conn} do
      # Erro faria o provider reentregar para sempre algo que nunca será processável.
      corpo = Jason.encode!(%{"type" => "email.delivered", "data" => %{"email_id" => "sumiu"}})

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/resend", corpo)

      assert json_response(conn, 200)
    end
  end

  # ---- helpers ----

  # Devolve o corpo **já serializado**. O teste manda a string, não o mapa: `Plug.Test.conn/3`
  # com um mapa seta `conn.params` direto e **pula o `Plug.Parsers`** — logo, pula o body_reader
  # que guarda o corpo cru, e a assinatura seria calculada sobre "".
  #
  # Isso não é artifício de teste: é o mesmo caminho do provider real, que manda bytes.
  defp evento(tipo, message, extra \\ %{}) do
    Jason.encode!(%{
      "type" => tipo,
      "data" => Map.merge(%{"email_id" => message.provider_message_id}, extra)
    })
  end

  # Assina como o Svix: HMAC-SHA256 sobre "<id>.<timestamp>.<corpo cru>". O corpo cru precisa ser
  # exatamente o que o Phoenix vai enviar — por isso o teste serializa uma vez e manda a MESMA
  # string, em vez de deixar o `post` reserializar o mapa.
  defp assinar(conn, payload, secret, timestamp \\ nil) do
    ts = timestamp || DateTime.to_unix(DateTime.utc_now())
    id = "msg_teste"

    chave = secret |> String.replace_prefix("whsec_", "") |> Base.decode64!()
    mac = :crypto.mac(:hmac, :sha256, chave, "#{id}.#{ts}.#{payload}")

    conn
    |> put_req_header("svix-id", id)
    |> put_req_header("svix-timestamp", to_string(ts))
    |> put_req_header("svix-signature", "v1," <> Base.encode64(mac))
    |> put_req_header("content-type", "application/json")
  end
end
