# 76 — Traces: o terceiro sinal

> Construído em 2026-07-29. Fecha o trio de sinais: o [doc 62](62-plano-de-logs.md) montou o log,
> o [doc 79](79-signoz-vs-hyperdx.md) e o compose das métricas montaram o Prometheus, e aqui entra
> o trace — **Grafana Tempo**, recebendo pelo Alloy que já roda ao lado.
>
> Este doc **reverte uma decisão escrita duas vezes**. O porquê está no §1; o que a execução
> ensinou, no §7 — e ali estão seis armadilhas que custaram diagnóstico, quatro delas da classe
> "sobe, não dá erro nenhum e não funciona".

---

## 1. A decisão que muda, e o que exatamente muda nela

O [doc 62 §12](62-plano-de-logs.md) e o [doc 79 §5](79-signoz-vs-hyperdx.md) recusaram tracing. O
argumento central, repetido nos dois e também nos moduledocs de `Api.Correlacao` e do
`correlacao.ts`, era:

> trace é o item de maior custo, menor ganho marginal com apenas dois serviços, e **maior
> superfície de vazamento** (todo atributo de span é dado exportado).

O ponto de custo/ganho continua verdadeiro e foi **decidido contra**: com o log carregando
`request_id` e `clinic_id`, dá para responder quase tudo — mas "quase tudo" deixava de fora
exatamente a pergunta que mais se faz numa tela lenta: *onde foram os 3 segundos*. Log e métrica
dizem que a requisição demorou e que a máquina estava tranquila; nenhum dos dois diz que 2,8 s
foram numa consulta do Ecto disparada duas vezes.

O ponto do **vazamento**, por outro lado, não é mais o mesmo argumento. Ele foi escrito contra
SaaS — mandar span para fora da nossa infraestrutura. Não é o que acontece aqui:

```
   API (Elixir) ──┐
                  ├──► Alloy ──► Tempo ──► Grafana
   BFF (Node) ────┘   (mesmo agente     (mesmo volume,
                       que já lê o log)   mesma máquina)
```

O span nasce no app, passa pelo agente que já processa o log há meses e para num volume da mesma
VM. **Mesmo perímetro do log**, com a mesma redação de PII disponível no mesmo arquivo. O que
sobra do argumento não é vazamento, é **volume de detalhe** — e a resposta a isso é a poda (§4).

---

## 2. O desenho, e por que os spans passam pelo agente

Os apps não falam com o Tempo. Falam com o **Alloy**, e o Tempo só aceita OTLP vindo dele.

Isso não é simetria estética com o log — é onde a poda vai morar. Um processador no
[`alloy.alloy`](../deploy/observability/alloy.alloy) remove um atributo dos **dois serviços de uma
vez**, sem rebuild de imagem e sem tocar em código de aplicação. A alternativa seria a mesma regra
escrita em Elixir e em TypeScript, divergindo com o tempo — que é precisamente o motivo de a
redação de CPF/e-mail/telefone do log morar lá e não no logger de cada app.

| Peça | Onde | Papel |
| --- | --- | --- |
| `otelcol.receiver.otlp` | `alloy.alloy` | escuta 4317 (gRPC, Elixir) e 4318 (HTTP, Node) |
| `otelcol.processor.memory_limiter` | `alloy.alloy` | recusa span na porta antes de o OOM levar junto a coleta de log |
| `otelcol.processor.batch` | `alloy.alloy` | lotes |
| `tempo` | `compose.obs.yml` + `tempo.yml` | armazena; retenção 7 dias |
| datasource `Tempo` + `derivedFields` | `grafana-datasources.yml` | a costura log ↔ trace (§5) |

**Uma variável liga tudo:** `OTEL_EXPORTER_OTLP_ENDPOINT`. Vazia, o exportador do Elixir é `:none`
e o `otel.mjs` do BFF nem constrói o SDK — dev sem stack de observabilidade, CI e a suíte ficam
exatamente como estavam. Ligar trace não pode virar pré-requisito para rodar o projeto.

---

## 3. O que está instrumentado

**API (Elixir)** — `Api.Tracing.setup/0`, chamado antes da árvore de supervisão:

| Pacote | Cobre | Por que é necessário junto dos outros |
| --- | --- | --- |
| `opentelemetry_bandit` | span de servidor | é quem **lê o `traceparent`** do BFF; sem ele, dois traces órfãos |
| `opentelemetry_phoenix` | rota, controller, action | com adapter `:bandit` ele NÃO cria span, só enriquece o de cima |
| `opentelemetry_ecto` | consulta | onde o tempo costuma estar de fato |
| `opentelemetry_oban` | job | o trace atravessa a fila, como o `request_id` já atravessava |

**BFF (Node)** — [`web/otel.mjs`](../web/otel.mjs), carregado com `node --import` antes da
aplicação: `instrumentation-http` (span de servidor) e `instrumentation-undici` (o `fetch` para a
API — é ele quem **escreve** o `traceparent`).

Provado ao vivo, num trace só, com os dois serviços:

```
[cinetra-web] GET                (instrumentation-undici)   ← escreve traceparent
[cinetra-api] GET /api/health    (opentelemetry_bandit)     ← lê traceparent
```

---

## 4. O que vai no span hoje — e o plano de poda

A decisão de partida foi **ligar com os atributos padrão e podar depois**. Estes são os atributos
reais, colhidos de um trace de verdade (não da documentação):

| Origem | Atributos |
| --- | --- |
| Servidor (bandit) | `url.path`, `http.route`, `http.request.method`, `http.response.status_code`, `phoenix.plug`, `phoenix.action`, `client.address`, `network.peer.*`, `server.*`, `user_agent.original` |
| Cliente (undici) | `url.full`, `url.path`, `url.query`, `server.address`, `network.peer.*`, `http.*` |
| Ecto | `db.statement`, `db.system`, `db.name`, `db.instance`, `db.url`, `source`, `*_time_microseconds` |

**O que a poda deve mirar primeiro, e por quê:**

1. **`url.path` e `url.full`** — carregam o caminho REAL, com o UUID: `/api/patients/019f7c5b-…`.
   É o único identificador que o [doc 05 §1.3](05-observabilidade-e-producao.md) proíbe exportar,
   e é o que o `RequestLogger` e o `sanitizarRota` já trocam por `:id` no log. **`http.route` já
   traz a rota parametrizada**, então remover `url.path` não perde a capacidade de agrupar.
2. **`db.statement`** — útil na largada (é o que responde "qual consulta"), volumoso depois. Note
   que ele **não carrega valores**: o Ecto emite SQL parametrizado (`WHERE cpf = $1`), então o CPF
   não está ali. O risco aqui é volume, não PII.
3. **`network.peer.*` / `client.address`** — IP interno de container. Ruído em quase toda
   investigação.

O lugar da poda está preparado e comentado no `alloy.alloy`, com o `otelcol.processor.transform`
pronto para descomentar. Ficou **comentado de propósito**: processador vazio que não remove nada é
código morto que parece proteção — a mesma classe de erro do rótulo `level` que saía sempre vazio
(doc 62 §10).

O `test/api/tracing_test.exs` tem uma asserção sobre `db.statement` que é a **trava consciente**
desta decisão: podar aquele atributo exige mudar o teste, ou seja, uma decisão explícita.

### O que já foi cortado na origem

Só uma coisa, e por ser ruído puro e não dado: requisições de `/_app/immutable/`, favicon e health
check não viram span (`ignoreIncomingRequestHook` no `otel.mjs`). Uma navegação carrega dezenas de
arquivos estáticos; sem o corte, a lista do Tempo vira 95% JavaScript e o trace que interessa
some no meio. É a mesma decisão que o doc 62 §2.1 tomou para o log.

---

## 5. A costura: log ↔ trace

É o que transforma dois bancos separados numa ferramenta só, e depende de **um campo**:

- toda linha de log carrega `trace_id` — no Elixir pelo `ApiWeb.Plugs.TraceMetadata` (que usa
  `Logger.metadata/1`, então vale para **todas** as linhas do processo, não só a da requisição);
  no BFF pelo `correlacaoDeTrace()` do `log.ts`;
- o `derivedFields` do datasource do Loki lê esse campo e oferece o botão **"Ver trace"**;
- o `tracesToLogsV2` do datasource do Tempo faz o caminho de volta.

