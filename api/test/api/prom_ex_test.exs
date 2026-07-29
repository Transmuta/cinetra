defmodule Api.PromExTest do
  @moduledoc """
  Métricas Prometheus da aplicação (doc 74).

  ## Por que este teste existe, e por que ele exercita a coleta DE VERDADE

  Configuração de métrica é o tipo de código que falha **em silêncio**. Um `router:` apontando
  para um módulo renomeado, um plugin que deixou de casar com a versão do Oban, um grupo caído
  na `drop_metrics_groups` por engano — nada disso levanta. O `/metrics` continua respondendo
  200, o painel continua desenhando, e o que se vê é uma linha reta em zero que qualquer um lê
  como "está tudo calmo".

  É exatamente o defeito do doc 49: um gate que nasceu morto em duas das quatro portas e passou
  na revisão porque ninguém provou o caminho inteiro. Por isso aqui não basta afirmar que a
  configuração tem a forma certa (`plugins/0`); o teste **gera tráfego real** — uma requisição
  HTTP e uma consulta ao banco — e depois lê o texto que o Prometheus leria, exigindo que as
  famílias de métrica correspondentes tenham aparecido.

  A consequência prática: renomear `ApiWeb.Router` ou trocar de repo quebra este teste, em vez
  de quebrar o painel três semanas depois, no meio de um incidente.
  """
  use ApiWeb.ConnCase, async: false

  # Sem `alias Api.PromEx` aqui, de propósito: ele faria `PromEx.Plugins.Phoenix` resolver para
  # `Api.PromEx.Plugins.Phoenix`, um módulo que não existe — e o teste reprovaria por um motivo
  # que não tem nada a ver com o que ele afirma.

  describe "plugins/0 — a fiação que o painel assume" do
    test "o plugin do Phoenix aponta para o router e o endpoint desta aplicação" do
      assert {PromEx.Plugins.Phoenix, opts} = plugin(PromEx.Plugins.Phoenix)
      assert opts[:router] == ApiWeb.Router
      assert opts[:endpoint] == ApiWeb.Endpoint
    end

    test "o plugin do Ecto aponta para o repo desta aplicação" do
      assert {PromEx.Plugins.Ecto, opts} = plugin(PromEx.Plugins.Ecto)
      assert opts[:repos] == [Api.Repo]
    end

    test "o plugin do Oban acompanha a instância que a árvore de supervisão sobe" do
      assert {PromEx.Plugins.Oban, opts} = plugin(PromEx.Plugins.Oban)
      assert opts[:oban_supervisors] == [Oban]
    end

    test "BEAM e Application entram — são o 'a máquina virtual está saudável?'" do
      carregados = Enum.map(Api.PromEx.plugins(), &elem_modulo/1)

      assert PromEx.Plugins.Beam in carregados
      assert PromEx.Plugins.Application in carregados
    end
  end

  describe "a coleta de verdade — tráfego entra, família de métrica sai" do
    test "requisição HTTP vira contador com rota, método e status", %{conn: conn} do
      get(conn, ~p"/api/health")

      texto = metricas()

      assert texto =~ "api_prom_ex_phoenix_http_requests_total"
      assert texto =~ "api_prom_ex_phoenix_http_request_duration_milliseconds"

      # O label `path` é o que separa "a API está lenta" de "ESTA rota está lenta". Ele vem do
      # `router:` do plugin; se o módulo do router mudar de nome sem que `Api.PromEx` acompanhe,
      # a série continua existindo e este label some — e é justamente ele que some primeiro.
      assert texto =~ ~s(path="/api/health")
    end

    test "consulta ao banco vira tempo de fila do pool" do
      Api.Repo.query!("SELECT 1")

      texto = metricas()

      # `queue_time` é o número que avisa antes do timeout: quanto a consulta esperou por uma
      # conexão livre. Com RLS por transação (ADR-018) toda leitura ocupa uma conexão, então é
      # aqui que a saturação aparece primeiro.
      assert texto =~ "api_prom_ex_ecto_repo_query_queue_time_milliseconds"
      assert texto =~ ~s(repo="Api.Repo")
    end

    test "o pool do repo é medido — prova que o PromEx subiu ANTES do Api.Repo" do
      # `ecto_repo_init_*` sai de um evento emitido UMA vez, quando o repo inicia. Se algum dia
      # `Api.PromEx` for movido para depois de `Api.Repo` na árvore de supervisão, o evento passa
      # despercebido e só ESTA asserção cai — as outras continuam verdes, porque as métricas de
      # consulta não dependem da ordem. É o teste que protege o comentário lá no
      # `Api.Application`.
      assert metricas() =~ "api_prom_ex_ecto_repo_init_pool_size"
    end

    test "a BEAM é amostrada — memória e contagem de processos" do
      texto = metricas()

      assert texto =~ "api_prom_ex_beam_memory_allocated_bytes"
      assert texto =~ "api_prom_ex_beam_system_process_limit_info"
    end
  end

  describe "os dois grupos que a SUÍTE não pode coletar" do
    # Estes dois não são preferência: cada um causou um defeito medido ao ligar o PromEx.
    #
    # Se alguém esvaziar `drop_metrics_groups` no `config/test.exs` para "coletar tudo no teste",
    # os dois voltam. Um deles só suja a saída; o outro faz teste vizinho falhar por sorteio, que
    # é o pior tipo de regressão para depurar depois.

    test "o polling de fila do Oban sai — ele disputa a conexão do sandbox" do
      # MEDIDO: `Api.PromEx.Poller.5000` consulta `oban_jobs` de 5 em 5 segundos, de um processo
      # que não é dono de conexão nenhuma no `Ecto.Adapters.SQL.Sandbox`. O resultado foi
      # `DBConnection.OwnershipError` no meio da suíte, com o rastro apontando para
      # `PromEx.Plugins.Oban.handle_oban_queue_polling_metrics/2`.
      #
      # Não é ruído: o poller CHECA UMA CONEXÃO OUT do pool, e num sandbox isso é contenção real
      # com o teste que estiver rodando. Em produção não existe sandbox e o poller é justamente o
      # que alimenta o painel "Filas do Oban" — por isso o descarte é só aqui.
      assert :oban_queue_poll_metrics in dropados()
    end

    test "os eventos de canal do Phoenix saem — o transport do ChannelTest não é um label válido" do
      # MEDIDO: `Phoenix.ChannelTest` monta o socket com `transport: {Phoenix.ChannelTest, pid}` —
      # uma TUPLA. O `telemetry_metrics_prometheus_core` só aceita valor de label conversível para
      # texto, e recusa cada evento com "Dropping aggregation for bad tag value ... tag: :transport",
      # centenas de vezes por execução.
      #
      # É artefato do arnês de teste, não defeito de produção: no container de dev, com WebSocket
      # de verdade em uso, o mesmo aviso apareceu ZERO vezes em duas horas de log. O que se perde
      # aqui é métrica de canal na suíte, que nenhum teste afirma; o que se ganha é uma saída de
      # teste onde a falha de verdade ainda é visível.
      assert :phoenix_channel_event_metrics in dropados()
    end

    test "e o grupo VIZINHO de socket também — é o mesmo transport, em outro nome" do
      # Descartar só o de canal derrubou o ruído de centenas para 7 linhas, e as 7 restantes eram
      # `socket.connected.duration`, do `:phoenix_socket_event_metrics`. O mesmo campo, o mesmo
      # defeito, outro grupo.
      #
      # A lição que esta asserção guarda é de método: "o ruído diminuiu muito" não é o mesmo que
      # "o ruído acabou". Sem contar o que sobrou, o conserto teria sido dado por pronto com o
      # segundo grupo ainda sujando toda execução.
      assert :phoenix_socket_event_metrics in dropados()
    end

    test "o que NÃO sai: HTTP, Ecto e os eventos de job continuam sendo coletados no teste" do
      # A tentação é descartar o plugin inteiro; seria trocar um defeito por outro. São estes
      # grupos que fazem um `router:` renomeado ou um repo trocado reprovarem aqui em vez de no
      # painel — ver o describe "a coleta de verdade" acima.
      recusados = dropados()

      refute :phoenix_http_event_metrics in recusados
      refute :ecto_query_event_metrics in recusados
      refute :oban_job_event_metrics in recusados
    end

    defp dropados, do: Api.PromEx.init_opts().drop_metrics_groups
  end

  describe "metrics_server_children/0 — a porta" do
    test "no teste não abre porta nenhuma" do
      assert Api.PromEx.metrics_server_children() == []
    end

    test "ligado, sobe um Bandit na porta configurada servindo o plug do PromEx" do
      original = Application.get_env(:api, :metrics)
      on_exit(fn -> Application.put_env(:api, :metrics, original) end)
      Application.put_env(:api, :metrics, server?: true, port: 4999)

      assert [%{id: id, start: {Bandit, :start_link, [opts]}}] =
               Api.PromEx.metrics_server_children()

      assert id == Api.PromEx.MetricsServer
      assert opts[:port] == 4999
      assert opts[:scheme] == :http

      assert opts[:plug] ==
               {PromEx.MetricsServer.Plug, %{path: "/metrics", prom_ex_module: Api.PromEx}}
    end
  end

  defp metricas do
    # `get_metrics/1` devolve exatamente o texto que o Prometheus leria pela porta 4021 — ler
    # daqui exercita o mesmo caminho do raspador, sem precisar abrir a porta na suíte.
    PromEx.get_metrics(Api.PromEx)
  end

  defp plugin(modulo) do
    Enum.find(Api.PromEx.plugins(), fn definicao -> elem_modulo(definicao) == modulo end) ||
      flunk("plugin #{inspect(modulo)} não está em Api.PromEx.plugins/0")
  end

  defp elem_modulo({modulo, _opts}), do: modulo
  defp elem_modulo(modulo), do: modulo
end
