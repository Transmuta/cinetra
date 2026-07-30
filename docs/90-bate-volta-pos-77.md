# Bate-volta dos 37 commits desde o doc 77

Alvo: `a77c8bf..HEAD` (`a788e65`), 2026-07-30. É tudo que entrou desde o último bate-volta
([`77`](77-bate-volta-observabilidade-e-pacotes.md)): ~9.200 linhas de código fora de `docs/`
— web (+5.811/−678), api (+3.389/−377), deploy (+1.149/−34), compose.

As fatias no alvo: identificação única (89), e-mail em minúsculas, drawer linkável (85), teto de
confirmações (52 §4), a11y/ADR-019 (83), rename `movimento`→`cinetra` (84), deploy Hostinger +
Cloudflare (87), métricas podadas (86), rodadas de QA guiado (82, 88) e os consertos que elas
renderam.

Sondas: `psql` no `db` como `postgres` (dono) e como `cinetra_app` (NOBYPASSRLS), `mix run` no
container da API **rodando como `cinetra_app`** — que é o role do servidor real —, `mix test`, e
mutação deliberada de arquivo de configuração.

**Onde parou:** rodada 5, com dois achados confirmados e consertados. A rodada 2 pagou: um dos
dois só apareceu no ângulo adversarial (mutar a regra e cobrar vermelho), não na checklist.

---

## 1. A varredura

### Segurança

| Item | Estado | Sonda |
| --- | --- | --- |
| Bypass do BFF / ataque direto na API | REFUTADO | Traefik só roteia `/socket` e `/webhooks` (labels do compose); `/api/*` é inalcançável de fora |
| Tenant vindo do cliente | NÃO SE APLICA | nenhuma ação nova aceita `clinic_id` no corpo |
| IDOR/BOLA na rota nova `GET /api/appointments/:id` | REFUTADO | ator da clínica A + bloco da B → `nil` (404); id malformado → `nil`, não 500. Coberto na fronteira por 5 testes de controller |
| RLS como defesa-em-profundidade | REFUTADO (defesa OK) | query crua sob `cinetra_app` **sem** GUC voltou 0 linhas; com GUC, N |
| `pre_check?` das `identities` novas cego sob RLS | REFUTADO | o `SELECT` do pre-check sai **dentro** da GUC; duplicata recusada com 422, não 500 |
| Erro de identity chega ao campo certo | REFUTADO | `InvalidChanges` traz `fields: [:cpf]`, e `TenantScope.error_field/1` já lê `:fields` |
| Broken function level authz | NÃO SE APLICA | nenhuma action nova sem policy no diff |
| Mass assignment | NÃO SE APLICA | `accept @campos` inalterado nos dois cadastros |
| CORS/CSRF | NÃO SE APLICA | sem endpoint de mutação novo cross-site |
| Magic link / OAuth / sessão | NÃO SE APLICA | só a caixa do e-mail mudou (`casing: :lower`), não o fluxo |
| XSS | NÃO SE APLICA | zero `{@html` no diff do `web/` |
| SQL injection | REFUTADO | o `fragment` novo do `FilterPatients` é parametrizado; nenhuma interpolação no diff |
| SSRF / open redirect / path traversal | NÃO SE APLICA | sem superfície nova |
| Vazamento de `clinic_id` / em log | REFUTADO | o `frase_desconhecida/1` novo **tira** o átomo interno da tela e o manda ao log |
| Secrets em código | REFUTADO | senha default do role de métricas saiu (`:?` no compose); grep no diff não achou literal |
| Headers de segurança | NÃO SE APLICA | HSTS/CSP inalterados no `hooks.server.ts` |
| DoS / dependência vulnerável | NÃO SE APLICA | `mix.exs` só mudou um comentário; sem mudança em `package.json` |
| Chave do rate limit forjável sob a topologia nova | **HANDOFF (H1)** | ver §4 |

### Performance

