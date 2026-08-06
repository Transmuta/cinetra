defmodule Api.Messaging.ZernioTest do
  @moduledoc """
  O cliente da Zernio (doc 65 §3), com o HTTP costurado por `Req.Test` — sem rede e sem
  credencial.

  Testar o duplo em memória (`Api.Messaging.WhatsAppMemory`) prova o encaixe; o que **só** aqui se
  prova é o que este módulo faz de fato: montar o corpo que a Zernio espera, achar o id da
  mensagem na resposta e traduzir cada família de erro para um texto que a recepção entenda.

  A distinção mais importante está no último bloco: **erro de negócio devolve, erro de rede
  levanta**. É ela que decide se o Oban retenta — retentar "número inválido" queima as três
  tentativas para dar o mesmo resultado, e não retentar um timeout perde a mensagem.
  """
  use ExUnit.Case, async: true

  alias Api.Messaging.Zernio

  @message %{
    id: "01930000-0000-7000-8000-000000000000",
    destino: "+5511987654321",
    vars: %{}
  }

  @corpo %{nome: "confirmacao_v1", idioma: "pt_BR", params: ["Ana", "Clínica", "28/07", "14:00"]}

  setup do
    anterior = Application.get_env(:api, Api.Messaging.Zernio, [])

    on_exit(fn -> Application.put_env(:api, Api.Messaging.Zernio, anterior) end)

    :ok
  end

  defp responder(fun) do
    Application.put_env(:api, Api.Messaging.Zernio,
      api_key: "sk_de_teste",
      account_id: "conta-da-cinetra",
      base_url: "https://zernio.test/api/v1",
      plug: fun
    )
  end

  describe "a URL base quando a env vem VAZIA" do
    test "`base_url` em branco cai no padrão, não vira caminho sem esquema" do
      # `${ZERNIO_BASE_URL:-}` no compose entrega **string vazia**, não `nil` — a env está
      # definida, só que sem valor. E `"" || padrao` devolve `""` em Elixir, porque string vazia é
      # truthy. O resultado era a URL virar `/inbox/conversations`, sem host nem esquema, e o
      # Finch levantar `scheme is required for url` — o que o Oban lê como falha de REDE e
      # retenta três vezes, sem nunca chegar à Zernio.
      #
      # Medido em 2026-08-01, no primeiro envio real de WhatsApp. `compose.dokploy.yml` tem a
      # mesma linha, então produção quebraria igual no primeiro disparo.
      Application.put_env(:api, Api.Messaging.Zernio,
        api_key: "sk_de_teste",
        account_id: "conta-da-cinetra",
        base_url: "",
        plug: fn conn ->
          assert conn.host == "zernio.com"
          assert conn.request_path == "/api/v1/inbox/conversations"
          Req.Test.json(conn, %{"data" => %{"messageId" => "wamid.1"}})
        end
      )

      assert {:ok, "zernio", "wamid.1"} = Zernio.entregar(@message, @corpo)
    end

    test "`base_url` preenchida continua mandando" do
      # O par do teste acima: o conserto não pode passar por cima de quem configurou de verdade
      # (o sandbox da Zernio, um proxy de HML).
      responder(fn conn ->
        assert conn.host == "zernio.test"
        Req.Test.json(conn, %{"data" => %{"messageId" => "wamid.2"}})
      end)

      assert {:ok, "zernio", "wamid.2"} = Zernio.entregar(@message, @corpo)
    end
  end

  describe "configurado?/0" do
    test "exige chave E conta" do
      responder(fn conn -> conn end)
      assert Zernio.configurado?()

      Application.put_env(:api, Api.Messaging.Zernio, api_key: "sk_x")
      refute Zernio.configurado?()

      Application.put_env(:api, Api.Messaging.Zernio, [])
      refute Zernio.configurado?()
    end
  end

  describe "entregar/2 — o que sai" do
    test "abre conversa com template, telefone em dígitos e a conta da clínica" do
      responder(fn conn ->
        {:ok, corpo, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(corpo)

        assert conn.request_path =~ "/inbox/conversations"
        assert ["Bearer sk_de_teste"] = Plug.Conn.get_req_header(conn, "authorization")

        # O `+` sai na borda: a Zernio pede dígitos com código de país.
        assert body["participantId"] == "5511987654321"
        assert body["accountId"] == "conta-da-cinetra"
        assert body["templateName"] == "confirmacao_v1"
        assert body["templateLanguage"] == "pt_BR"
        assert body["templateParams"] == ["Ana", "Clínica", "28/07", "14:00"]

        Req.Test.json(conn, %{"success" => true, "data" => %{"messageId" => "wamid.ABC"}})
      end)

      assert {:ok, "zernio", "wamid.ABC"} = Zernio.entregar(@message, @corpo)
    end

    test "manda Idempotency-Key com o id da nossa mensagem" do
      # Aposta barata contra a janela "provider aceitou / não gravamos" (ver `SendJob`). Se a
      # Zernio honrar, a janela fecha; se ignorar, o header é inerte.
      responder(fn conn ->
        assert Plug.Conn.get_req_header(conn, "idempotency-key") == [@message.id]
        Req.Test.json(conn, %{"data" => %{"messageId" => "wamid.X"}})
      end)

      assert {:ok, "zernio", _} = Zernio.entregar(@message, @corpo)
    end

    test "a conta da clínica sobrescreve a compartilhada (§9.1.4)" do
      responder(fn conn ->
        {:ok, corpo, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(corpo)["accountId"] == "numero-proprio"
        Req.Test.json(conn, %{"data" => %{"messageId" => "wamid.X"}})
      end)

      propria = put_in(@message.vars, %{"zernio_account_id" => "numero-proprio"})
      assert {:ok, "zernio", _} = Zernio.entregar(propria, @corpo)
    end

    test "aceito sem messageId ainda é sucesso, sem rastro" do
      # A mensagem saiu; o que se perde é o webhook de entrega achar a linha depois. Marcar
      # `:falhou` aqui diria à recepção que não foi entregue algo que foi.
      responder(fn conn -> Req.Test.json(conn, %{"success" => true, "data" => %{}}) end)

      assert {:ok, "zernio", nil} = Zernio.entregar(@message, @corpo)
    end

    test "corpo que não é template não vira chamada de rede" do
      responder(fn _conn -> raise "não devia ter chamado a rede" end)

      assert {:error, motivo} = Zernio.entregar(@message, %{assunto: "oi", texto: "corpo"})
      assert motivo =~ "sem template renderizado"
    end
  end

  describe "entregar/2 — o que volta quando dá errado" do
    test "o código da Meta chega inteiro no motivo, para a tradução casar" do
      responder(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "code" => "TEMPLATE_REQUIRED",
          "error" => "131021 recipient is not a valid WhatsApp user"
        })
      end)

      assert {:error, motivo} = Zernio.entregar(@message, @corpo)
      assert motivo =~ "400"
      assert motivo =~ "TEMPLATE_REQUIRED"

      assert Api.Messaging.Falhas.para_tela(motivo) ==
               "Este número não tem WhatsApp — confira o telefone na ficha"
    end

    test "401 vira 'erro de configuração', não 'número inválido'" do
      responder(fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "Unauthorized"})
      end)

      assert {:error, motivo} = Zernio.entregar(@message, @corpo)

      assert Api.Messaging.Falhas.para_tela(motivo) ==
               "Erro de configuração do envio — avise o suporte"
    end

    test "429 vira 'tente de novo em alguns minutos'" do
      responder(fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "Too many requests"})
      end)

      assert {:error, motivo} = Zernio.entregar(@message, @corpo)

      assert Api.Messaging.Falhas.para_tela(motivo) ==
               "Limite de envio atingido — tente reenviar em alguns minutos"
    end

    test "erro de REDE levanta — é o que faz o Oban retentar" do
      # A distinção que decide o comportamento da fila: negócio devolve `{:error, _}` e o
      # `SendJob` grava `:falhou` sem retentar; rede levanta e o Oban tenta de novo.
      responder(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert_raise RuntimeError, ~r/indisponível/, fn -> Zernio.entregar(@message, @corpo) end
    end
  end
end
