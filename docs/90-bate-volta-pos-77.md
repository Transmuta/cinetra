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

**Onde parou:** rodada 5, com dois achados confirmados e consertados (§2–3) — e, depois, um
terceiro conserto que nasceu de *escrever a indicação* de dois itens de handoff e perceber que
eram a mesma decisão (§4). A rodada 2 pagou: um dos dois achados só apareceu no ângulo
adversarial (mutar a regra e cobrar vermelho), não na checklist.

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
| Chave do rate limit forjável sob a topologia nova | CONFIRMADO (latente) → **corrigido**, ver §4 | `grep` em `api/config/*.exs`: `trusted_client_ip_headers` não era setado em ambiente nenhum, e o BFF já confiava em `CF-Connecting-IP` |

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

`servico/2` recorta as linhas do serviço e cobra `^\s+NOME:` — um comentário nunca casa, e o
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

## 4. O H1 e o H2 eram a mesma decisão, escrita em dois arquivos

Estavam separados nesta lista como dois itens de handoff. Ao escrever a indicação ficou claro que
são **uma pergunta só** — *qual header a edge garante?* — respondida em dois lugares distantes:
a lista do `ApiWeb.ClientIp` (API) e o `ADDRESS_HEADER` do adapter-node (BFF). E as duas respostas
**discordavam**: o BFF confiando em `CF-Connecting-IP`, a lista da API vazia, caindo no
`x-forwarded-for`. Separar essa resposta em dois lugares foi também a causa B do
[doc 68](68-bate-volta-rate-limit-global.md).

Por isso não entrou a linha crua que o [`docs/87`](87-servidor-hostinger-riscos-e-cuidados.md)
pedia. Entrou **uma variável de stack alimentando os dois lados**:

```yaml
# compose.dokploy.yml
  api:  { TRUSTED_CLIENT_IP_HEADER: "${CLIENT_IP_HEADER:-}" }
  web:  { ADDRESS_HEADER: "${CLIENT_IP_HEADER:-X-Forwarded-For}" }
```

O `runtime.exs` traduz a env em `config :api, trusted_client_ip_headers: [...]`, com `trim` +
`downcase` (o `get_req_header/2` do Plug só casa header minúsculo) e sob `config_env() != :test`,
pela razão que o bloco de traces do mesmo arquivo já tinha aprendido: senão uma variável solta no
shell de quem roda a suíte decide a cadeia de confiança.

**O default deixou de ser risco.** Sem a variável, os dois lados caem em `x-forwarded-for` — e aí
o H2 some, porque o `getClientAddress()` só levanta quando o header **configurado** falta. O XFF
também não é forjável nesse caminho: o adapter-node conta da **direita**
(`addresses[length - 1]`, `XFF_DEPTH=1`) e quem escreve a última posição é o Traefik. É a mesma
configuração do `compose.bff-test.yml`.

### O que fica para o painel do Dokploy

`CLIENT_IP_HEADER=CF-Connecting-IP` nos **dois** stacks. Não é mais uma escolha em aberto: com o
firewall da origem fechado nas faixas do Cloudflare (feito), um host em DNS-only resolve para o IP
da origem e bate no firewall — não abre. Ou seja, tudo tem que estar laranja, e aí o header da CF
é a resposta consistente.

### Teste vermelho primeiro, nas duas pontas

O teste fecha o laço inteiro, porque cada metade é invisível da outra: passar a env no compose não
faz nada se o `runtime.exs` não a lê, e ler no `runtime.exs` não faz nada se o compose não passa.

```
1) o compose passaria a env para um runtime.exs que não a lê — ligação pela metade
```

E depois, mutando de volta o hardcode (a regressão realista):

```
code:  assert valor_de(servico(compose, "web"), "ADDRESS_HEADER") =~ @fonte_do_ip
left:  " \"CF-Connecting-IP\""
right: "CLIENT_IP_HEADER"
```

Re-sonda na app rodando, que é o que o teste de compose **não** alcança:

```
sem a env                              → trusted: nil          (cai no x-forwarded-for)
TRUSTED_CLIENT_IP_HEADER="  CF-Connecting-IP  " → trusted: ["cf-connecting-ip"]
```

---

## 5. O que ainda é seu — o H3, e duas armadilhas que o firewall trouxe

**As faixas da CF no firewall do hPanel já estão postas**, então a camada que de fato fecha o
acesso à origem está de pé — vale para o app e para o `obs.*` juntos. O que sobra:

### O cinto do H3: Authenticated Origin Pulls, não `ipAllowList`

A primeira indicação deste bate-volta foi um `ipAllowList` no router `cinetra-obs`. **Está
retirada**, por dois motivos:

* seria uma **segunda cópia** da lista de faixas da CF, no repositório, ao lado da do hPanel — duas
  fontes da mesma verdade que precisam mudar juntas quando o Cloudflare mexe nos blocos;
* o `ipAllowList` olha o IP da conexão, e com publicação de porta em container isso pode chegar
  reescrito pelo SNAT do daemon. O cinto passaria a bloquear tudo, ou nada, e só medindo se sabe.

O [`docs/59:166`](59-deploy-dokploy-oci.md#L166) já nomeia a alternativa certa: **Authenticated
Origin Pulls** (mTLS Cloudflare↔origem). O Cloudflare apresenta um certificado de cliente que só
ele tem; quem bater no IP da origem com `Host: obs.cinetra.com.br` não completa o handshake. Sem
lista de IP, então sem cópia e sem deriva. Custa um arquivo de configuração dinâmica do Traefik
(`tls.options` com `clientAuth` e a CA de origin-pull da CF), e vale para o app inteiro.

O Cloudflare Access continua sendo a camada de **identidade** — e é ela que responde ao IP
dinâmico de quem administra, que nenhuma regra de rede consegue enderençar. O que ele guarda não é
um painel: é o datasource que enxerga o agregado de **todas** as clínicas, porque as views
`metrics_*` rodam com os direitos do dono e ignoram RLS por construção.

### A1 — as faixas do Cloudflare mudam

Raramente, mas mudam. Quando a CF acrescenta um bloco e o hPanel não tem, uma fatia dos visitantes
leva connection-refused: intermitente, sem nenhuma linha de log do nosso lado, e com toda a cara
de problema do usuário. Precisa de um lembrete de conferência em algum lugar que seja lido — é o
custo recorrente que a opção de firewall traz e a de mTLS não.

### A2 — o WAF pode barrar os webhooks, e o sintoma é o pesadelo já escrito

`POST /webhooks/resend` e `/webhooks/zernio` agora atravessam o Cloudflare, e vêm de **servidor**,
não de browser — exatamente o perfil que o Bot Fight Mode bloqueia. O sintoma é o que o
[`compose.dokploy.yml`](../compose.dokploy.yml) já descreve para o caso do segredo ausente: a
timeline congela em `enviado` para sempre, o Resend reentrega por horas, e nada em lugar nenhum
diz por quê.

Precisa de uma regra de exceção (skip WAF/bots em `PathPrefix(/webhooks)`) **antes** do primeiro
envio real, e de uma entrega de teste conferida logo depois. É a mais barata de fazer e a mais
cara de descobrir tarde.
