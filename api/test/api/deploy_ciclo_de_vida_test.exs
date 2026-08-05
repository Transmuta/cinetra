defmodule Api.DeployCicloDeVidaTest do
  @moduledoc """
  O que acontece com o trabalho em voo quando o container é **derrubado** — e com a conexão ociosa
  quando o proxy a reaproveita. R-A1, R-M1 e R-M3 do [doc 95](../../../docs/95-analise-infraestrutura.md),
  onda 1 do [doc 102](../../../docs/102-plano-de-acao-infraestrutura.md).

  ## O job órfão (R-A1) — quatro fatos que se encaixam

  1. o default do Docker é **SIGTERM, 10 s, SIGKILL**, e o `compose.dokploy.yml` não declarava
     `stop_grace_period` em serviço nenhum;
  2. o drain do Oban é **15 s** (`Oban.Config`, `shutdown_grace_period`) — **maior** que os 10 s do
     Docker, ou seja o SIGKILL corta garantidamente o drain que o Oban planejou;
  3. `Api.Housekeeping.PruneAttachments` varre **linha a linha** de propósito (há bytes no R2 do
     outro lado) e cada deleção tem `receive_timeout` de 15 s — uma única pode consumir o drain
     inteiro;
  4. os plugins eram `Pruner` e `Cron`, e só.

  O que isso produz: a linha em `oban_jobs` fica em `state = 'executing'` **para sempre**. O
  `Pruner` não a alcança (ele poda `completed`, `cancelled` e `discarded`), ninguém a resgata, não
  há exceção — portanto **não há linha de log de erro**, e o alerta `cinetra-job-falhando`
  (`grafana-alertas.yml`) conta eventos `job:exception` que nunca vão existir. O lembrete não sai,
  o digest não sai, a poda deixa bytes órfãos pagos no R2, e nada avisa.

  ## Por que as duas metades são indivisíveis

  Só o `stop_grace_period` **reduz a chance** e não resgata nada do que já ficou órfão (inclusive de
  um OOM kill ou de um `restart: unless-stopped`, onde não há SIGTERM nenhum). Só o `Lifeline`
  resgata, mas continua matando job no meio a cada deploy. Por isso os dois moram no mesmo teste:
  se um dia alguém remover um deles, é este arquivo que fica vermelho.

  ## O que o `rescue_after` do Lifeline paga

  O `Lifeline` é, nas palavras do próprio moduledoc dele, *naive*: ele decide por tempo, não por
  saber se o nó ainda está vivo — *"may transition jobs that are genuinely executing and cause
  duplicate execution"*. O risco real aqui não é a poda (deletar objeto já deletado no R2 é
  no-op); é a fila `notifications`, onde execução dupla vira **lembrete duplicado para o
  paciente**.

  A escolha é 60 min (o default, explicitado): três ordens de grandeza acima de qualquer job de
  notificação e com folga sobre a poda. **O número a revisitar** é este, no dia em que uma poda
  legitimamente passar de uma hora — aí o `Lifeline` a resgataria com ela ainda rodando.

  ## A conexão ociosa (R-M3)

  O `keepAliveTimeout` do Node é **5 s** por default, e o pool de saída do Traefik segura conexão
  ociosa por **90 s** (`forwardingTimeouts.idleConnTimeout`). Corrida clássica: o Traefik tira do
  pool uma conexão no instante em que o Node a está fechando → **502 intermitente, sem uma linha
  no log da aplicação**, tipicamente em baixa carga. O remédio é o Node segurar por mais tempo que
  o proxy, nunca o contrário.

  ## O limite honesto deste arquivo

  Ele prova **configuração declarada**, não comportamento. Que o job seja de fato resgatado só se
  vê em `oban_jobs`, e que o 502 sumiu só se vê em `traefik_service_requests_total{code="502"}` de
  produção. O que este teste impede é a configuração **regredir em silêncio** — que é como ela
  chegou até aqui.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Compose

  # O drain que o Oban planeja por default (`Oban.Config`: `shutdown_grace_period:
  # :timer.seconds(15)`). O grace do Docker precisa ser MAIOR que isto, senão o SIGKILL corta o
  # drain no meio — que é exatamente o estado que este teste existe para não deixar voltar.
  @drain_do_oban 15

  # `SHUTDOWN_TIMEOUT` do adapter-node (`files/index.js`: `env('SHUTDOWN_TIMEOUT', '30')`), em
  # segundos. Mesmo raciocínio do de cima, do lado do BFF — e aqui o corte no meio é visível para
  # o usuário: o SSR é *streamed* (`web/src/lib/server/compress.ts`, `pipeThrough(CompressionStream)`),
  # então uma requisição cortada entrega **gzip truncado**. Página quebrada, não retry.
  @drain_do_adapter_node 30

  # `forwardingTimeouts.idleConnTimeout` do Traefik. O Node tem de segurar por mais tempo que o
  # proxy; o contrário é a corrida do R-M3.
  @idle_do_traefik 90

  setup_all do
    {:ok, compose: Compose.ler()}
  end

  describe "encerramento do container (R-A1, R-M1)" do
    test "a API segura o SIGTERM por mais tempo que o drain do Oban", %{compose: compose} do
      grace = grace_em_segundos(compose, "api")

      assert grace > @drain_do_oban,
             """
             O serviço `api` declara `stop_grace_period: #{grace}s`, que NÃO excede os \
             #{@drain_do_oban}s de drain do Oban.

             Sem essa folga o Docker manda SIGKILL no meio do drain e todo job em execução fica \
             em `state = 'executing'` para sempre: o Pruner não o alcança, não há exceção, não há \
             log e o alerta `cinetra-job-falhando` conta um evento que nunca vai existir.

             Ver o moduledoc deste arquivo.
             """
    end

    test "o BFF segura o SIGTERM por mais tempo que o drain do adapter-node", %{compose: compose} do
      grace = grace_em_segundos(compose, "web")

      assert grace > @drain_do_adapter_node,
             """
             O serviço `web` declara `stop_grace_period: #{grace}s`, que NÃO excede os \
             #{@drain_do_adapter_node}s de `SHUTDOWN_TIMEOUT` do adapter-node.

             O SSR é streamed: requisição cortada no meio entrega gzip TRUNCADO ao browser — \
             página quebrada, e não um erro que o usuário possa tentar de novo.
             """
    end

    test "o Lifeline está na lista de plugins do Oban — é ele que resgata o que ficou órfão" do
      assert Oban.Plugins.Lifeline in plugins_do_oban(),
             """
             `Oban.Plugins.Lifeline` não está nos plugins (hoje: #{inspect(plugins_do_oban())}).

             O `stop_grace_period` do compose REDUZ a chance de deixar job órfão; ele não resgata \
             o que já ficou — e num OOM kill ou num `restart: unless-stopped` não há SIGTERM \
             nenhum para respeitar grace. As duas metades entram juntas ou o buraco continua \
             aberto pelo outro lado.
             """
    end

    test "o rescue_after é folgado o bastante para não causar execução dupla" do
      rescue_after = opcoes_do_lifeline()[:rescue_after]

      # `is_integer` ANTES da comparação, e não por preciosismo: em Elixir `nil >= 1_800_000` é
      # **true** (átomo ordena acima de número), então sem esta linha o teste passava verde com o
      # Lifeline ausente da configuração — a vacuidade exata que o `Api.ComposeDeProducao` guarda
      # por dentro. Medido: foi o que aconteceu na primeira execução deste arquivo.
      assert is_integer(rescue_after),
             "`rescue_after` não é um inteiro (#{inspect(rescue_after)}) — o Lifeline está configurado?"

      assert rescue_after >= :timer.minutes(30),
             """
             `rescue_after` está em #{inspect(rescue_after)} ms.

             O Lifeline decide por TEMPO, não por saber se o nó está vivo — o moduledoc dele avisa \
             que pode ressuscitar job genuinamente em execução e causar execução dupla. Na fila \
             `notifications` isso é lembrete duplicado para o paciente.

             Se o número precisa baixar, a pergunta a responder antes é: qual o job legítimo mais \
             LONGO deste sistema?
             """
    end
  end

  describe "conexão ociosa contra o pool do Traefik (R-M3)" do
    test "o BFF segura a conexão keep-alive por mais tempo que o pool do proxy", %{
      compose: compose
    } do
      segundos =
        compose
        |> Compose.servico("web")
        |> Compose.valor_de("KEEP_ALIVE_TIMEOUT")
        |> inteiro_de()

      assert segundos > @idle_do_traefik,
             """
             `KEEP_ALIVE_TIMEOUT` do serviço `web` está em #{segundos}s, que não excede os \
             #{@idle_do_traefik}s de `idleConnTimeout` do Traefik.

             Com o Node fechando primeiro, o proxy tira do pool uma conexão que o Node está \
             fechando naquele instante e o cliente recebe **502**. Não há log na aplicação — a \
             requisição nunca chegou a ela. Vira "flakiness inexplicável", tipicamente em BAIXA \
             carga, que é quando a conexão fica ociosa tempo suficiente.

             Atenção à unidade: o adapter-node lê este valor em SEGUNDOS e multiplica por 1000.
             """
    end
  end

  # `stop_grace_period: 25s` → 25. Aceita `Nm` porque o Compose aceita, e um `1m` que fosse lido
  # como 1 faria este teste reprovar uma configuração correta.
  defp grace_em_segundos(compose, servico) do
    compose
    |> Compose.servico(servico)
    |> Compose.valor_de("stop_grace_period")
    |> String.trim()
    |> case do
      valor ->
        case Regex.run(~r/^(\d+)(s|m)?$/, valor) do
          [_todo, n, "m"] -> String.to_integer(n) * 60
          [_todo, n | _] -> String.to_integer(n)
          nil -> flunk("`stop_grace_period` do serviço `#{servico}` não é uma duração: #{valor}")
        end
    end
  end

  defp inteiro_de(valor) do
    valor |> String.trim() |> String.trim("\"") |> String.to_integer()
  end

  defp plugins_do_oban do
    Enum.map(plugins_configurados(), fn
      {modulo, _opcoes} -> modulo
      modulo when is_atom(modulo) -> modulo
    end)
  end

  defp opcoes_do_lifeline do
    Enum.find_value(plugins_configurados(), [], fn
      {Oban.Plugins.Lifeline, opcoes} -> opcoes
      _ -> nil
    end)
  end

  defp plugins_configurados do
    plugins = Application.get_env(:api, Oban)[:plugins]

    # Anti-vacuidade, no espírito do `Api.ComposeDeProducao`: se a chave sumir ou mudar de forma,
    # `plugins_do_oban/0` devolveria `[]` e a asserção do Lifeline falharia por um motivo que a
    # mensagem não explicaria.
    assert is_list(plugins) and plugins != [],
           "Application.get_env(:api, Oban)[:plugins] devolveu #{inspect(plugins)}"

    plugins
  end
end
