defmodule Api.PromEx do
  @moduledoc """
  Métricas Prometheus da aplicação — a segunda metade da observabilidade (doc 74).

  ## O que isto responde que o log não responde

  O doc 62 §11.2 registrou a lacuna com todas as letras: *"log registra o que a aplicação fez;
  não registra o estado da máquina. Um p95 subindo mostra o sintoma, e sem métricas de host não
  dá para dizer se a causa foi CPU saturada, disco lento ou o banco."*

  O Loki mede requisição por requisição. Ele sabe que a chamada demorou 3 s; não sabe que a fila
  do pool do Ecto estava com 40 esperando por uma conexão, que o Oban acumulou 900 jobs, nem que
  a BEAM estava em GC. Essas três são **estado**, não evento — só aparecem se alguém amostrar
  periodicamente. É o que este módulo faz.

  A parte de máquina (CPU, disco, rede, container) vem de fora, do `node_exporter` e do cAdvisor
  no stack de observabilidade. Aqui é só o que **a aplicação sabe sobre si mesma**.

  ## Por que um servidor HTTP próprio, e não uma rota no router

  O `/metrics` serve numa porta separada (`:metrics` em config, 4021 por padrão), sob um `Bandit`
  próprio na árvore de supervisão — não como rota do `ApiWeb.Router`. São quatro razões, e cada
  uma já causou problema em algum projeto:

    * **Rate limit** — o `RateLimitGlobal` conta por IP. O Prometheus raspa a cada 15 s do mesmo
      endereço, para sempre; mais cedo ou mais tarde ele mesmo dispara o 429 e a série vira
      buraco. Pior: o buraco aparece exatamente durante um incidente, que é quando o tráfego
      sobe e o limite aperta.
    * **Traefik** — rota no router é rota publicável. Um `PathPrefix` distraído expõe para a
      internet inventário de rotas, nomes de fila e volume de negócio. Porta que ninguém publica
      não tem esse modo de falha.
    * **RequestLogger** — 5.760 requisições/dia de raspagem entrariam na conta da retenção do
      Loki, e o doc 62 §7.4 já teve de descartar health check pelo mesmo motivo.
    * **Autenticação** — o pipeline do router carrega `LoadScope` e `VerifyTokenSubject`. Nada
      disso faz sentido para o raspador, e desviar dele é mais uma exceção para manter viva.

  O PromEx traz um `metrics_server` embutido, e ele fica **desligado** de propósito: aquele usa
  `Plug.Cowboy`, e esta aplicação serve por `Bandit`. Subir um segundo servidor web só para o
  `/metrics` acrescentaria uma dependência e um jeito diferente de configurar TLS, timeout e
  pool. O plug do PromEx é reaproveitado — só o servidor é nosso.

  ## O que a porta 4021 expõe, e para quem

  Sem autenticação, por decisão: ela **não é publicada** no compose nem no Traefik, então só
  alcança quem já está na rede interna do Docker. Autenticação por token aqui protegeria de um
  atacante que já está dentro da rede — e esse atacante tem o Postgres ao lado, um alvo bem
  melhor que a contagem de jobs. O que importa é a porta não sair da máquina; isso é
  responsabilidade do compose, e o doc 74 §5 mostra como conferir.
  """

  use PromEx, otp_app: :api

  alias PromEx.Plugins

  @doc """
  Filho da árvore de supervisão que serve o `/metrics` — uma lista de zero ou um.

  Lista, e não uma especificação avulsa, porque `server?: false` (o caso do teste) precisa
  resultar em **nenhum** filho: `Supervisor.init/2` não aceita `:ignore` no meio da lista de
  children, e um `nil` filtrado depois espalha a condicional pelo `Api.Application`.

  Com o servidor fora, a COLETA continua ligada — é ela que faz um plugin quebrado reprovar na
  suíte. O que sai é só a porta, que é recurso global e faria dezenas de arquivos `async: true`
  brigarem por 4021.
  """
  @spec metrics_server_children() :: [Supervisor.child_spec()]
  def metrics_server_children do
    config = Application.get_env(:api, :metrics, [])

    if Keyword.get(config, :server?, true) do
      porta = Keyword.get(config, :port, 4021)

      [
        Supervisor.child_spec(
          {Bandit,
           plug: {PromEx.MetricsServer.Plug, %{path: "/metrics", prom_ex_module: __MODULE__}},
           scheme: :http,
           port: porta,
           startup_log: false},
          id: __MODULE__.MetricsServer
        )
      ]
    else
      []
    end
  end

  @impl true
  def plugins do
    [
      # Versão e uptime. Barato, e é o que responde "isto reiniciou sozinho?" — um contador de
      # uptime que zera é a evidência mais direta de crash loop que existe.
      Plugins.Application,

      # A BEAM: memória por categoria, contagem de processos e portas, run queue, GC.
      #
      # `total_run_queue_lengths` é o que distingue "a máquina está sem CPU" de "o schedulers da
      # BEAM está esperando I/O" — duas causas com remédios opostos que o log confunde.
      Plugins.Beam,

      # HTTP e canais. `router` e `endpoint` são obrigatórios: é do router que sai o label
      # `route`, e sem ele toda requisição colapsa numa série só — o painel mostra que está
      # lento, e não mostra ONDE.
      {Plugins.Phoenix, router: ApiWeb.Router, endpoint: ApiWeb.Endpoint},

      # O pool de conexões, que é o gargalo real desta aplicação antes de qualquer outro: RLS por
      # transação (ADR-018) significa que toda leitura ocupa uma conexão pelo `SET LOCAL`. Aqui
      # aparece `queue_time` — quanto tempo a consulta esperou por uma conexão livre. Esse número
      # subindo é o aviso que chega ANTES do timeout que o usuário vê.
      {Plugins.Ecto, repos: [Api.Repo]},

      # As filas do Oban: materialização de pacote, envio de mensagem, poda. O que importa aqui
      # não é o job que falhou (esse o log tem, desde que `attach_default_logger` foi ligado) —
      # é o tamanho da fila e o tempo que o job passou esperando. Fila crescendo é lembrete que
      # não vai sair no horário, e ninguém descobre isso lendo log linha a linha.
      {Plugins.Oban, oban_supervisors: [Oban]}
    ]
  end
end
