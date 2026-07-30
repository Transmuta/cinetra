# 74 — Métricas do servidor: o doc irmão do 62

O [doc 62](62-plano-de-logs.md) montou o pipeline de log e, na §11.2, registrou por escrito a
lacuna que ele não fechava:

> **Não dá — e isto é uma lacuna real, não um detalhe.** "Latência do servidor" no sentido de
> **CPU, memória, I/O de disco, saturação de rede, pool do Postgres** não está aqui. Log registra o
> que a aplicação fez; não registra o estado da máquina. Um p95 subindo mostra o *sintoma*, e sem
> métricas de host não dá para dizer se a causa foi CPU saturada, disco lento ou o banco.
>
> Fechar isso é a **fase de métricas** (…). É o doc irmão.

Este é o doc irmão. Ele fecha a lacuna.

---

## 1. Três fontes, três perguntas

O Grafana passa a ter três datasources, e a divisão não é de tecnologia — é de **pergunta**:

| Fonte | Responde | Exemplo do que só ela sabe |
| --- | --- | --- |
| **Loki** (doc 62) | o que a aplicação **fez** | "a requisição `/api/agenda` das 14h03 do usuário X demorou 3,2 s" |
| **Postgres**, views `metrics_*` (doc 73) | em que estado o **negócio** está | "há 12 lembretes pendentes que não saíram" |
| **Prometheus** (este doc) | em que estado a **máquina** está | "a CPU estava em 97% e o pool do Ecto tinha 40 consultas na fila" |

A pergunta que motivou este doc precisa das três ao mesmo tempo. O Loki mostra o sintoma; sozinho,
ele não distingue "o código ficou lento" de "a máquina ficou sem CPU" — e são diagnósticos com
remédios opostos.

Vale dizer o que **não** muda: as métricas não substituem log. Elas são agregadas e sem
identidade — sabem que 5% das requisições falharam, nunca quais. Investigar um caso continua sendo
trabalho do Loki. A regra prática: **métrica para perceber, log para entender**.

## 2. As peças

```
             ┌───────────────┐
  máquina ──►│ node_exporter │──┐
             └───────────────┘  │
             ┌───────────────┐  │      ┌────────────┐      ┌─────────┐
containers ──►│   cAdvisor   │──┼─────►│ Prometheus │◄─────│ Grafana │
             └───────────────┘  │      └────────────┘      └─────────┘
             ┌───────────────┐  │        raspa 15s
    a API ──►│ PromEx :4021  │──┘
             └───────────────┘
```

Tudo na mesma VM, no stack `cinetra-obs`, ao lado do Loki/Grafana/Alloy que já estavam lá.

### 2.1 Por que o Prometheus RASPA e o Alloy EMPURRA

O Alloy, ao lado, descobre containers sozinho pelo socket do Docker. O Prometheus usa alvos
**declarados**, e a diferença parece um retrocesso mas não é:

- descoberta exigiria montar `/var/run/docker.sock` num **segundo** container. O socket montado é
  equivalente a root na máquina — o `compose.obs.yml` já comenta isso a respeito do Alloy, e
  repetir a exposição para poupar quatro linhas de YAML é troca ruim;
- são **quatro alvos**, e eles mudam quando nasce um serviço novo, não a cada deploy.

Os três alvos internos ao stack (node-exporter, cAdvisor, o próprio Prometheus) são
`static_configs` — o nome deles não muda nunca. O da **aplicação** é `file_sd_configs`, lendo
`targets/api-{dev,prod}.yml`: é o único que difere entre ambientes, e assim o `prometheus.yml`
continua sendo **um arquivo só** para os dois. De brinde, o `file_sd` recarrega sozinho —
acrescentar um alvo não reinicia o Prometheus nem perde a série em memória.

### 2.2 Por que exporters em containers separados, e não dentro do Alloy

O Alloy tem `prometheus.exporter.unix` e `prometheus.exporter.cadvisor` embutidos, e usá-los
economizaria dois containers. Foi descartado por **raio de explosão**: o Alloy é o coletor de log,
e o cAdvisor é notoriamente guloso de memória. Um pico dele derrubaria a coleta de log junto — o
oposto do argumento do doc 62 §3, que trocou a segunda VM por `mem_limit` isolando cada peça.

### 2.3 O cAdvisor roda SEM `privileged`

A documentação dele manda rodar privilegiado. Aqui ele roda sem, com montagens somente-leitura,
porque privilegiado é estritamente pior que o socket do Docker que o Alloy já monta — e aquele ao
menos é `:ro`.

