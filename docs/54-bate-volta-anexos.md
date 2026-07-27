# 54 — Bate-volta da fatia de anexos (doc 51)

Auditoria da fatia de anexos do paciente e das correções de design da ficha, contra a **stack
rodando**: `psql` como `movimento_app`, `curl` no BFF e na API, `EXPLAIN (ANALYZE, BUFFERS)` nos
planos reais, `docker compose logs api` durante os fluxos, Playwright no browser.

**Onde parou:** rodada 5. As duas caças acharam **5 causas-raiz + 3 menores**; todas consertadas.
A rodada 5 achou mais **um achado dentro do próprio conserto**, também corrigido, e deixou
**5 itens para decisão humana**.

**Fora do alvo, de propósito:** o trabalho concorrente na mesma árvore (notificações, docs 52/53,
`web/src/lib/components/shell/*`, `api/lib/api/notifications*`, `rls_smoke_test.exs`).

---

## 1. A varredura

### Segurança

| Item | Estado | Prova |
| --- | --- | --- |
| Bypass do BFF / ataque direto na API | **REFUTADO** | `curl` sem sessão nas 3 rotas novas → `401`, `401`, `401` |
| Tenant vindo do cliente | **REFUTADO** | `clinic_id` sai do `Api.Scope`; o `patient_id` sai do path. Teste de fronteira já existente |
| IDOR / BOLA entre clínicas | **REFUTADO** | RLS de baixo: com a GUC da clínica B, `SELECT` do anexo da A → **0 linhas**; `UPDATE`/`DELETE` cross-tenant → linha intacta (`laudo-sonda.pdf` sobreviveu) |
| Broken Function Level Authorization | **REFUTADO** | Policy única em `Attachment` (owner·admin·recepção) + `forbid_if always()` na escrita da trilha. Provado com o domínio chamado direto |
| Mass assignment (`accept [:id, :chave, :patient_id]`) | **REFUTADO** | `Api.Records` não está no AshJsonApi: `/api/json/attachments` → **404**. A ação só é alcançável pelo wrapper do domínio |
| **CORS / CSRF** | **CONFIRMADO** → C2 | ver §2 |
| Brute force / magic link / OAuth / sessão | NÃO SE APLICA | nenhuma superfície de auth no diff |
| Ataque de timing | NÃO SE APLICA | nenhuma comparação de segredo no diff (a assinatura é conferida pelo R2) |
| XSS | NÃO SE APLICA | `grep '{@html'` no diff do `web/` → vazio |
| SQL injection | **REFUTADO** | nome de tabela é literal de módulo (`@tabela_eventos`); parâmetros ligados |
| SSRF | **REFUTADO** | a URL do R2 é montada de config + chave derivada de ids; nenhuma URL vem da request |
| Open redirect | NÃO SE APLICA | `window.open` recebe URL da nossa API; `?paciente=` é id, não destino |
| Path traversal | **REFUTADO** | a chave nunca leva o nome do arquivo; o `filename` do disposition passa por `ascii/1` (aspas e barras saem) |
| Vazamento de `clinic_id` / da `chave` | **REFUTADO** | `attachment_json/1` não emite nenhum dos dois; teste fixa isso |
| Vazamento em log | **REFUTADO** | log de um download inteiro: `[info] GET /api/attachments/…/download`. Sem URL, sem assinatura, sem `X-Amz-*` |
| Secrets em código | **REFUTADO** | as 4 variáveis vêm de env em `runtime.exs`; as de `config/test.exs` são falsas e nomeadas como tal |
| Headers de segurança (CSP) | **REFUTADO** | `connect-src` ganha **host exato** (`https://<id>.r2.cloudflarestorage.com`), sem curinga, e some quando não há `R2_ACCOUNT_ID` |
| DoS / payload sem limite | **PARCIAL** → §5 | os bytes não passam pelo BFF; a cota (100/paciente) limita o bucket. **Sem rate limit no `presign`** |
| Dependência vulnerável | **CONFIRMADO, não é do diff** → §5 | `mix hex.audit`: `bandit 1.12.0` — CVE-2026-65623 (HIGH) |