| Item | Estado | Sonda |
| --- | --- | --- |
| N+1 no agregado novo `resposta_do_paciente` | REFUTADO | **5 queries** para 22 blocos / 23 presenças; o agregado vira um `LEFT JOIN LATERAL`, não uma query por linha |
| Tenant perdido no agregado cross-domínio | REFUTADO | o LATERAL carrega `sm0.clinic_id = $7` — a relação preserva o tenant |
| Índice no predicado de junção do LATERAL | REFUTADO | `messages_attendance_id_index` existe |
| `load: [:attendances]` novo no relatório | REFUTADO | coberto por `attendances_one_per_patient_per_appt_index (clinic_id, appointment_id, patient_id)` |
| FK nova sem índice | NÃO SE APLICA | nenhuma FK nova; as 4 sem índice-líder são pré-existentes e fora do alvo |
| Índices novos redundantes | REFUTADO | os 6 únicos são `(clinic_id, campo)`; nenhum duplica prefixo existente |
| `CONCURRENTLY` na migration | REFUTADO | tabelas chegam vazias no servidor; a migration justifica a exceção à regra §2 |
| Query sem `LIMIT` | REFUTADO | `list_attendance_messages!` lê 1–4 linhas por presença |
| Waterfall no BFF | REFUTADO | `/api/patients/lookup` faz até 3 chamadas **em série**, mas com curto-circuito: o caso comum é 1, atrás de debounce de 400 ms. Paralelizar aumentaria a carga média |
| Transação longa segurando GUC | NÃO SE APLICA | sem I/O externo novo dentro de ação |

### Refatoração / rules

| Item | Estado | Sonda |
| --- | --- | --- |
| Segunda fonte da mesma verdade — teto de confirmações | REFUTADO | `LIMITE_DE_CONFIRMACOES` (web) espelha `@limite_de_confirmacoes` (api); ambos fixados por teste dos dois lados, e `travaDeRepeticao` casa item a item com `barreira/3` |
| Regra de negócio no BFF | REFUTADO | o lookup só *avisa*; quem recusa é a identity |
| Constante/literal repetida | REFUTADO | `frase_desconhecida/1` unificou as três portas que despejavam átomo cru |
| Change com lógica não-trivial inline | REFUTADO | `Api.Changes.Canonicalizar` é módulo próprio, em namespace neutro |
| Canonicalização com porta de trás | REFUTADO | só `create`/`update` escrevem cpf/tel/e-mail; `deactivate`/`reactivate` tocam só `ativo` |
| Comentário que contradiz o código | REFUTADO | o `patient_reply_controller.ex` **corrigiu** um (o "já aparece no status do bloco" que não aparecia) |
| Unidade das quebras do relatório | **CONFIRMADO (C1)** | ver §2 |
| Guarda de regressão que não guarda | **CONFIRMADO (C2)** | ver §2 |

**O que a rodada 2 achou que a 1 não tinha achado:** o C2. A checklist lê o teste e vê uma
asserção; o ângulo adversarial — *mute a regra e cobre vermelho*, de
[`.claude/rules/migrations.md`](../.claude/rules/migrations.md) §3 — é o que mostra que ela não
morde.

---

## 2. As causas-raiz

Duas, independentes, e do mesmo feitio: **a mudança fez 90% do que anunciou, e o resto ficou em
silêncio.**

### C1 — o relatório trocou de unidade em três das quatro quebras

`4cdf1e7` ("o número conta quem foi atendido, não o bloco") converteu `summary_totais`,
`summary_por_dia` e `summary_por_profissional` de bloco para presença. `summary_por_tipo/1`
continuou com `length(list)` sobre agendamentos.

Sonda — mesmo relatório, mesmo período, dados vivos de dev:

```
### totais.atendimentos    = 2
### soma por_dia           = 2
### soma por_profissional  = 2
### soma por_tipo          = 1   <-- ?
```

