# O painel vazio: por que os 4xx sumiram do Grafana, e o formato de log que saiu disso

**Data:** 2026-08-01 · **Origem:** o dashboard `04 · Atrito (4xx)` abrindo "No data" em produção,
com o log inteiro presente no Loki.

## 1. O sintoma, e por que ele engana

Os cinco stats do dashboard de atrito — 422, 409, 403, 429, 401 — e todos os painéis abaixo deles
abriam **"No data"** em `prod`, janela de 24h. Nenhum erro na tela, nenhum aviso: o retângulo
vazio que o Grafana desenha quando a consulta responde certo e não traz série nenhuma.

Esse é o pior sintoma possível numa ferramenta de observabilidade, porque ele é **indistinguível
de uma boa notícia**. "Nenhum 422 nas últimas 24h" é uma leitura plausível de uma clínica com
pouco movimento — e foi assim que isso sobreviveu.

## 2. A causa

A API loga em produção com `LoggerJSON.Formatters.Basic`, que **aninha todo o metadata** sob a
chave `metadata`. A linha real, renderizada rodando o próprio formatter no container:

```json
{"message":"requisição","time":"…","severity":"info",
 "metadata":{"status":422,"method":"POST","route":"/api/patients/:id","duration_ms":12.3}}
```

O parser `| json` do Loki **achata objeto aninhado usando `_`**. Os rótulos que existiam de fato
eram, portanto:

```
message · severity · time · metadata_duration_ms · metadata_method · metadata_route · metadata_status
```

E os painéis perguntavam por `status`, `route`, `clinic_id`. Consulta sintaticamente correta sobre
um campo que não existe **não dá erro no Loki — devolve zero linhas**.

## 3. O raio do estrago

Todo painel que extraía campo da API por `| $parser` estava cego em produção:

| Dashboard | Painéis afetados |
| --- | --- |
| 04 · Atrito | **todos** |
| 01 · Visão geral | "Requisições por status" e as três de latência (`unwrap duration_ms`) |
| 02 · Requisições | volume por rota, p95 por rota, 5xx por rota, volume por clínica, lentas > 1s |
| 05 · Uso e clínicas | **todos** |
| 03 · Erros e jobs, 09 · Jobs | os painéis de `worker` — ver §5 |

Continuavam corretos, e a razão de cada um vale como lição:

- **00 · Plantão** — os painéis de 5xx não usam parser, usam regex na linha crua
  (`|~ "status[=\":]+5\\d\\d"`). Feio, e imune ao defeito.
- **os painéis de browser do 03** — consultam log do **BFF**, que já emitia achatado
  (`web/src/lib/server/log.ts`).
- **11 · Servidor e 12 · Dia a dia** — leem Prometheus, não log.

## 4. Por que os gates não pegaram

O verificador de painéis (`deploy/observability/verificar-paineis.py`) existe exatamente para isso
e roda com `ENV=dev PARSER=logfmt` por padrão. **Em dev a API loga texto**, com o metadata
achatado (`config/dev.exs`) — os nomes chatos dos painéis estão certos ali. A execução contra
prod/json está documentada no [doc 73](73-dashboards-do-log-ao-banco.md), mas ou nunca rodou, ou o
"0 série(s)" que ela devolveu foi lido como "sem tráfego" — que é a armadilha descrita no docstring
do próprio script.

> **A lição, e ela é a mesma da regra de RLS em `.claude/rules/migrations.md`:** o ambiente em que
> o gate roda define o que ele consegue ver. Um gate que só exercita dev não prova produção quando
> **o formato do dado muda entre os dois**.

## 5. A decisão: achatar na origem

Havia dois caminhos, excludentes entre si:

| Caminho | A favor | Contra |
| --- | --- | --- |
| **Mapear nos dashboards** (`json status="metadata.status"`) | Sem redeploy da API; conserta os **30 dias já gravados** | O mapeamento vira uma variável com vírgulas escapadas em 6 arquivos; todo painel novo tem de lembrar de usar `$parser` |
| **Achatar na origem** ✅ | Toda consulta existente fica correta como está escrita, inclusive as futuras; alinha API e BFF | Exige redeploy; vale só para linha nova — o log já gravado continua invisível para os painéis |