### Performance

| Item | Estado | Prova |
| --- | --- | --- |
| N+1 | **REFUTADO** | uma abertura de ficha → **1** query em `attachments` |
| Seq scan | **REFUTADO** | os 4 planos novos, como `movimento_app`: `Index Scan Backward` (lista), `Index Only Scan` (cota), `Bitmap Index Scan` (poda), `Index Scan Backward` (trilha). Nenhum `Seq Scan` |
| Índice faltando em FK | **REFUTADO** | `on_delete_test.exs` exige índice em que a FK **lidere**; as 3 FKs novas passam |
| Índice redundante | **REFUTADO** | `[:patient_id]` não é prefixo de `[:clinic_id, :patient_id, :inserted_at]` — colunas líderes diferentes |
| Paginação ausente | **PARCIAL** → §5 | a lista da ficha é limitada pela cota (100); `list_clinic_attachment_events/2` não tem teto (não roteada) |
| **Aggregate caro em caminho compartilhado** | **CONFIRMADO** → C3 | ver §2 |
| **I/O externo dentro da transação** | **CONFIRMADO** → C4 | ver §2 |
| Crescimento sem poda | **REFUTADO** | `PruneAttachments` poda pendentes (24 h) e trilha (730 d) |

### Refatoração

| Item | Estado |
| --- | --- |
| **DRY — segunda fonte da verdade do teto** | **CONFIRMADO** → C5 |
| DRY — tripwire dos papéis só de um lado | **CONFIRMADO** → menor |
| `cond` fechando com `:else ->` (2×, ambas minhas) contra `true ->` (19× no projeto) | **CONFIRMADO** → menor |
| Adaptador de teste devolvendo chave fora do behaviour | **CONFIRMADO** → menor |
| Regra de negócio/authz fora de action/policy | **REFUTADO** — a guarda do controller é conveniência; a policy é a autoridade, e há teste chamando o domínio direto |
| Ash: code interface, actor no changeset, multitenancy pelo mecanismo | **REFUTADO** |

### O que a rodada 2 achou que a 1 não tinha achado

A checklist deu **1** achado de segurança e **2** de performance. O ângulo adversarial deu mais
**3**, e são os que mais mudaram código:

- **C1** — perguntar *"e se eu chamar duas vezes?"*: 5 POSTs de `confirm` no mesmo anexo →
  **5 linhas `:enviou`** e **10 idas ao R2**;
- **C4** — seguir o job em vez de ler o recurso: o `delete` no Cloudflare rodava dentro da
  transação da poda;
- **TOCTOU do PUT** — perguntar *"o que eu ganho se eu mentir aqui?"*: a URL de `PUT` continua
  valendo depois do `confirm` (§5).

Foi também a rodada 2 que descobriu que a proteção CSRF do SvelteKit vive dentro de um
`if (!DEV)` — o que transformou um susto ("um POST forjado arquivou um paciente de verdade") na
causa-raiz certa (C2), em vez de num alarme falso ou num achado inflado.

---

## 2. As causas-raiz, e o que foi corrigido

### C2 · Dois `POST` do BFF viajavam sem `content-type` — e escapavam das duas peneiras

**A sonda.** Um `POST` cross-origin com `origin: https://evil.example` no endpoint de anexo
respondeu **503**, não 403 — ou seja, o handler **executou**. O mesmo no `DELETE`: **502**, que é
o erro do storage — a remoção chegou a tentar apagar o arquivo. E no baseline pré-existente
(`?/deactivate`), **200** — com `ativo` indo a `f` no banco. (Paciente restaurado na hora.)

**A causa.** Duas brechas que se somam, ambas lidas no fonte instalado do
`@sveltejs/kit@2.69.2`:

```js
// runtime/server/respond.js
if (!DEV) {                                   // (1) a proteção não existe em desenvolvimento
  } else if (options.csrf_check_origin) {
    const forbidden = is_form_content_type(request) && ...   // (2) só content-type de FORMULÁRIO
```