O estrago não é só um número discordando. O card divide `row.total` por `totais.atendimentos`
([`relatorios/+page.svelte:286`](../web/src/routes/(app)/relatorios/+page.svelte#L286)), então a
porcentagem é **uma contagem de blocos sobre um total de presenças**: uma turma de quatro aparece
como "1 (25%)" embaixo de um KPI dizendo 4, e as fatias não somam 100%. Em atendimento individual
os dois números coincidem — que é exatamente por que o desvio sobreviveu ao commit que existia
para eliminá-lo.

### C2 — `Api.DeployEnvTest` casava por substring no arquivo inteiro

`9e2f57f` consertou um bug real (o compose de produção nunca passou as envs de comunicação:
sem `RESEND_API_KEY` nenhum e-mail sai, nem o magic link) e trouxe um teste para prendê-lo. A
asserção era `assert compose =~ env` sobre o texto cru — e o compose **cita as duas envs nos
comentários** que explicam por que elas são obrigatórias.

Sonda — apaguei do bloco `environment:` exatamente as duas linhas cujo sumiço o teste existe para
pegar, preservando os comentários:

```
$ grep -n "RESEND_API_KEY" compose.dokploy.yml
161:      #   * sem RESEND_API_KEY o mailer cai no adapter `Local` (runtime.exs) e NENHUM e-mail sai,

$ mix test test/api/deploy_env_test.exs
1 test, 0 failures        # ← verde, com a regressão presente
```

---

## 3. O que foi corrigido

### C1 — `summary_por_tipo/1` passa a contar presença

**Teste vermelho primeiro** (`api/test/api/scheduling/summary_test.exs`), sobre a invariante que
fecha o assunto — quebras do mesmo relatório têm de somar o mesmo total:

```
por_tipo soma 2 mas os totais dizem 3 — unidades diferentes
1 test, 1 failure
```

O conserto reusa o `summary_presencas/1` que as outras três quebras já usam
([`api/lib/api/scheduling.ex:935`](../api/lib/api/scheduling.ex#L935)) — a unidade passa a ter
uma fonte só. Dois testes entraram: a invariante da soma (turma de 2 + individual = 3) e o
recorte da presença `:cancelada`.

**Re-sonda, com a mesma sonda que encontrou o achado:**

```
### totais.atendimentos    = 2
### soma por_dia           = 2
### soma por_profissional  = 2
### soma por_tipo          = 2   ✓
```

### C2 — a asserção passa a olhar a chave YAML dentro do serviço `api`

`servico_api/1` recorta as linhas do serviço e cobra `^\s+NOME:` — um comentário nunca casa, e o
recorte impede que a env migrar para o `web` conte como se estivesse aqui. Ganhou também a guarda
contra o recorte virar vazio, no mesmo espírito do `assert length(nomes) >= 5` que já existia.

**Verificação por mutação** (a mesma que expôs o achado):

```
com as duas linhas apagadas → 1 test, 1 failure
  `RESEND_API_KEY` é lida por config/runtime.exs mas não é passada ao container da API
compose restaurado          → 1 test, 0 failures
```

### Auditoria do diff dos consertos

Código novo é código não-auditado. O que a superfície acende:

- **query nova?** Não — `summary_por_tipo/1` opera sobre presenças já carregadas pelo
  `load: [:attendances]`. O trabalho extra é O(presenças), sem ida ao banco.
- **contrato da fronteira?** `por_tipo` pode agora omitir um tipo com zero presenças. A tela
  trata: `{#if report.por_tipo.length}` cai no estado vazio, e `maxTipo` já usa `Math.max(1, …)`.
- **comentário que contradiz o código?** O `@doc` de `load_summary/5` não declara unidade; o
  comentário novo declara, e cita o porquê.
- **`NÃO SE APLICA` que deixou de valer?** Nenhum: os consertos não abrem endpoint, render nem
  migration.

---

## 4. O que ficou para você

Três, todos de **decisão de deploy** — a correção não é código, é postura de infraestrutura, e
nenhuma é sondável a partir daqui.

### H1 — `trusted_client_ip_headers` não entrou junto com o Cloudflare

**O que é.** `ApiWeb.ClientIp` teve o default trocado para `[]` (certo: o `["fly-client-ip"]`
antigo sobreviveu à saída da Fly e virou forjável). A queda é para `x-forwarded-for`, e
`forwarded/2` pega o **primeiro** da cadeia. O
[`docs/87`](87-servidor-hostinger-riscos-e-cuidados.md) (linha 269) pede
`config :api, trusted_client_ip_headers: ["cf-connecting-ip"]` **junto** com a troca de edge; o
[`docs/84`](84-rename-movimento-para-cinetra.md) (linha 105) já anotou que ele não é configurado
em ambiente nenhum. Continua não sendo.

**A sonda.** `grep` em `api/config/*.exs`: a chave não aparece. E o router mostra que os dois
limitadores por IP vivem em `/api/*` e no scope `/` do reply/OAuth — **nenhum deles alcançável de
fora**, porque o Traefik só roteia `/socket` e `/webhooks` para a API. No caminho real
(browser → CF → Traefik → BFF → API) quem escreve o header é o BFF, com `headers.set` sobre o
`getClientAddress()`, e é honesto.

**Por que não foi corrigido.** Não é exploitável hoje, e a linha de config é uma decisão de
topologia que precisa entrar no mesmo passo do provisionamento — mudá-la agora, sem o servidor
de pé, cria a assimetria inversa. É armadilha para o dia em que alguém rotear um terceiro
`PathPrefix` para a API.

**Qual seria a correção.** A linha do docs/87 no `runtime.exs`, condicionada ao ambiente, no
commit que provisiona a Hostinger.

### H2 — `ADDRESS_HEADER=CF-Connecting-IP` faz o BFF **levantar** se o header faltar

**O que é.** O `compose.dokploy.yml` passou o BFF de `X-Forwarded-For` para `CF-Connecting-IP`.
O `getClientAddress()` do adapter-node **lança** quando o header configurado está ausente:

```js
if (!(address_header in req.headers)) {
  throw new Error(`Address header was specified with ${env_prefix}ADDRESS_HEADER=${address_header} but is absent from request`);
}
```
(`web/.svelte-kit/adapter-node/entries/handler.js:115-119`)

Ele é chamado por `headersDeContexto`, que está em **toda** chamada do BFF à API. Logo: qualquer
requisição que chegue à origem fora do Cloudflare responde 500 em toda página que fale com a API.

**Por que não foi corrigido.** É a postura desejada para produção (a origem só deve ser alcançada
via CF), e trocar por um fallback tolerante *reintroduziria* o furo do H1 pelo outro lado. O que
precisa de decisão é: **HML também está laranja no Cloudflare?** Se estiver em DNS-only, ela
nasce 100% quebrada. O healthcheck do Traefik não é afetado — ele bate em `/health`, que não
toca a API.

**Qual seria a correção.** Confirmar o proxy nos dois hosts antes do primeiro deploy; se HML
ficar cinza, ela precisa de `ADDRESS_HEADER: X-Forwarded-For` próprio.

### H3 — o Grafana em `obs.cinetra.com.br` depende de proteção que não mora no repositório

**O que é.** `deploy/observability/compose.obs.yml` ganhou `traefik.enable=true` +
`Host(${GRAFANA_HOST})` + `tls=true`, sem `middlewares`. O bind em `127.0.0.1` (achado A2 do doc 86)
está certo e o `verificar.sh` §13 o cobra — mas o roteamento novo publica o login do Grafana no
domínio, e o que o protege é o **Cloudflare Access**, configurado fora do repositório. Uma
requisição direta ao IP da origem com `Host: obs.cinetra.com.br` chega ao Traefik e passa ao lado
do Access.

**Por que não foi corrigido.** É a mesma decisão do H2 (a origem só pode aceitar as faixas do
Cloudflare) e ela é de firewall, não de compose.

**Qual seria a correção.** Fechar a 443 da origem para fora das faixas da CF no hPanel — que o
docs/87 já prevê — e, como cinto, um middleware `ipAllowList` do Traefik no router
`cinetra-obs`. Vale lembrar o que está atrás dessa porta: o datasource do banco enxerga o
agregado de **todas** as clínicas, porque as views `metrics_*` rodam com os direitos do dono.
