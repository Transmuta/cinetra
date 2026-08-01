defmodule ApiWeb.ZernioWebhookControllerTest do
  @moduledoc """
  O webhook da Zernio (doc 65 §4) — a segunda rota pública sem sessão desta fatia.

  O que precisa estar provado aqui, e que nenhum teste de domínio alcança:

    * **a assinatura protege** — sem ela qualquer um muda o estado de entrega de uma mensagem
      cujo id conheça, ou registra opt-out no telefone de terceiro;
    * **o corpo cru sobrevive ao `Plug.Parsers`** — se for reserializado, o HMAC não fecha e todo
      webhook legítimo é recusado (o caminho já existia para o Resend; a rota nova precisava
      entrar na lista do `CacheRawBody`, e este teste é quem prova que entrou);
    * **o evento resolve o tenant sozinho** — chega sem `clinic_id`, e é a busca pelo id do
      provider que descobre de quem é a linha;
    * **`message.read` avança de verdade** — é o estado que o e-mail nunca alcança, e a razão de
      `:lido` existir na máquina desde a fase 1.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Messaging

  @secret "segredo-zernio-de-teste"

  setup do
    anterior = Application.get_env(:api, Api.Messaging, [])
    Application.put_env(:api, Api.Messaging, zernio_webhook_secret: @secret)
    on_exit(fn -> Application.put_env(:api, Api.Messaging, anterior) end)

    # O canal ligado, com o duplo em memória (`config/test.exs`): sem isto o paciente com telefone
    # e sem e-mail é `:sem_contato` e não haveria mensagem nenhuma para o webhook casar.
    transporte = Application.get_env(:api, Api.Messaging.Transport, [])

    Application.put_env(
      :api,
      Api.Messaging.Transport,
      Keyword.put(transporte, :whatsapp_habilitado, true)
    )

    on_exit(fn -> Application.put_env(:api, Api.Messaging.Transport, transporte) end)

    # `whatsapp: true` é a segunda chave: o bloco acima liga o transporte da INSTALAÇÃO, e esta
    # liga o canal DESTA CLÍNICA (`msg_whatsapp_ativo`). Só uma delas e a mensagem sai por e-mail.
    ctx = clinica(whatsapp: true)
    paciente = paciente_com(ctx, comunicacao: true, tel: "11987654321")
    appt = agendamento!(ctx, paciente: paciente)
    # Disparada à mão: criar o bloco não fala mais com o paciente (doc 98).
    message = confirmacao!(ctx, appt, paciente)

    # Simula o que o transporte grava quando a Zernio aceita.
    enviada =
      Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
        Messaging.do_mark_sent!(
          message,
          %{provider: "zernio", provider_message_id: "wamid-#{Api.Generators.unico()}"},
          tenant: ctx.clinic.id,
          authorize?: false
        )
      end)

    %{ctx: ctx, message: enviada, paciente: paciente}
  end

  describe "assinatura" do
    test "sem header, recusa", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/webhooks/zernio", ~s({"event":"message.delivered"}))

      assert json_response(conn, 401)["error"] == "assinatura_invalida"
    end

    test "com assinatura de outro segredo, recusa", %{conn: conn, message: message} do
      corpo = evento("message.delivered", message)

      conn = conn |> assinar(corpo, "outro-segredo") |> post(~p"/webhooks/zernio", corpo)

      assert json_response(conn, 401)
    end

    test "sem segredo configurado, recusa tudo (fail closed)", %{conn: conn, message: message} do
      Application.put_env(:api, Api.Messaging, zernio_webhook_secret: nil)
      corpo = evento("message.delivered", message)

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      assert json_response(conn, 401)
    end

    test "hex maiúsculo é a mesma assinatura", %{conn: conn, ctx: ctx, message: message} do
      # Formatação não pode custar entrega: recusar por causa do case seria recusar webhook
      # legítimo de um provider que mudou de biblioteca.
      corpo = evento("message.delivered", message)
      assinatura = String.upcase(hmac(corpo, @secret))

      conn
      |> put_req_header("x-zernio-signature", assinatura)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/zernio", corpo)

      assert recarregar_mensagem(ctx, message).status == :entregue
    end
  end

  describe "eventos de entrega" do
    test "delivered avança e resolve o tenant sozinho", %{
      conn: conn,
      ctx: ctx,
      message: message
    } do
      corpo = evento("message.delivered", message)

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      assert json_response(conn, 200)["ok"]
      assert %{status: :entregue, entregue_em: %DateTime{}} = recarregar_mensagem(ctx, message)
    end

    test "read chega a :lido — o estado que o e-mail nunca alcança", %{
      conn: conn,
      ctx: ctx,
      message: message
    } do
      for tipo <- ["message.delivered", "message.read"] do
        corpo = evento(tipo, message)
        build_conn() |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)
      end

      assert %{status: :lido, lido_em: %DateTime{}} = recarregar_mensagem(ctx, message)
      _ = conn
    end

    test "failed grava o código da Meta, e a tela o traduz", %{
      conn: conn,
      ctx: ctx,
      message: message
    } do
      corpo =
        evento("message.failed", message, %{
          "error" => %{"code" => 131_021, "message" => "Recipient is not a valid WhatsApp user"}
        })

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      recarregada = recarregar_mensagem(ctx, message)

      assert recarregada.status == :falhou
      assert recarregada.erro =~ "131021"

      assert Api.Messaging.Falhas.para_tela(recarregada.erro) ==
               "Este número não tem WhatsApp — confira o telefone na ficha"
    end

    test "o mesmo evento duas vezes é no-op", %{conn: conn, ctx: ctx, message: message} do
      # A Zernio reentrega até 7 vezes e **não** assina timestamp: sem idempotência, replay
      # reescreveria estado. Ver `Api.Messaging.ZernioSignature`.
      corpo = evento("message.delivered", message)

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)
      primeira = recarregar_mensagem(ctx, message)

      build_conn() |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      assert recarregar_mensagem(ctx, message).entregue_em == primeira.entregue_em
    end

    test "evento de mensagem desconhecida responde 200, não erro", %{conn: conn} do
      corpo =
        Jason.encode!(%{"event" => "message.delivered", "message" => %{"id" => "sumiu-daqui"}})

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      assert json_response(conn, 200)
    end

    test "evento que não conhecemos é silêncio, não erro", %{
      conn: conn,
      ctx: ctx,
      message: message
    } do
      corpo = evento("message.reaction", message)

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      assert json_response(conn, 200)
      assert recarregar_mensagem(ctx, message).status == :enviado
    end
  end

  describe "entrada do paciente: opt-out por palavra-chave (§10)" do
    test "SAIR registra opt-out GLOBAL do telefone", %{conn: conn, ctx: ctx} do
      corpo = entrada("SAIR", "+5511987654321")

      conn = conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      assert json_response(conn, 200)
      assert Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id)

      # Global: com número compartilhado, "SAIR" é para a Cinetra, não para uma clínica (C10/C11).
      assert Messaging.opted_out?(:whatsapp, "+5511987654321", Ash.UUID.generate())
    end

    test "o número chega normalizado, venha como vier", %{conn: conn, ctx: ctx} do
      # Se o opt-out gravar num formato e a ficha comparar noutro, a próxima mensagem sai — que é
      # o pior defeito possível neste caminho.
      corpo = entrada("pare", "5511987654321")

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      assert Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id)
    end

    test "'não pare de mandar' NÃO é opt-out", %{conn: conn, ctx: ctx} do
      # `String.contains?` acharia "pare" aqui dentro e silenciaria quem pediu o contrário.
      corpo = entrada("por favor, não pare de mandar os lembretes", "+5511987654321")

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      refute Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id)
    end

    test "mensagem comum não registra nada", %{conn: conn, ctx: ctx} do
      corpo = entrada("obrigada, até quinta!", "+5511987654321")

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      refute Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id)
    end
  end

  describe "replay (§S-7)" do
    # A Zernio **não assina timestamp** (`Api.Messaging.ZernioSignature` explica): um corpo
    # capturado continua com assinatura válida para sempre. O argumento de que isso é inócuo
    # dependia de todo efeito ser idempotente — e tem um furo, porque `revoke_opt_out/3` existe:
    # entre o "SAIR" original e o replay cabe uma revogação, e o replay a desfaz.
    #
    # O sintoma para quem usa é o pior possível: o paciente pediu no balcão para voltar a receber,
    # a recepção reativou, e ele simplesmente para de receber de novo — sem erro, sem log, sem
    # ninguém conseguir explicar.
    test "um SAIR capturado e reentregue não ressilencia depois da revogação", %{
      conn: conn,
      ctx: ctx
    } do
      corpo = entrada("SAIR", "+5511987654321")

      conn |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)
      assert Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id)

      :ok = Messaging.revoke_opt_out(ctx.scope, :whatsapp, "+5511987654321")
      refute Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id)

      # Mesmíssimos bytes, mesma assinatura — é literalmente a requisição de antes.
      build_conn() |> assinar(corpo, @secret) |> post(~p"/webhooks/zernio", corpo)

      refute Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id),
             "o replay ressilenciou o paciente (doc 96, S-7)"
    end

    test "evento novo, de corpo diferente, continua sendo processado", %{conn: conn, ctx: ctx} do
      # O controle contra excesso: a barreira é por evento, não por remetente nem por rota. Dois
      # "SAIR" de números diferentes são dois fatos, e os dois têm de valer.
      um = entrada("SAIR", "+5511987654321")
      outro = entrada("SAIR", "+5511912345678")

      conn |> assinar(um, @secret) |> post(~p"/webhooks/zernio", um)
      build_conn() |> assinar(outro, @secret) |> post(~p"/webhooks/zernio", outro)

      assert Messaging.opted_out?(:whatsapp, "+5511987654321", ctx.clinic.id)
      assert Messaging.opted_out?(:whatsapp, "+5511912345678", ctx.clinic.id)
    end
  end

  # ---- helpers ----

  # Corpo **já serializado**: `Plug.Test.conn/3` com um mapa pula o `Plug.Parsers` — logo, pula o
  # body reader que guarda o corpo cru, e a assinatura seria calculada sobre "".
  defp evento(tipo, message, extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "id" => "evt-#{Api.Generators.unico()}",
          "event" => tipo,
          "message" => %{"id" => message.provider_message_id}
        },
        extra
      )
    )
  end

  defp entrada(texto, telefone) do
    Jason.encode!(%{
      "id" => "evt-#{Api.Generators.unico()}",
      "event" => "message.received",
      "message" => %{
        "id" => "in-#{Api.Generators.unico()}",
        "text" => texto,
        "direction" => "incoming",
        "sender" => %{"id" => telefone}
      }
    })
  end

  defp assinar(conn, payload, secret) do
    conn
    |> put_req_header("x-zernio-signature", hmac(payload, secret))
    |> put_req_header("content-type", "application/json")
  end

  defp hmac(payload, secret),
    do: :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
end