```js
// utils/http.js
const type = request.headers.get('content-type')?.split(';', 1)[0].trim() ?? '';
```

Um `POST` **sem content-type nenhum** não é formulário (a expressão vira `''`) — e também é
*simple request* de CORS, então o browser nem pede preflight. Meus dois `fetch` (`confirm` e
`download-url`) eram exatamente assim. O `PATCH`/`DELETE` se salvavam por acidente da tabela de
CORS, não por regra.

**O conserto.** [`$lib/server/csrf.ts`](../web/src/lib/server/csrf.ts) — `exigirJson/1` nos três
mutadores. Quem quiser mandar `application/json` de outra origem é obrigado a preflightar, e o
preflight não é respondido com `Access-Control-Allow-Origin` (medido: `405`, sem o header).

**Vermelho:** 5 testes em
[`anexos/[anexoId]/server.test.ts`](../web/src/routes/(app)/pacientes/%5Bid%5D/anexos/%5BanexoId%5D/server.test.ts).
**Re-sonda:**

```
POST anexos, form cross-origin  : 415   (era 503 = handler rodou)
POST anexos, SEM content-type   : 415
DELETE anexo, SEM content-type  : 415   (era 502 = chegou no storage)
POST ?acao=download bare        : 415
POST anexos com JSON            : 503   (o caminho do app continua passando)
```

### C1 · `confirm` era um comando repetível, não uma transição de estado

**A sonda.** Teste-sonda com 5 POSTs de `confirm` no mesmo anexo já disponível:

```
PROBE eventos_enviou=5 (5 POSTs de confirm no MESMO anexo já disponível)
PROBE visualizou=20 apos 20 GETs        ← este está certo: é a trilha fazendo o trabalho dela
```

`:enviou` significa "este arquivo entrou", e isso acontece **uma** vez. Cada repetição também
gastava mais duas idas ao R2 (`HEAD` + `GET` de faixa) e **reabria a conferência** sobre bytes que
podem ter sido trocados — com poder de **descartar** um anexo já aprovado.

**O conserto.** `confirmar/2` devolve `{:ok, anexo}` sem efeito quando o anexo já está
`:disponivel`. Idempotente em vez de 422 porque a repetição legítima é a retentativa de rede.
**Re-sonda:** `Enum.count(eventos, & &1.acao == :enviou) == 1` — e um segundo teste prova que
trocar os bytes depois não faz o anexo válido ser descartado.

### C3 · `faltas` pendurado num lookup que seis chamadores usam

**A sonda.** O SQL que o Ash emite, capturado do log da app:

```sql
FROM "patients" AS p0 LEFT OUTER JOIN LATERAL (SELECT ... count(*) ... FROM "attendances" ...)
```

`EXPLAIN (ANALYZE, BUFFERS)` como `movimento_app`, na clínica com **10.185** attendances:
**67 buffers, 0,92 ms** por chamada (o índice certo é usado — `Index Cond` inclui `patient_id` —,
então escala com o paciente, não com a clínica). O problema não é o custo unitário: é **quem
paga**. `fetch_clinic_patient/2` é a porta da ficha, do histórico, dos anexos e das **três
escritas**; só a ficha lê o número. Uma abertura de ficha resolvia o paciente 3× e pagava o
`LATERAL` 3×; o `PATCH` pagava por um dado que a resposta descarta.

**O conserto.** `:load` virou **opt-in** (`fetch_clinic_patient/3`); só o `show/2` pede
`[:faltas]`. **Vermelho:** um teste que captura o *texto* das queries (contar linhas não
distingue — o `LATERAL` viaja dentro da query de `patients`). **Re-sonda ao vivo:**

```
SELECTs em patients          : 3
destes, COM o LATERAL faltas : 1     (antes: 3)
```

### C4 · O `delete` no Cloudflare rodava dentro da transação da poda