Quebrou o campo, quebraram os dois sentidos — e **nada dá erro**: o botão apenas não aparece. Por
isso há teste dos dois lados (`tracing_test.exs` e `log.test.ts`) e uma asserção no
`verificar.sh` §14.

`request_id` **continua existindo** e não foi substituído: ele sobrevive 30 dias no Loki (contra 7
do trace), atravessa para o job do Oban por `Api.Correlacao`, e é o que existe quando o trace está
desligado. Os dois convivem de propósito.

---

## 6. Recursos e retenção

| | Teto | Observação |
| --- | --- | --- |
| Tempo | 512 MB | rajada fica no ingester até o bloco fechar (5 min) |
| Alloy | 256 → **384 MB** | subiu junto com o receptor OTLP, que segura lote em memória |
| Retenção | **7 dias** | contra 30 do Loki e do Prometheus |

A assimetria da retenção é deliberada — trace é o sinal mais caro por byte e responde à pergunta
mais recente — e tem uma **consequência que precisa ser conhecida**: o log guarda `trace_id` por 30
dias, então em log com mais de 7 dias o botão "Ver trace" abre um trace vazio. Não é defeito; subir
é `TEMPO_RETENTION=720h` se um dia incomodar mais que o disco.

O Tempo, como o Loki, tem retenção por tempo e **nenhum teto de tamanho** — quem impõe o teto é o
sistema de arquivos. O `criar-volume-limitado.sh` agora serve aos dois (passa-se outro ponto de
montagem) e `TEMPO_DATA` aponta para ele.

---

## 7. O que a execução ensinou

Seis achados medidos. Quatro são da mesma família — **sobe, não dá erro, não funciona** —, que é o
modo de falhar típico de instrumentação.

### 7.1 A imagem do Tempo é distroless, e o healthcheck derrubou o Alloy

Copiar o healthcheck do Loki (`wget … | grep ready`) parecia trivial. A imagem do Tempo não tem
`/bin/sh` nem `wget`: todo teste falhou com "no such file or directory" e o container ficou
`unhealthy` **para sempre**, com o serviço perfeito. Como o Alloy tinha `depends_on:
condition: service_healthy`, o efeito não foi um trace faltando — foi **a coleta de log parar de
subir**, por causa do healthcheck do trace.

Ficou sem healthcheck, com `service_started`, e a prontidão é verificada de fora (`verificar.sh`
§14). O exportador reconecta sozinho, então esperar frouxo custa alguns spans, não o agente.

### 7.2 Em ESM, o SDK sobe e não instrumenta nada

O BFF tinha as variáveis certas, o `otel.mjs` comprovadamente carregado (conferido no
`/proc/<pid>/environ`), o SDK iniciado — e **zero spans**, enquanto a API mandava normalmente.

A instrumentação automática funciona trocando o módulo por baixo de quem o importa. Em CommonJS
isso é feito interceptando `require`; em **ESM** é preciso registrar um loader:

```js
register('import-in-the-middle/hook.mjs', import.meta.url, { data: { include: [...] } });
```

O diagnóstico só fechou ao notar que `node -e` (contexto CommonJS) instrumentava e o Vite (ESM)
não. Este projeto é ESM ponta a ponta, então a linha não é opcional.

### 7.3 …e o loader sem `include` derrubou o servidor de dev

Registrado sem lista, o hook intercepta **todo** módulo ESM do processo. O embrulho não é
transparente para código que inspeciona as próprias funções: o compilador do Svelte passou a
estourar `locator is not a function` e **toda página virou 500**. A ferramenta de observabilidade
derrubou o servidor que ela observa.

Com `include: ['http', 'https', 'node:http', 'node:https']` — os únicos que precisam do loader —
as páginas voltaram. O `undici` não entra na lista de propósito: aquela instrumentação escuta
`diagnostics_channel` do Node e não troca módulo nenhum.

### 7.4 O `runtime.exs` roda na suíte, e ligar trace em dev quebrou os testes

`config/runtime.exs` é avaliado em **todos** os ambientes, `:test` inclusive. Ao ligar o trace no
`.env` de dev, a config passou a sobrescrever o `span_processor: :simple` do `test.exs`; o
`otel_simple_processor_global` deixou de existir e os testes de trace morreram com "no process".

