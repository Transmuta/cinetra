defmodule ApiWeb.HealthController do
  @moduledoc """
  Os dois checks do deploy, com semânticas deliberadamente diferentes (doc 62 §7.1).

  **Confundir liveness com readiness derruba o serviço em cascata**, então são duas rotas:

    * `GET /api/health` (liveness) — barato, **sem I/O**. 200 significa "o processo BEAM está de
      pé e respondendo". Não toca o banco de propósito: se um blip do Postgres fizesse o liveness
      falhar, o orquestrador reiniciaria instâncias saudáveis e transformaria uma lentidão do
      banco numa queda total.

    * `GET /api/ready` (readiness) — toca o banco. 200 só quando a instância consegue de fato
      servir. É o que decide se entra na rotação de tráfego.

  Sobre migrations: **não** são checadas aqui. No modelo de deploy do projeto elas rodam no
  `release_command` (`Api.Release.setup/0`), numa máquina efêmera, **antes** de trocar as
  instâncias — logo "app no ar com migration pendente" não é estado alcançável, e checar em
  runtime seria custo sem cobertura.
  """
  use ApiWeb, :controller

  require Logger

  # Orçamento TOTAL do check, e ele é cravado por fora (ver `checar_banco/0`). Curto de propósito:
  # o readiness é consultado a cada 10s e um check mais lento que o intervalo empilha.
  @timeout_ms 2_000

  # Medido em 2026-07-28, com o Postgres pausado: passar só `timeout:` para o `Ecto.Adapters.SQL`
  # NÃO limita o check — aquilo é o timeout da *query*, e a requisição ainda espera na fila do
  # pool. O DBConnection tem backoff adaptativo, e o resultado real foi **21s** (`queue=17003ms`)
  # até o 503. Num endpoint batido a cada 10s isso empilha e vira amplificador de carga sobre um
  # banco já doente. Estes dois encurtam a desistência do pool...
  @queue_target_ms 200
  @queue_interval_ms 500

  def show(conn, _params) do
    json(conn, %{status: "ok", service: "api"})
  end

  def ready(conn, _params) do
    case checar_banco() do
      :ok ->
        json(conn, %{status: "ok", service: "api", db: "ok"})

      {:error, motivo} ->
        # O motivo vai para o log (com contexto), não para o corpo da resposta: o readiness é
        # público na rede interna e não deve descrever a topologia para quem perguntar.
        Logger.warning("readiness reprovado: #{motivo}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable", service: "api", db: "error"})
    end
  end

  # `SELECT 1` exercita as duas coisas que importam de uma vez: o pool (precisa entregar uma
  # conexão — pool esgotado estoura aqui) e o banco do outro lado.
  #
  # ...e a Task é o teto duro. Nenhuma opção do pool garante um limite superior, então quem crava
  # o orçamento é `Task.yield/2` + `Task.shutdown/2` (o padrão que as regras de OTP do projeto
  # mandam usar). A função da Task captura tudo e **nunca** estoura, de modo que o processo do
  # controller não morre junto com uma falha de banco.
  defp checar_banco do
    tarefa =
      Task.async(fn ->
        try do
          Ecto.Adapters.SQL.query(Api.Repo, "SELECT 1", [],
            timeout: @timeout_ms,
            queue_target: @queue_target_ms,
            queue_interval: @queue_interval_ms
          )
        rescue
          erro -> {:error, erro}
        catch
          :exit, _ -> {:error, :exit}
        end
      end)

    case Task.yield(tarefa, @timeout_ms) || Task.shutdown(tarefa, :brutal_kill) do
      {:ok, {:ok, _}} -> :ok
      {:ok, {:error, %{__struct__: _} = erro}} -> {:error, Exception.message(erro)}
      {:ok, {:error, motivo}} -> {:error, inspect(motivo)}
      # `nil` = a Task não respondeu dentro do orçamento e foi morta.
      nil -> {:error, "banco não respondeu em #{@timeout_ms}ms"}
    end
  end
end