**A sonda.** `Api.Repo.with_clinic/2` é `transaction/1` (lido no fonte, e medido na app viva:
`FORA in_transaction? = false` / `DENTRO in_transaction? = true`). A varredura de pendentes
chamava `Api.Storage.delete/1` — request ao Cloudflare, `receive_timeout` de 15 s — de dentro
dela, uma vez por linha. Uma clínica com 20 uploads abandonados segurava **uma conexão do pool
por até 5 minutos**, e o sintoma disso aparece como latência de API, não como problema do job.

**O conserto.** Três fases: (1) lê as chaves sob transação; (2) apaga os objetos **fora** dela;
(3) volta à transação só para o `DELETE` das linhas. A ordem objeto-antes-de-linha é preservada.

**Re-sonda.** No sandbox, `Repo.in_transaction?/0` responde `true` sempre — então ele não serve
de prova, e isso está dito no teste. O que **distingue** as duas versões é a ordem das chamadas,
e é isso que o teste fixa: com dois anexos, a versão antiga intercalaria delete-de-linha entre os
dois deletes-de-objeto. `Api.Storage.Memory` ganhou uma linha do tempo (`chamadas/0`) para
sustentar a asserção.

### C5 · O teto de 50 MB tinha duas fontes da verdade

`"O arquivo passa do limite de 50 MB."` escrito à mão ao lado de `Conteudo.max_bytes/0`, que é a
autoridade. Não quebra nada — só passa a **mentir** no dia em que o teto mudar. Agora o número é
interpolado da constante.

### Menores

- **Tripwire dos papéis só de um lado.** `web/src/lib/attachments.ts` repete a lista de
  `Attachment.papeis/0` e nenhum compilador liga as duas linguagens (é o D-3 da paleta). O lado
  web tinha asserção; o Elixir não. Agora tem, e cada uma aponta para a irmã.
- **`cond` fechando com `:else ->`** — 2 ocorrências, ambas minhas, contra 19 `true ->` no
  projeto. Alinhadas.
- **`Api.Storage.Memory.presign_put/4` devolvia `bytes:`**, chave que o behaviour não tem. Um
  adaptador de teste com forma diferente do de produção ensina o chamador a depender do que não
  existe. Removida.

---

## 3. O achado da rodada 5 — dentro do próprio conserto

O conserto de **C1** nasceu como cláusula de `confirm_attachment/2` casando
`%Attachment{status: :disponivel}` — **antes** de `autorizar/3`. Isso fazia dele a única porta da
fatia a responder `{:ok, _}` a quem a policy recusa.

Não vaza nada (quem chama já tem o struct em mãos) e não tem efeito colateral, mas quebra a
uniformidade que o teste de defesa-em-profundidade afirma — e uniformidade é o que torna a regra
verificável. Movido para depois da autorização, com teste próprio: *"profissional não confirma —
nem um anexo já disponível"*.

É o motivo de a rodada 5 auditar o diff dos consertos: **código novo é código não-auditado**.

---

## 4. Estado das suítes

| | Antes do bate-volta | Depois |
| --- | --- | --- |
| Backend | 1158 testes, 90,8% | **1167 testes, 0 falhas, 90,8%** (gate: mín. 80) |
| Web | 1379 testes | **1391 testes, 0 falhas**, gate `exit 0`; `csrf.ts` 100% |
| `mix format --check-formatted` | — | limpo |
| `mix compile --warnings-as-errors` | — | limpo |
| `npm run check` | — | 0 erros, 0 avisos |

Fumaça ao vivo depois dos consertos: ficha renderiza, duas colunas, stat de faltas, contagem no
histórico, seção de anexos degradando sem credencial. Console sem erros.

---

## 5. O que ficou para você

> **Decidido em 2026-07-27:** os itens **5a**, **5c** e **5e** foram avaliados e ficam como estão,
> registrados como [`50 §D-7`, `§D-8` e `§D-9`](50-debitos-tecnicos.md) — com o gatilho de cada um
> escrito lá. O **5b** (bandit) é tarefa de bump, não decisão. O **5d** vira achado só no dia em que
> existir tela que leia a trilha de um anexo.

### 5a. TOCTOU: a URL de `PUT` continua valendo depois do `confirm`