O modo de falhar é o pior possível: **verde no CI** (que não tem a variável) e vermelho só na
máquina de quem ligou observabilidade. A guarda é `config_env() != :test`, e há teste de regressão
prendendo as duas chaves.

### 7.5 `mix run`/`bin/api eval` reclamam do exportador — e é inofensivo

Processo efêmero com OTLP ligado imprime `OTLP exporter failed to initialize: bad argument`: o
canal gRPC sobe enquanto as aplicações já estão encerrando. O servidor de longa duração **nunca**
emite isso (medido: zero ocorrências no log do container) e os spans chegam normalmente. Vale
saber porque `Api.Release.setup/0` roda por `bin/api eval` no deploy — o aviso vai aparecer ali.

---

### 7.6 A lista de metadata do Logger existe em TRÊS arquivos, e a de produção venceu

O mais perigoso da fatia, e só a verificação ao vivo pegou. `config.exs`, `dev.exs` e `prod.exs`
declaram cada um a sua lista `metadata:` do Logger, e a do ambiente **sobrescreve** a comum.
Acrescentar `:trace_id` apenas no `config.exs` deixou a costura:

- **verde na suíte** — que roda com a lista do `config.exs`;
- **morta em dev** — a linha saía com `request_id=…` e sem `trace_id`;
- **morta em produção** — onde ela é a razão de existir: o `LoggerJSON` do `prod.exs` descarta toda
  chave fora da sua lista, e é desse JSON que o Loki indexa o campo que o `derivedFields` procura.

O sintoma seria: trace perfeito no Tempo, log perfeito no Loki, e o botão "Ver trace" nunca
aparecendo — sem um erro em lugar nenhum.

A regressão está presa por dois testes que leem a configuração **real** de cada ambiente com
`Config.Reader.read!/2`, em vez de repetir a lista numa terceira cópia dentro do teste.

E há um detalhe operacional que atrasou o diagnóstico: **config de Logger não é recarregada pelo
code reloader**. Depois de mexer em `dev.exs`, só reiniciando o container.

## 8. Como verificar

```bash
deploy/observability/verificar.sh      # §14: Tempo pronto, OS DOIS serviços com span,
                                       #      trace_id no log, portas OTLP não publicadas
```

A asserção que mais importa é a de **dois** serviços. Trace só com a API é metade da história:
significa que a propagação quebrou, ou que o agente não é alcançável a partir da rede do BFF — e
cada serviço, sozinho, parece estar funcionando.

> **Armadilha de rede em produção.** O Grafana precisa da rede do BANCO (`<projeto>_data`); o Alloy
> precisa da rede **API↔WEB** (`<projeto>_app`), que é a única com os dois serviços — o web não
> entra na rede do banco de propósito. São duas variáveis diferentes no `.env` do stack de
> observabilidade: `APP_NETWORK` e `APP_NETWORK_OTLP`.

---

## 9. O que este trabalho NÃO faz

- **`span-metrics` e `service-graphs`** (os processadores do `metrics_generator` que fazem
  **remote_write para o Prometheus**). Ficam desligados **enquanto os spans saírem com `url.path`
  cheio de UUID**: viraria uma série por caminho, e o Prometheus tem teto de disco. É o passo
  seguinte à poda, não anterior.

  Cuidado para não confundi-los com o **`local-blocks`**, que está LIGADO (§10): aquele não
  escreve série em lugar nenhum — guarda blocos aqui dentro para responder TraceQL metrics.
- **Amostragem.** Hoje é 100%. Com o volume atual isso é barato; o dia de amostrar é quando o
  disco do Tempo mandar, e a decisão vem com medição.
- **RUM / trace no browser.** Continua fora, pelo [doc 05 §1.2](05-observabilidade-e-producao.md) e
  pelo ADR-007 — o trace começa no BFF.
- **Migrar para plataforma unificada.** O [doc 79](79-signoz-vs-hyperdx.md) segue valendo: os 97
  painéis em LogQL e o pipeline de redação são o ativo, e agora o Grafana entrega os três sinais.

---

## 10. O Traces Drilldown, e o processador que ele exige

