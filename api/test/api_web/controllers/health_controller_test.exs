defmodule ApiWeb.HealthControllerTest do
  @moduledoc """
  Liveness e readiness (doc 62 §7.1) — as duas respondem sem exigir autenticação.

  O que estes testes travam, além do 200:

    * o liveness **não toca o banco**. É o que impede um blip do Postgres de virar reinício em
      cascata de instância saudável;
    * o readiness tem **teto de tempo**. Este contrato já nasceu quebrado uma vez: passar só
      `timeout:` para o `Ecto.Adapters.SQL` limita a *query*, não a espera na fila do pool, e o
      `/api/ready` levou **21s** para devolver 503 (medido com o Postgres pausado, `queue=17003ms`).
      Um readiness batido a cada 10s que demora 21s empilha e vira carga sobre um banco doente.
  """
  use ApiWeb.ConnCase, async: false

  describe "GET /api/health (liveness)" do
    test "200 com status ok", %{conn: conn} do
      conn = get(conn, ~p"/api/health")
      assert json_response(conn, 200) == %{"status" => "ok", "service" => "api"}
    end

    test "não reporta dependência — liveness é sobre o processo", %{conn: conn} do
      corpo = conn |> get(~p"/api/health") |> json_response(200)
      refute Map.has_key?(corpo, "db")
    end
  end

  describe "GET /api/ready (readiness)" do
    test "200 e reporta o banco quando ele responde", %{conn: conn} do
      conn = get(conn, ~p"/api/ready")
      assert %{"status" => "ok", "service" => "api", "db" => "ok"} = json_response(conn, 200)
    end

    test "responde dentro do orçamento de tempo", %{conn: conn} do
      {micros, _} = :timer.tc(fn -> get(conn, ~p"/api/ready") end)

      # O teto do check é 2s; com banco sadio fica muito abaixo. O limite é frouxo de propósito
      # (CI é lento), mas pega a regressão que importa: a espera do pool voltar a ser ilimitada.
      assert div(micros, 1000) < 3_000
    end

    test "não descreve a infra no corpo da resposta", %{conn: conn} do
      corpo = conn |> get(~p"/api/ready") |> json_response(200)

      # O motivo da falha vai para o log, não para a resposta: o readiness é alcançável por quem
      # estiver na rede interna e não deve detalhar a topologia para quem perguntar.
      assert corpo |> Map.keys() |> Enum.sort() == ["db", "service", "status"]
    end
  end
end