**A sonda.** Depois de confirmar, reusei a mesma chave com outro conteúdo do mesmo tamanho:

```
PROBE apos confirm: status=disponivel, bytes conferidos
PROBE linha diz: application/pdf / disponivel
PROBE bytes no bucket agora: "<script>alert("
PROBE farejar(bytes atuais) = :error
```

**Por que não foi corrigido.** É inerente a upload por URL assinada: a assinatura vale pela
janela dela (10 min, escolhidos para um upload de 50 MB em conexão ruim). Encurtar é trocar
segurança por uploads que falham em clínica com internet ruim — **decisão de produto**, não de
código.

**O que limita hoje:** o atacante precisa ser membro **autorizado** trocando o **próprio**
arquivo, dentro de 10 min, por conteúdo de **exatamente o mesmo tamanho** (o `content-length` está
na assinatura). E o `response-content-type` da URL de leitura é pinado ao tipo **conferido**, então
HTML colocado ali é servido como `application/pdf` — não executa. O que sobra é integridade do
artefato, não XSS.

**Qual seria a correção:** TTL de `PUT` mais curto (ex.: 3 min) com retomada, ou reconferir os
magic bytes na emissão de cada download (+1 `GET` de faixa por abertura).

### 5b. `bandit 1.12.0` — CVE-2026-65623 (HIGH)

```
bandit 1.12.0 - EEF-CVE-2026-65623 (HIGH)
  Quadratic CPU blow-up reassembling fragmented WebSocket messages in Bandit
```

**Não é do meu diff** — apareceu porque a checklist manda rodar `mix hex.audit` quando o diff
toca `mix.exs`, e eu toquei (para somar `req`). Fica registrado: o projeto **usa** WebSocket
(o canal da agenda), então a superfície existe. **A correção é um bump de dependência**, com o
teste de regressão do canal — trabalho de infra, fora do alvo desta auditoria.

### 5c. Sem rate limit na emissão de URL assinada

`ApiWeb.Plugs.RateLimitAuth` só cobre o escopo de auth. `POST /patients/:id/attachments` é barato
para o servidor e caro para a conta do R2. **O que limita hoje:** a cota de 100 anexos por
paciente (contando os `:pendente`, justamente para o abuso não passar por aí). **Não corrigido**
porque o teto já é estrutural — o rate limit reduziria a *velocidade*, não o *máximo*. Já estava
declarado aberto em [`51 §5`](51-ficha-anexos-e-storage.md).

### 5d. `list_clinic_attachment_events/2` sem teto

Função pública de domínio que devolve **todos** os eventos de um anexo, e a trilha cresce a cada
visualização. **Não corrigido** porque não há rota que a exponha — só testes a chamam. **Vira
achado de verdade no dia em que a tela de auditoria de anexo existir**; aí ela nasce paginada,
como a trilha de agendamentos (doc 25 §11.4).

### 5e. Uma chamada a mais na ficha para quem não pode vê-la

O `load` da ficha dispara os 6 fetches em paralelo, e o de anexos vai **mesmo para o
`profissional`**, que recebe 403. Medido: cada chamada à API custa ~4 queries de resolução de
sessão (`tokens`/`memberships`/`clinics`/`users`) + 1 de paciente.

**Não corrigido** porque a alternativa — `await event.parent()` para conhecer o papel antes — põe
o load em série e custa um round-trip a **todos** os papéis, para poupar um a **um**. É o mesmo
trade-off que o load da agenda já documenta. **Qual seria a correção**, se incomodar: o layout
expor o papel num lugar que o `load` da página alcance sem esperar o pai.

---

## Referências

- [`51`](51-ficha-anexos-e-storage.md) — a fatia auditada
- [`50 §D-6`](50-debitos-tecnicos.md) — o antivírus, débito declarado antes desta auditoria
- [`06 §7`](06-seguranca-e-lgpd.md) — os seis requisitos de anexo
- [`43`](43-bate-volta-onda-3.md), [`49`](49-bate-volta-onda-6.md) — bate-voltas anteriores
