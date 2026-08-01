defmodule ApiWeb.Plugs.RateLimitGlobalTest do
  @moduledoc """
  Rate limit do tráfego geral, nos dois estágios: o de **borda** (por IP, antes da stack de
  sessão) e o de **ator** (200/min, depois do `LoadScope`). Ficam de fora os endpoints de auth
  (que têm o `RateLimitAuth` próprio), os health checks e os webhooks dos providers.

  Enforcement gated a produção (`config :api, :rate_limit_enabled`), como no plug de auth: aqui
  ligamos a flag e encolhemos os tetos via `config :api, :rate_limit_global` para exercitar o
  pipeline real sem disparar centenas de requisições por teste.
  """
  use ApiWeb.ConnCase, async: false

  setup do
    Application.put_env(:api, :rate_limit_enabled, true)

    on_exit(fn ->
      Application.put_env(:api, :rate_limit_enabled, false)
      Application.delete_env(:api, :rate_limit_global)
    end)

    :ok
  end

  defp limite!(n), do: Application.put_env(:api, :rate_limit_global, limit: n)

  # Rota pública (sem sessão): a chave cai no IP. O 404 do token inválido não importa — o plug
  # roda antes do controller e conta a requisição do mesmo jeito.
  defp get_reply(ip) do
    build_conn()
    |> put_req_header("x-forwarded-for", ip)
    |> get(~p"/api/reply/token-invalido")
  end

  test "sem sessão a chave é o IP: o excedente leva 429 com retry-after" do
    limite!(3)
    ip = "203.0.113.10"

    for _ <- 1..3, do: assert(get_reply(ip).status == 404)

    barrado = get_reply(ip)
    assert json_response(barrado, 429) == %{"error" => "rate_limited"}
    assert [retry_after] = get_resp_header(barrado, "retry-after")
    assert String.to_integer(retry_after) >= 1
  end

  test "IPs diferentes não dividem o balde" do
    limite!(1)
    assert get_reply("203.0.113.20").status == 404
    assert get_reply("203.0.113.21").status == 404
  end

  test "autenticado a chave é o ator: rotacionar IP não escapa do limite" do
    limite!(2)
    user = usuario_com_sessao!("rl-global")

    for i <- 1..2 do
      resp =
        as(user)
        |> put_req_header("x-forwarded-for", "10.9.9.#{i}")
        |> get(~p"/api/auth/me")

      assert resp.status == 200
    end

    barrado =
      as(user)
      |> put_req_header("x-forwarded-for", "10.9.9.99")
      |> get(~p"/api/auth/me")

    assert json_response(barrado, 429) == %{"error" => "rate_limited"}
  end

  test "atores diferentes não dividem o balde, mesmo atrás do mesmo IP" do
    limite!(1)
    ip = "10.8.8.8"

    for prefixo <- ["rl-a", "rl-b"] do
      resp =
        prefixo
        |> usuario_com_sessao!()
        |> as()
        |> put_req_header("x-forwarded-for", ip)
        |> get(~p"/api/auth/me")

      assert resp.status == 200
    end
  end

  test "endpoints com limite personalizado (auth) ficam fora do global" do
    limite!(1)

    # Duas requisições do mesmo IP: o RateLimitAuth permite (10/2min por IP); se o global
    # (limite 1) estivesse aplicado, a segunda levaria 429.
    for _ <- 1..2 do
      resp =
        build_conn()
        |> put_req_header("x-forwarded-for", "198.51.100.77")
        |> post(~p"/api/auth/magic-link", %{
          email: "fora-do-global-#{System.unique_integer([:positive])}@example.com"
        })

      assert json_response(resp, 200) == %{"ok" => true}
    end
  end

  test "webhooks dos providers ficam fora do global (rajada de campanha não pode levar 429)" do
    limite!(1)

    # 401 exato, não `refute 429`: o frouxo aceitaria um 500 como prova de que "o webhook está
    # fora do global" (doc 68, causa E). Sem assinatura o controller recusa com 401 — e é isso
    # que prova ao mesmo tempo que a rota está viva e que o limitador não a tocou.
    for _ <- 1..3 do
      resp =
        build_conn()
        |> put_req_header("x-forwarded-for", "198.51.100.99")
        |> post(~p"/webhooks/resend", %{})

      assert resp.status == 401
    end
  end

  test "health checks ficam fora do global (liveness não depende do rate limiter)" do
    limite!(1)

    for _ <- 1..3 do
      resp =
        build_conn()
        |> put_req_header("x-forwarded-for", "198.51.100.88")
        |> get(~p"/api/health")

      assert resp.status == 200
    end
  end

  test "desligado (default fora de prod): não barra" do
    Application.put_env(:api, :rate_limit_enabled, false)
    limite!(1)

    for _ <- 1..4, do: assert(get_reply("203.0.113.30").status == 404)
  end

  test "o default do código é DESLIGADO — sem a flag, nada barra" do
    # Sem `put_env`: é o default de `Application.get_env(..., false)` que decide. O teste acima
    # prova a flag; este prova o default, e é o que impede o limite de nascer ligado em dev/test
    # numa edição distraída (o bate-volta mediu essa mutação passando verde — doc 68, causa E).
    Application.delete_env(:api, :rate_limit_enabled)
    limite!(1)

    for _ <- 1..4, do: assert(get_reply("203.0.113.31").status == 404)
  end

  test "dá para derrubar o teto global sem derrubar o anti-brute-force do login" do
    # A válvula de incidente: se o teto global estiver barrando tráfego legítimo, quem o desliga
    # não pode estar desligando junto a proteção do magic link (doc 68, causa F).
    Application.put_env(:api, :rate_limit_global_enabled, false)
    on_exit(fn -> Application.delete_env(:api, :rate_limit_global_enabled) end)
    limite!(1)

    for _ <- 1..4, do: assert(get_reply("203.0.113.60").status == 404)

    email = "valvula-#{System.unique_integer([:positive])}@example.com"
    for _ <- 1..5, do: post(build_conn(), ~p"/api/auth/magic-link", %{email: email})

    barrado = post(build_conn(), ~p"/api/auth/magic-link", %{email: email})
    assert barrado.status == 429, "o limite de auth tem de continuar de pé"
  end

  test "o default de produção é 200 requisições por minuto" do
    ip = "203.0.113.200"

    for _ <- 1..200, do: assert(get_reply(ip).status == 404)

    assert json_response(get_reply(ip), 429) == %{"error" => "rate_limited"}
  end

  test "a janela é uma JANELA, e a unidade é milissegundo" do
    # O teste acima prova o "200"; este prova o "por minuto". A mutação que trocava a janela de
    # 1 minuto por 90 minutos — e a que a trocava por 60 MILISSEGUNDOS, que é o bug histórico que
    # o `RateLimitAuth` documenta em caixa alta — passavam as duas verdes (doc 68, causa E).
    Application.put_env(:api, :rate_limit_global, limit: 1, scale: 120)
    ip = "203.0.113.40"

    assert get_reply(ip).status == 404
    assert get_reply(ip).status == 429, "dentro da janela o segundo pedido é barrado"

    Process.sleep(150)

    assert get_reply(ip).status == 404, "passada a janela de 120ms, o balde é outro"
  end

  test "a enxurrada é cortada ANTES da stack de sessão — o 429 da borda não paga query" do
    # O limite rodava só depois de `:authenticated`, então cada requisição barrada ainda pagava
    # 5 queries (sessão + token + membership). Com 10 mil req/min de um ator, "200 req/min" virava
    # 49 mil queries descartadas por minuto — amplificação de 42× (doc 68, causa C). O estágio de
    # borda põe teto nisso: passado o teto do IP, o 429 sai sem tocar o banco.
    Application.put_env(:api, :rate_limit_global, edge_limit: 1)
    user = usuario_com_sessao!("rl-edge")
    ip = "10.7.7.7"

    primeira = as(user) |> put_req_header("x-forwarded-for", ip) |> get(~p"/api/auth/me")
    assert primeira.status == 200

    {barrada, queries} =
      Api.QueryCounter.count(fn ->
        as(user) |> put_req_header("x-forwarded-for", ip) |> get(~p"/api/auth/me")
      end)

    assert barrada.status == 429
    assert queries == 0, "a requisição barrada na borda tocou o banco (#{queries} queries)"
  end

  test "a borda não confunde clientes: o teto por IP é por IP" do
    Application.put_env(:api, :rate_limit_global, edge_limit: 1)
    user = usuario_com_sessao!("rl-edge2")

    for ip <- ["10.7.7.8", "10.7.7.9"] do
      resp = as(user) |> put_req_header("x-forwarded-for", ip) |> get(~p"/api/auth/me")
      assert resp.status == 200, "o IP #{ip} não pode herdar o consumo do vizinho"
    end
  end

  # Doc 96, L-2. O estágio de borda existia para "cortar a enxurrada antes do trabalho", e cortava
  # antes do BANCO (o teste acima prova isso) — mas não antes do **corpo**: `Plug.Parsers` é plug do
  # endpoint e rodava antes do router, então mesmo a requisição que ia levar 429 já tinha lido,
  # alocado e decodificado até 8 MB.
  #
  # O jeito de provar a ORDEM sem medir memória é mandar um corpo que o parser recusa: se ele roda
  # primeiro, a resposta é o 400 dele; se o limitador roda primeiro, é 429. Nenhum dos dois é
  # opinião — é qual plug respondeu.
  describe "a borda roda antes do Plug.Parsers (L-2)" do
    defp post_json_quebrado(ip) do
      build_conn()
      |> put_req_header("x-forwarded-for", ip)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/patients", "{isto não é json")
    end

    test "passado o teto, o 429 vem ANTES do erro de parse" do
      Application.put_env(:api, :rate_limit_global, edge_limit: 1)
      ip = "192.0.2.10"

      # A primeira consome o balde. Ela morre no parser mesmo — é o comportamento esperado de
      # corpo inválido, e o que interessa é o que acontece com a SEGUNDA.
      assert_raise Plug.Parsers.ParseError, fn -> post_json_quebrado(ip) end

      assert post_json_quebrado(ip).status == 429,
             "o parser respondeu antes do limitador — o corpo foi lido e decodificado à toa"
    end

    test "webhook segue isento mesmo com a borda no endpoint" do
      # A isenção do `/webhooks` era do ROUTER (o escopo simplesmente não passava pelo estágio).
      # Movendo o estágio para o endpoint, ela precisa ser explícita — senão a mudança reintroduz
      # exatamente o que `router.ex` decidiu evitar: a rajada legítima de uma campanha virando 429.
      Application.put_env(:api, :rate_limit_global, edge_limit: 1)

      for _ <- 1..3 do
        resp =
          build_conn()
          |> put_req_header("x-forwarded-for", "192.0.2.20")
          |> post(~p"/webhooks/resend", %{})

        assert resp.status == 401
      end
    end

    test "health check segue isento mesmo com a borda no endpoint" do
      Application.put_env(:api, :rate_limit_global, edge_limit: 1)

      for _ <- 1..3 do
        resp =
          build_conn()
          |> put_req_header("x-forwarded-for", "192.0.2.30")
          |> get(~p"/api/health")

        assert resp.status == 200
      end
    end
  end

  test "o retry-after vai em SEGUNDOS (RFC 7231), não em milissegundos" do
    # `>= 1` aceitava 60000 tão bem quanto 60 — e 60000 mandaria o cliente esperar 16 horas.
    # A janela é de 1 minuto, então qualquer valor acima de 60 é erro de unidade por construção.
    limite!(1)
    ip = "203.0.113.50"

    assert get_reply(ip).status == 404
    barrado = get_reply(ip)

    assert [retry_after] = get_resp_header(barrado, "retry-after")
    assert String.to_integer(retry_after) in 1..60
  end
end