**Medido**: sem privilégio saem CPU (9 séries), memória (12), rede (18), tempo de partida (10) e
`container_spec_memory_limit_bytes` — que é a métrica que importa, o `mem_limit` do compose. O que
falta são coletores de borda (perf events, resctrl) que nenhum painel usa.

## 3. O que a aplicação passou a expor

`Api.PromEx` ([`api/lib/api/prom_ex.ex`](../api/lib/api/prom_ex.ex)) liga cinco plugins:
`Application`, `Beam`, `Phoenix`, `Ecto` e `Oban`. Medido no container de dev: **417 linhas** de
métrica, ~60 famílias.

### 3.1 A porta 4021 não é rota do router

O `/metrics` serve num `Bandit` próprio, na árvore de supervisão. Quatro razões, e cada uma já
causou problema em algum projeto:

- **rate limit** — o `RateLimitGlobal` conta por IP, e o Prometheus raspa do mesmo endereço a cada
  15 s, para sempre. Mais cedo ou mais tarde ele dispara o próprio 429 e a série vira buraco —
  justamente durante um incidente, quando o tráfego sobe e o limite aperta;
- **Traefik** — rota no router é rota publicável, e um `PathPrefix` distraído exporia inventário de
  rotas, nomes de fila e volume de negócio;
- **RequestLogger** — 5.760 raspagens/dia entrariam na conta da retenção do Loki, e o doc 62 §7.4
  já teve de descartar health check pelo mesmo motivo;
- **autenticação** — `LoadScope` e `VerifyTokenSubject` não fazem sentido para um raspador.

O PromEx traz um servidor embutido; ele fica **desligado** porque usa `Plug.Cowboy`, e esta
aplicação serve por `Bandit`. Reaproveitamos o plug dele e trocamos só o servidor — uma dependência
a menos e um jeito a menos de configurar timeout e pool.

Sem autenticação, por decisão: a porta **não é publicada**, então só alcança quem já está na rede
interna do Docker — e esse atacante tem o Postgres ao lado, alvo melhor que a contagem de jobs.
O `verificar.sh` §13 confere que ela continua fechada.

### 3.2 A ordem na árvore de supervisão é contrato

`Api.PromEx` sobe **antes** de `Api.Repo` e do `Oban`. Os dois emitem um evento de `init` uma única
vez, na partida; quem sobe depois perde o evento. O efeito não é métrica faltando — é o dropdown de
repo do painel nascer vazio com **todas as outras séries presentes**. Falha caladíssima.

Está protegido por teste: mutar a ordem reprova `"o pool do repo é medido"` e **só** ele, o que
confirma que as demais métricas de fato não dependem da ordem.

## 4. Os painéis e os alertas

**Dashboard** [`11-servidor.json`](../deploy/observability/dashboards/11-servidor.json), lido de
cima para baixo do geral para o específico: máquina → containers → aplicação. 17 painéis,
30 consultas.

Três merecem nota:

- **"Memória por container: % do próprio teto"** — é o painel que fecha o argumento do doc 62 §3.
  A segunda VM foi trocada por `mem_limit` por container; aqui se confere se o limite está
  segurando ou estrangulando. O denominador leva `> 0` porque container sem limite reporta teto
  zero, a divisão vira `+Inf`, e uma linha vertical arruína a escala do painel inteiro.
- **"Alvos raspando"** — o equivalente para métricas do que "Linhas de log por minuto" é para o
  Loki. Painel vazio pode significar "nenhum problema" ou "a coleta morreu", e sem este número não
  há como distinguir.
- **"Pool do Ecto: espera por conexão"** — `queue_time` é quanto a consulta esperou por uma conexão
  livre, antes de o banco ver qualquer SQL. Com RLS por transação (ADR-018) toda leitura ocupa uma
  conexão pelo `SET LOCAL`, então é aqui que a saturação aparece primeiro. Se `queue_time` sobe e
  `total_time` não, o banco está ocioso e o pool é que está pequeno; se sobem juntos, o gargalo é o
  banco.

**Alertas** — novo grupo `cinetra-maquina` em
[`grafana-alertas.yml`](../deploy/observability/grafana-alertas.yml): disco > 85%, memória > 90%,
container > 90% do próprio teto, e alvo de métrica fora do ar.