**Decidido: achatar na origem**, com um formatter do projeto (`Api.LogFormatter`). O contrato está
no moduledoc dele; em resumo, três chaves de estrutura (`time`, `severity`, `message`) e o resto
dos campos na raiz.

Dois efeitos que valem registro:

- **O `severity` continua no topo, e isso não é detalhe.** É de lá que o Alloy extrai o rótulo
  `level` (`alloy.alloy`, estágio 4). Foi o que descartou o `LoggerJSON.Formatters.Elastic`, que
  também achata mas renomeia a chave para `log.level` — consertaria os 4xx e apagaria o `level` em
  silêncio, repetindo um defeito que o comentário daquele estágio já conta ter cometido uma vez.
- **O evento estruturado do Oban também achata.** Com `encode: false` (`Api.Application`) o Oban
  entrega um **mapa** ao Logger; com o formatter antigo ele ia parar sob `message`, e o rótulo
  virava `message_worker` enquanto os painéis 03 e 09 pediam `worker`. O `event` do próprio Oban
  (`job:stop`) passa a ser a `message`, para a coluna de mensagem do painel de log não ficar vazia
  em toda linha de job.

**Sobre corpo de request e de response:** ficaram de fora nesta leva, e o [ADR-025](00-decisoes.md#adr-025--payload-e-resposta-entram-no-log-só-em-4xx5xx-e-redigidos)
os trouxe de volta logo em seguida, com escopo e redação — §8 abaixo.

## 6. Como isto foi provado, e não só testado

A suíte prova a **forma da linha**; ela não prova que o Loki consegue consultá-la. As duas coisas
foram medidas separadamente.

**a) A linha, pelo caminho real** — `ApiWeb.RequestLogger.handle/4` com uma `%Plug.Conn{}`, através
do handler de verdade do `:logger` com o formatter de produção instalado:

```json
{"message":"requisição","status":422,"time":"2026-08-01T15:20:39.581Z","severity":"info",
 "request_id":"F9x1abc","clinic_id":"019f7c5b-…","method":"POST",
 "route":"/api/patients/:id","duration_ms":12.3,"client_ip":"203.0.113.7"}
```

**b) A consulta, contra um Loki de verdade** — as duas linhas (a antiga aninhada e a nova achatada)
empurradas para o Loki local, e as consultas **exatas dos painéis**, sem uma vírgula alterada:

| Consulta do painel | linha antiga | linha nova |
| --- | --- | --- |
| `422 — formulário recusado` | **vazio** | `1` |
| `Onde dói — rota × status (4xx)` | — | `{route="/api/patients/:id", status="422"} → 1` |
| `Recusa por clínica` | — | `{clinic_id="019f7c5b-…"} → 1` |
| p95 de latência (`unwrap duration_ms`) | — | `12.3` |
| `Jobs executados por worker` | **vazio** | `{worker="Api.Messaging.ReminderJob"} → 1` |

O controle positivo é a coluna da esquerda: sem ela, "1" na direita não distinguiria *consulta
certa* de *consulta que casaria com qualquer coisa*.

## 7. O que fica pendente para decisão humana

1. **O log já gravado continua aninhado.** Os painéis só voltam a mostrar dado a partir do deploy;
   os 30 dias anteriores seguem invisíveis para eles (ainda legíveis no Explore por
   `metadata_status`). Se essa janela importar para alguma investigação em aberto, o caminho dos
   dashboards ainda pode ser aplicado **por cima** deste, temporariamente.
2. **`verificar-paineis.py` continua aprovando "0 séries".** Enquanto isso não mudar, a próxima
   divergência de formato entre dev e prod passa igual. O aperto proposto: reprovar quando uma
   consulta de log volta vazia num período em que a **mesma stream sem o parser** tem linhas.