O Grafana 12 traz os apps de **Drilldown** (Logs, Metrics, Traces, Profiles) já instalados — o de
traces é o `grafana-exploretraces-app`, em **Drilldown → Traces**. Ele é a maneira mais direta de
usar o que foi construído aqui: taxa de spans, taxa de erro e histograma de duração no topo, e
abaixo um *breakdown* por atributo (serviço, rota, `span.kind`) sem escrever uma linha de TraceQL.

**Ele não funciona só com os traces armazenados.** O app é construído sobre **TraceQL metrics** —
consultas como `{} | rate() by (resource.service.name)` e
`{} | quantile_over_time(duration, .95)` —, e quem as responde é o processador **`local-blocks`**
do `metrics_generator`. Sem ele, o Tempo devolve **500** nessas consultas: o app abre, os painéis
ficam em erro, e a busca de traces continua funcionando perfeitamente ao lado. Foi exatamente esse
o estado da primeira versão desta fatia.

A distinção que importa, e que fez o `metrics_generator` sair de "desligado" para "ligado pela
metade":

| Processador | Escreve onde | Estado | Por quê |
| --- | --- | --- | --- |
| `local-blocks` | bloco local, dentro do Tempo | **ligado** | é o que o Drilldown exige; não gera série no Prometheus, então a cardinalidade do `url.path` não o afeta |
| `span-metrics` | **remote_write** → Prometheus | desligado | uma série por caminho, com UUID de paciente dentro. Passo seguinte à poda (§4) |
| `service-graphs` | **remote_write** → Prometheus | desligado | idem |

Por isso `overrides.defaults.metrics_generator.processors` é uma lista **explícita com um item só**:
acrescentar qualquer um dos outros dois é decisão consciente, não efeito colateral de "ligar o
gerador".

Verificado ao vivo em 2026-07-29: as duas consultas acima respondem com série para `cinetra-api` e
`cinetra-web`, e as abas *Breakdown*, *Service structure* e *Traces* do app carregam.

---

## 11. Primeira poda aplicada: o encanamento do banco

Medido num `POST /api/appointments` real (criar agendamento pela tela), antes de qualquer poda:

| | spans | tempo |
| --- | --- | --- |
| `begin` / `commit` | 16 | — |
| `SELECT set_config(...)` — a GUC do tenant, uma por transação | 14 | — |
| **encanamento, somado** | **30 (45%)** | 13,8 ms |
| consultas de domínio | 34 | 46,9 ms |
| **trace inteiro** | **67** | 200,1 ms (188,8 ms na API) |

Quase metade do trace dizia apenas "abriu transação" e "carimbou a GUC". Não é diagnóstico, é
encanamento — e o custo não era só volume: eram 30 linhas empurrando para fora da tela as 34 que
respondem *onde foi o tempo*.

O `otelcol.processor.filter "encanamento"` do [`alloy.alloy`](../deploy/observability/alloy.alloy)
descarta esses spans. Verificado depois: num trace de 46 spans com 37 consultas, **zero**
remanescentes.

**O que se perde:** enxergar as fronteiras de transação na cascata. Aceito conscientemente — quando
a pergunta for essa, o log do Postgres responde melhor que um trace de aplicação.

> **Armadilha do `error_mode`.** Span sem `db.statement` (todo span de HTTP) faz a expressão OTTL
> falhar, e o padrão do processador é **descartar** o span quando a condição erra. Sem
> `error_mode = "ignore"`, a poda do banco levaria junto os spans de servidor — ou seja, o trace
> inteiro. Falha silenciosa e total.

### O que a poda revelou

Com o ruído fora, o que sobra fica legível — e o primeiro trace já mostrou um padrão que vale
investigar (não é dívida registrada aqui; é a medição, que antes não existia):

- **carregar uma tela** dispara ~5 chamadas do BFF à API, e cada uma revalida a sessão:
  `tokens` **12×**, `memberships` 5×, `clinics` 5×, `users` 4× num único trace. Parte é o preço do
  modelo de sessão em allowlist ([doc 14](14-sessao-e-tokens.md)) — o `jti` é conferido na tabela a
  cada requisição, que é o que permite revogar na hora;
- **criar um agendamento** relê `appointment_types` 4×, `patients` 2×, `clinics` 2× e
  `professionals` 2× na mesma requisição, em 8 transações separadas.

Nenhum desses números é conclusão de otimização — são as perguntas que só o trace permite fazer.