Os três primeiros usam `noDataState: Alerting`, ao contrário dos alertas de log, que usam `OK`. A
diferença é o que a ausência significa: log sem linha quer dizer "não houve erro"; métrica de disco
sem série quer dizer que o exporter morreu — e aí ninguém está mais olhando o disco.

## 5. Como verificar

```bash
cd deploy/observability

# 1. Toda consulta de TODO dashboard, pelo caminho real do Grafana.
GRAFANA=http://localhost:3300 GRAFANA_AUTH=admin:senha python3 verificar-paineis.py

# 2. O pipeline inteiro, incluindo a seção 13 (métricas).
GRAFANA=http://localhost:3300 GRAFANA_AUTH=admin:senha DOCKER_CMD=docker ./verificar.sh
```

O `verificar-paineis.py` ganhou um ramo de Prometheus. Sem ele, toda consulta que não fosse SQL ia
para o Loki, e o dashboard de Servidor reprovaria 30 vezes por erro de sintaxe — escondendo
qualquer falha real no meio do ruído.

Medido nesta entrega: **126 consultas, 0 falhas** e **46 verificações, 0 falhas**.

Provar que um alerta dispara é passo à parte, e vale fazer: parar o `node-exporter` leva
`cinetra-coleta-de-metrica-parada` de `inactive` a `pending` em ~1 min. Regra provisionada sem erro
não é o mesmo que regra que casa.

## 6. Custo medido

Medido com `docker stats --no-stream`, com o stack todo no ar e a suíte tendo acabado de rodar:

| Componente | Limite | Uso real medido |
| --- | --- | --- |
| Loki | 1,5 GB | 171 MiB |
| Grafana | 512 MB | 300 MiB |
| Alloy | 256 MB | 170 MiB |
| **Prometheus** | **512 MB** | **194 MiB** |
| **node-exporter** | **128 MB** | **21 MiB** |
| **cAdvisor** | **512 MB** | **90 MiB** |
| **Total** | **~3,3 GB de teto** | **~946 MiB em uso** |

Numa máquina de 24 GB, a observabilidade inteira custa **~14% da memória no pior caso** e **~3,9%**
no uso real. O dimensionamento do doc 62 §3.2 já reservava espaço para esta fase.

Disco: o Prometheus tem teto **nativo** (`--storage.tsdb.retention.size=10GB`) e poda sozinho ao
encostar nele — ao contrário do Loki, que não tem e precisou do `criar-volume-limitado.sh`.

Os números do cAdvisor só são esses por causa da §7.6: na primeira versão ele consumia quase
quatro vezes mais.

## 7. O que a execução ensinou

### 7.1 `external_labels` não existe em consulta local

A primeira versão do `prometheus.yml` punha `env: dev` em `external_labels`, e os painéis
filtravam por `{env="$env"}`. Todos voltariam **vazios**.

`external_labels` só é anexado quando o dado **sai** do Prometheus: `remote_write`, federação e
notificação de alerta. Consulta local não o vê — `label_values(env)` devolve lista vazia. É o pior
tipo de defeito de observabilidade, o mesmo do doc 62 §7.4 (o rótulo `level` extraído de uma chave
inexistente): a consulta responde `success`, o painel desenha, e o que se conclui é "não houve
nada".

Corrigido pondo `env` como label do **alvo**, no `static_configs` do job da API. E ficou uma
distinção real: máquina e containers **não têm** `env`, porque a máquina é uma só, compartilhada
pelos dois ambientes — quem encher o disco derruba os dois.

### 7.2 Um filtro que não casa não dá erro — só não filtra

O `mount-points-exclude` do node-exporter passou por três medições até acertar: **97 séries** de
sistema de arquivos, das quais 58 eram bind mount interno do Docker Desktop.

A primeira versão filtrava `/mnt/host/wsl/...` e derrubou para 45. A segunda **substituiu** por
`/run/desktop/...` e chegou a 39 — porque são **dois conjuntos**, os mesmos diretórios montados por
caminhos diferentes, e trocar um pelo outro deixa metade. Somando os dois mais a exclusão de tmpfs
e 9p: **7 séries**.

A lição não é sobre WSL. É que a única forma de saber se um filtro funcionou é **contar o que
sobrou** — ele não reclama quando não casa.

### 7.3 "O ruído diminuiu muito" não é "o ruído acabou"

Ligar o PromEx encheu a suíte de `Dropping aggregation for bad tag value ... tag: :transport`. A
causa: `Phoenix.ChannelTest` monta o socket com `transport: {Phoenix.ChannelTest, pid}` — uma
**tupla**, que o coletor recusa como valor de label.