3. **Os `args` do job do Oban agora estão na raiz da linha.** Não é regressão — já estavam no log,
   aninhados sob `message` —, mas ficaram mais visíveis, e nunca passaram por uma revisão de PII.
   Vale checar quais jobs carregam identificador de paciente em `args`.

---

## 8. A emenda: payload e resposta entram (ADR-025)

O §7 acima registrou como pendência "para um 422 você sabe *que* foi recusado, não *por quê*". A
decisão veio no mesmo dia, e é o [ADR-025](00-decisoes.md#adr-025--payload-e-resposta-entram-no-log-só-em-4xx5xx-e-redigidos):
**a linha de uma requisição recusada passa a carregar o que foi enviado e o que foi devolvido.**

Três campos novos, e nenhum deles existe fora de 4xx/5xx:

| Campo | Origem |
| --- | --- |
| `payload` | `conn.body_params` |
| `query` | `conn.query_params`, quando há |
| `response` | o corpo da resposta, capturado por `ApiWeb.Plugs.CapturarResposta` |

### O detalhe técnico que decidiu o desenho

Não dá para ler a resposta no handler de telemetria: quando `[:phoenix, :endpoint, :stop]`
dispara, **`conn.resp_body` já é `nil`**. O `Bandit.Adapter.send_resp/4` devolve `{:ok, nil,
adapter}` e o `Plug.Conn` escreve esse `nil` de volta, de propósito, para não reter o corpo depois
que ele saiu pela rede. A única janela em que o corpo ainda existe **e** o status final já está
decidido é `register_before_send/2` — daí o plug, e daí ele ficar imediatamente antes do router:
os callbacks rodam na ordem **inversa** do registro, então o último registrado é o primeiro a
rodar.

### A redação, e o que ela não faz

`Api.LogRedacao` troca por `"***"` o valor de todo campo da blocklist, e roda em duas camadas: na
origem (antes de o valor entrar no `Logger`) e como `redactors:` do formatter (que alcança
**qualquer** linha do sistema, não só a de requisição).

Duas decisões dentro dela merecem registro:

- **`tags` é redigida no log, e não na trilha de auditoria.** A divergência é deliberada. O
  argumento que liberou `tags` na trilha foi *"quem lê o diff já podia ler o campo"* — verdadeiro
  lá, porque a trilha é owner·admin e roda **sob RLS, por clínica**. O Loki não tem nenhuma das
  duas coisas: quem abre o Grafana lê o de todas as clínicas.
- **`code` só é credencial na query.** No callback do Google ele é o authorization code; no corpo
  de uma resposta é o código do erro de validação — que é exatamente o que o ADR quer poder ler.
  Uma regra só para os dois apagaria o motivo da recusa e anularia o ganho da decisão.

O casamento é por **segmento** da chave, não exato: `emergencia_tel` quebra em `["emergencia",
"tel"]` e casa; `hotel` não. Sem isso a lista teria de prever cada composição — e prever
composição é justamente o que uma blocklist não consegue fazer.

### O que isto custa, de olhos abertos

A blocklist **erra aberto**: campo novo em `Patient` que ninguém acrescentar à lista vai para o
Loki em claro, e nada avisa. Três coisas seguram o risco, e nenhuma sozinha basta — o teste que
cobra a lista contra os recursos e contra `Api.Audit.Sensiveis`, a redação por forma do valor no
Alloy, e o escopo restrito a 4xx/5xx. O risco residual foi aceito pelo decisor.

### Prova

Requisição real atravessando o pipeline inteiro, com o formatter e a redação de produção
instalados:

```json
{"message":"requisição","status":401,"route":"/api/patients","duration_ms":73.1,
 "query":{"debug":"1","token":"***"},
 "payload":{"clinic_id":"019f7c5b-…","cpf":"***","emergencia_tel":"***","nascimento":"***",
            "nome":"***","tags":"***","tel":"***"},
 "response":{"error":"unauthenticated"}}
```

`clinic_id` e `debug` em claro (é o que se investiga), os sete campos de PII mascarados, e o
`token` do magic link — a credencial que assina a sessão — fora da linha.