Descartar `:phoenix_channel_event_metrics` levou de centenas para **7**. Sem contar, o conserto
teria sido dado por pronto ali: as 7 restantes eram `socket.connected.duration`, do grupo
**vizinho** `:phoenix_socket_event_metrics` — mesmo campo, mesmo defeito, outro nome.

É artefato do arnês, não defeito de produção: no container de dev, com WebSocket real em uso, o
mesmo aviso apareceu **zero** vezes em duas horas de log.

### 7.4 O poller do PromEx disputa a conexão do sandbox

Pior que ruído, e o achado mais sério desta entrega. `Api.PromEx.Poller.5000` consulta `oban_jobs`
de 5 em 5 segundos a partir de um processo que não é dono de conexão no
`Ecto.Adapters.SQL.Sandbox`:

```
** (DBConnection.OwnershipError) ... the connection itself was checked out by
   #PID<0.3262.0> (:"Elixir.Api.PromEx.Poller.5000")
   (prom_ex 1.12.0) lib/prom_ex/plugins/oban.ex:440
```

Ele **checa uma conexão do pool**, disputando com o teste que estiver rodando — falha por sorteio,
a pior regressão para depurar meses depois. Aparecia em `mix coveralls` e não em `mix test`, o que
é a assinatura de uma corrida.

Resolvido com `drop_metrics_groups` em `config/test.exs`, só no teste. Em produção o poller é
justamente o que alimenta o painel "Filas do Oban".

### 7.5 A coleta fica LIGADA no teste — de propósito

A tentação era `disabled: true` no teste. Seria repetir o defeito do [doc 49](49-bate-volta-onda-6.md):
um `router:` apontando para módulo renomeado não levanta exceção, só **para de emitir**. Com a
coleta desligada, a suíte ficaria verde sobre um `/metrics` vazio.

Por isso `prom_ex_test.exs` gera tráfego real — uma requisição HTTP e uma consulta ao banco — e
exige as famílias de métrica de volta. Renomear `ApiWeb.Router` quebra o teste, em vez de quebrar o
painel três semanas depois, no meio de um incidente.

### 7.6 O painel achou o próprio erro de configuração no primeiro dia

Escrito o dashboard, a primeira coisa que ele mostrou foi o **cAdvisor a 87,8% do próprio teto** —
337 MiB de um `mem_limit` de 384 MB que eu mesmo tinha acabado de escrever. A um passo do OOM kill,
num container cuja função é justamente avisar sobre OOM kill.

Aumentar o teto seria tratar o sintoma. As quatro causas, e o que cada uma custava:

| Opção | Padrão | Por que sobrava |
| --- | --- | --- |
| `--housekeeping_interval` | **1 s** | o Prometheus raspa a cada 15 s: 14 de cada 15 amostras eram calculadas, guardadas e descartadas sem nunca serem lidas |
| `--event_storage_*_limit` | ligado | histórico de eventos em memória, num projeto onde quem guarda linha do tempo é o Loki, com 30 dias e busca |
| `--store_container_labels` | `true` | os labels do compose viravam label de MÉTRICA em toda série: custo dobrado, memória aqui e cardinalidade no Prometheus |
| `--storage_duration` | 2 min | buffer maior que a janela de raspagem |

Resultado medido: **337 MiB → 90 MiB**, uma queda de 73%. O teto subiu para 512 MB como margem,
não como remédio.

Vale registrar o método junto com o número. `docker stats` reportava 348 MiB e o alerta continuava
`inactive` — não por discordância, mas porque o alerta usa `container_memory_working_set_bytes`
(337 MiB, 87,8%), que exclui cache de página reclamável. **A métrica do painel é a certa**: é o
working set que o OOM killer considera, e `docker stats` superestima.

### 7.7 O verificador errou para o lado seguro, e isso também é bug

A checagem nova de "a porta 4021 não está publicada" acusou **exposição** com as duas portas
fechadas. A causa: o helper `status()` termina em `|| echo 000`, e o curl **já** imprime `000`
antes de sair não-zero — o resultado é a string `000000`, e comparar com `"000"` reprova sempre.

Errou para o lado seguro (alarme falso, não silêncio), mas alarme falso é como se ensina uma equipe
a ignorar o verificador — o mesmo argumento que o doc 62 usa contra `noDataState` mal escolhido.

## 8. O que este documento não faz

- **Não** traz rastreamento distribuído. O doc 62 §12 já argumentou por que OpenTelemetry fica de
  fora por ora, e nada aqui muda esse cálculo.
- **Não** substitui o monitor externo. Alerta hospedado na máquina que caiu não é enviado; o
  `cinetra-coleta-de-metrica-parada` pega alvo morto, não a máquina morta.
- **Não** usa os dashboards que o PromEx empacota. Eles são bons e podem ser subidos por API, mas
  painel enviado por API existe só no volume do Grafana: some ao recriar o container e não aparece
  em diff nenhum. A convenção do projeto é arquivo provisionado, e ela vale mais que os painéis
  prontos.
- **Não** cobre o `web/` (BFF SvelteKit). Ele aparece como container no cAdvisor — CPU, memória,
  rede — mas não expõe métrica de aplicação. Se um dia importar, é um `prom-client` e um endpoint.

## 9. Deploy em produção

Duas variáveis no `.env` do stack de observabilidade (aba Environment do Dokploy). **Nenhuma
edição de arquivo, nenhum passo manual** — a primeira versão mandava editar o `prometheus.yml` no
servidor, e isso foi desfeito de propósito: arquivo que difere entre ambientes faz o diff do PR
mentir sobre o que roda em produção.

```bash
PROMETHEUS_TARGETS=./targets/api-prod.yml   # QUEM raspar
METRICS_NETWORK=dokploy-network             # POR ONDE chegar
```

### 9.1 Por que são duas, e por que a segunda não é a `APP_NETWORK`

| serviço | precisa alcançar | mora em | rede |
| --- | --- | --- | --- |
| Grafana | Postgres (views `metrics_*`) | rede `data` do stack | `APP_NETWORK` = `cinetra-prod_data` |
| Prometheus | `/metrics` dos **dois** api | `dokploy-network` | `METRICS_NETWORK` = `dokploy-network` |

`dokploy-network` é externa e compartilhada por todos os stacks da máquina, e o serviço `api` está
nela (`networks: [data, app, dokploy-network]` no `compose.dokploy.yml`). É o que permite **um**
Prometheus raspar produção e homologação, em vez de entrar na rede `data` de cada stack.

Com uma variável só, escolher `data` deixaria o HML sem métrica e escolher `dokploy-network`
deixaria o Grafana sem banco. Em dev as duas apontam para `cinetra_default`, e é por isso que a
distinção precisa estar escrita — ela não aparece em desenvolvimento.

**Esquecer `METRICS_NETWORK` não derruba o stack**: ela herda `APP_NETWORK`. O efeito é o alvo do
HML ficar sem DNS, o que acende `cinetra-coleta-de-metrica-parada` — falha visível, não silenciosa.

### 9.2 O que NÃO precisa mudar

O `compose.dokploy.yml` da aplicação fica **intocado**. A porta 4021 não precisa de `expose:`:
containers na mesma rede alcançam qualquer porta um do outro, e `expose` é documentação. Também não
é preciso setar `METRICS_PORT` — 4021 é o default do `runtime.exs`.

### 9.3 Antes do primeiro deploy, confira os dois nomes de fora

```bash
docker ps --format '{{.Names}}' | grep api   # bate com targets/api-prod.yml?
docker network ls | grep dokploy             # a rede existe com esse nome?
```

Nome de container errado **não derruba nada**: o alvo fica `DOWN`, os painéis da aplicação ficam
vazios, e vazio lê-se como "tudo calmo". Nome de rede errado, ao contrário, impede o stack inteiro
de subir — o compose valida rede externa antes de criar container. As duas falhas são detectáveis,
mas por caminhos opostos.

### 9.4 Pendências que continuam abertas

1. **`NODE_EXPORTER_ROOTFS` não vai para o servidor.** O padrão `rslave` é o correto em Linux; o
   override existe só para Docker Desktop/WSL2, e usá-lo num servidor faz o painel de disco mostrar
   os números da partição errada (§7.2 é sobre o mesmo tipo de engano).
2. **Provar que o alerta chega.** Vale a mesma advertência do doc 62: alerta que dispara e fica só
   na tela é painel, não alerta. Configure `GF_SMTP_*` e teste com um alvo derrubado de propósito.
3. **O Grafana só alcança o Postgres de UM stack.** É anterior a esta fase (o doc 73 já sobe um
   datasource de banco só) e não piora com ela: as métricas cobrem os dois ambientes; os painéis
   que leem o banco, não.
