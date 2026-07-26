# 47 — Bate-volta: a Onda 5 (endurecimento de produção)

Auditoria do que a sessão de 2026-07-26 construiu **depois** da Onda 4: os commits `7fdcdec`
(Frente 11), `1559708` (docs 46/17/35) e `aec7ba4` (remoção de `appointments.package_id`). A
Onda 4 ficou **fora do alvo** — já auditada no [doc 45](45-bate-volta-onda-4.md).

**Onde parou:** foi até a rodada 5. A rodada 1 fechou com achados, a rodada 2 confirmou os
REFUTADO fracos por sonda e não acrescentou achado novo (bom sinal: a cobertura da 1 valeu), a
rodada 3 deu conta da fila inteira (a 4 não foi necessária), e a rodada 5 re-sondou tudo e ainda
perguntou se o próprio conserto criou índice redundante.

**Verde ao fim:** API **1019 testes + 17 doctests / 0 falhas**, gate `:rls` **20/0** como
`movimento_app`, web **1291 testes / 0 falhas** em 137 arquivos (**91,6% stmts**),
`svelte-check` limpo, `mix format --check-formatted` limpo. Imagem de **produção** construída e
servida para conferir os headers de verdade.

---

## 1. A varredura

Nenhum achado entrou sem output de sonda. Os `REFUTADO` abaixo foram refutados **medindo**.

### Segurança — zero confirmados

| Item | Estado | Sonda |
| --- | --- | --- |
| Fronteira da API sem BFF | **REFUTADO** | `curl` direto na :4010 → `/api/auth/me` **401**, `/api/realtime/token` **401** |
| Tenant vindo do cliente (WS) | **REFUTADO** | `clinic_id` sai do token assinado, nunca de params; `Parameters: %{"vsn" => "2.0.0"}` no log da conexão |
| IDOR / BOLA pela relação nova (`Attendance.package`) | **REFUTADO** | `psql -U movimento_app`: com a GUC de outra clínica, `packages` → **0 linhas** e a junção `attendances⋈packages` → **0**; com a GUC da dona, **1** e **4** |
| Pacote de outra clínica carimbado na presença | **REFUTADO** | `PackageBelongsToPatient` recusa; `participant_package_test.exs:130` ("pacote de outra clínica é recusado") verde depois da mudança |
| Function-level authz | **NÃO SE APLICA** | Nenhuma action nova no diff — `belongs_to` não cria action |
| Mass assignment | **REFUTADO** | `accept [:package_id]` é o mesmo de antes; a FK **acrescenta** integridade, não superfície |
| Isolamento do canal (tópico de outra clínica) | **REFUTADO** | `test/api_web/channels/` **47 testes / 0 falhas**, incluindo "tópico de OUTRA clínica é recusado" |
| Vazamento do token do WS em log | **REFUTADO** | Fragmento do token buscado em `docker compose logs api` após um handshake 101 → **0 ocorrências** |
| Porta antiga do WS (query string) | **REFUTADO** | Token cru em `?token=` → **403**; subprotocolo adulterado → **403**; sem token → **403**; subprotocolo válido → **101** |
| `GOOGLE_REDIRECT_URI` do doc 17 | **REFUTADO** (a correção está certa) | `curl` em `/api/auth/strategy/user/google` → `redirect_uri=http://localhost:5173/auth/user/google/callback`: a base é do **web**, e a estratégia completa o caminho |
| Headers de segurança | **REFUTADO** | Imagem de produção rodando: `strict-transport-security: max-age=63072000; includeSubDomains`, `content-security-policy` com `connect-src` **sem** `localhost`, `x-frame-options: DENY`, `nosniff` |
| Segredos em código | **REFUTADO** | Grep no diff por `secret|password|api_key|token` com literal ≥8 chars → nada além dos salts já existentes e do smoke local |
| Dependência vulnerável | **NÃO SE APLICA** | `mix.exs`/`mix.lock`/`package.json` intocados no diff |
| XSS / SQLi / SSRF / open redirect / path traversal | **NÃO SE APLICA** | Sem render novo, sem `fetch` de URL da request, sem parâmetro de destino. O único SQL cru novo é o `pg_constraint` do teste — literal de módulo, sem interpolação |
| Brute force / magic link / OAuth / sessão / timing | **NÃO SE APLICA** | Nenhum caminho de credencial no diff (o doc 17 mudou texto, não código) |

### Performance

| Item | Estado | Sonda |
| --- | --- | --- |
| FK sem índice que sirva à checagem do `DELETE` | **CONFIRMADO** → causa A | `EXPLAIN` abaixo |
| Índice redundante criado pelo conserto | **REFUTADO** (rodada 5) | O composto segue sendo o escolhido pela forma da app (3 buffers) e tem `idx_scan` 4; o novo tem 88 kB e serve outra forma |
| Custo do `ADD CONSTRAINT` no deploy | **REFUTADO** | `DROP`+`ADD` da FK de `appointments` (10.208 linhas não-nulas) medido em **8,095 ms**; a migration inteira em `0.0s` |
| N+1 / `SELECT *` / paginação ausente / pool / poda | **NÃO SE APLICA** | Sem read novo, sem loop novo, sem trabalho concorrente novo |
| Waterfall no BFF | **NÃO SE APLICA** | `hooks.server.ts` só seta headers; nenhum `fetch` acrescentado |

### Refatoração

| Item | Estado | Sonda |
| --- | --- | --- |
| Segunda fonte da mesma verdade (`http→ws`) | **CONFIRMADO** → causa B | `grep -n "replace(/^http/"` → duas ocorrências, `csp.js:28` e `realtime.ts:72`, cada uma com comentário mandando concordar com a outra |
| Comentário que contradiz o código | **CONFIRMADO** → causa C | Duas: o racional do HSTS (ver causa C) e o docstring do `connectAgenda`, que ainda dizia "o `params` é uma função" depois de o token sair dos params |
| Regras de Elixir/Ash no diff | **REFUTADO** | `connect/3` casa na cabeça com guard; `reference`/`belongs_to` idiomáticos; nenhum `String.to_atom`, `case` aninhado, macro ou process dictionary |
| Tipagem do web | **REFUTADO** | `svelte-check` 0 erros; sem `any`. O único cast (`authToken`) tem justificativa escrita: `@types/phoenix` 1.6.7 está atrás do runtime 1.8 |
| Docs locais (CLAUDE.md) | **REFUTADO** | Todo entregável é `.md` no repo; nenhum Artifact |

**O que a rodada 2 acrescentou:** nenhum achado novo — mas fechou por sonda quatro hipóteses que
a rodada 1 tinha deixado como "provavelmente ok": a trilha não ficou órfã pela coluna removida
(**0** de 119 versões com `package_id` em `changes`), ator nulo na auditoria já é estado corrente
(**38** de 119 versões já têm `user_id` nulo, e a tela convive com isso desde que existe), a
`Attendance` **não** está exposta na AshJsonApi (rotas do domínio: `[]`, então a relação nova não
vira `?include=`), e a reconexão do socket sobrevive à troca de token — derrubando a API com a
aba aberta, o log mostra **4 `CONNECTED TO ApiWeb.UserSocket`** novos com rejoin dos dois
tópicos.

---

## 2. As causas-raiz

Cinco achados, três causas.

**Causa A — FK cuja checagem de `DELETE` não tem índice que sirva.** O Postgres emite
`WHERE <coluna_fk> = $1` no filho, **sem `clinic_id`** (ele não tem noção de tenant). Índice
`(clinic_id, coluna)` não serve a essa forma. Cobre dois achados, e a H64 os acendeu ao trocar
`NO ACTION` por `SET NULL`: o que antes era "o `DELETE` é recusado" virou "o `DELETE` **escreve**
em toda linha correspondente".

**Causa B — a regra `http→ws` escrita duas vezes.** `connectSrc` (CSP) e `socketUrl` (cliente do
socket). É a duplicação que dói: divergir faz o browser bloquear a conexão por um header que só
acusa no console.

**Causa C — o texto prometia mais do que o código garante.** O comentário do HSTS afirmava que a
condição de protocolo evitava "HSTS de mentira num deploy http acidental"; a sonda mostrou o
contrário.

---

## 3. O que foi corrigido

### A — os três índices de FK

**A sonda que encontrou** (antes):

```
attendances.package_id       Index Only Scan (índice composto inteiro)  cost 197   13 buffers
appointments_versions.user_id  Seq Scan                                  cost 15    13 buffers
attendances_versions.user_id   Seq Scan                                  cost 13     8 buffers
```

As duas tabelas de versão **não tinham índice nenhum** com a coluna — e a trilha é a tabela que
mais cresce do sistema (3× a base, [doc 43](43-bate-volta-onda-3.md) §5f), a ponto de ter poda
própria.

**O teste vermelho:** `test/api/on_delete_test.exs` ganhou um segundo contrato — *toda FK tem
índice liderando pela coluna*. Ele falhou nomeando exatamente as três:

```
FK sem índice liderando (o DELETE do pai varre o filho):
  [{"appointments_versions", "user_id"}, {"attendances", "package_id"},
   {"attendances_versions", "user_id"}]
```

O teste carrega uma lista de **quatro exceções conhecidas**, anteriores a esta onda
(`attendances.appointment_id`, `attendances.patient_id`, `packages.patient_id`,
`package_schedules.package_id`) — dívida declarada, não permissão; ver §4.

**O conserto:** `index [:package_id], all_tenants?: true` no recurso (sem `all_tenants?` o
ADR-017 prefixaria `clinic_id` e o índice não serviria), e os dois da trilha por SQL na mão, pelo
mesmo precedente dos `*_clinic_time_idx` — recursos `*.Version` são gerados e não têm
`custom_indexes` para declarar. **`CONCURRENTLY` nos três**
([regra do projeto](../.claude/rules/migrations.md)): estas migrations rodam no `release_command`
do deploy, e `CREATE INDEX` comum fila todo `INSERT`/`UPDATE` enquanto constrói.

**A re-sonda (rodada 5):**

```
attendances.package_id        Index Only Scan using attendances_package_id_index         cost 5    2 buffers
appointments_versions.user_id Index Only Scan using appointments_versions_user_id_index  cost 8    1 buffer
attendances_versions.user_id  Index Only Scan using attendances_versions_user_id_index   cost 8    1 buffer
```

E a pergunta que a rodada 5 obriga — *o conserto regrediu algo?* O índice novo **não** tornou o
composto redundante: a forma da aplicação (`clinic_id` **e** `package_id`) continua escolhendo
`attendances_clinic_id_package_id_index` (3 buffers, `idx_scan` 4). O preço é 88 kB e uma
estrutura a mais para manter numa tabela quente — o mesmo trade que o projeto já aceitou em
`appointments.created_by_id` (doc 26, achado (h)).

### B — uma fonte só para a regra de esquema

`wsOrigin/1` nasceu em `csp.js` (o módulo que o `svelte.config.js` consegue importar, por ser
`.js` puro) e `socketUrl` passou a usá-lo. O teste que fixa isso não é o da função — é o do
**acordo**: "a URL do socket e o `connect-src` da CSP apontam para a MESMA origem".

**Provado por mutação:** re-inlinando em `socketUrl` uma regra que só troca `https→wss`, o teste
do acordo fica vermelho; restaurando, verde (9/9). E o `import` de `.js` a partir de `.ts`
sobrevive ao **build de produção** — a imagem foi reconstruída e serve a CSP correta.

### C — o texto corrigido, e o que de fato garante

**A sonda:** rodando a imagem de produção **sem `ORIGIN`**, o `adapter-node` assume `https` e o
header sai **sobre http puro** (`grep -c strict-transport` → 1). Com `ORIGIN=http://...`, não sai
(0). Com `ORIGIN=https://...`, sai (1).

Ou seja: quem decide não é o fio, é o `ORIGIN` — que o `web/fly.toml` seta. Isso é inofensivo
para o browser (RFC 6797 §8.1 manda ignorar HSTS fora de HTTPS), mas o comentário afirmava uma
garantia que não existe. Comentário e teste agora dizem a verdade, e o teste novo fixa o cenário
real (request interno http, `ORIGIN` https, header presente). O docstring do `connectAgenda`, que
ainda falava em `params`, foi corrigido junto.

---

## 4. O que fica para decisão humana

### D1 — quatro FKs anteriores sem índice liderando

**O que é:** `attendances.appointment_id`, `attendances.patient_id`, `packages.patient_id` e
`package_schedules.package_id`. Todas têm um índice composto que **contém** a coluna sem que ela
lidere, então o plano é varredura de índice — não seq scan, e não o caso das versões.

**A sonda:** a consulta cruzando `pg_constraint` com `pg_index` (a mesma do teste novo) devolve
7 FKs sem índice liderando; 3 eram do alvo e foram corrigidas, estas 4 não são.

**Por que não foi corrigido:** estão **fora do alvo** — nenhuma nasceu ou mudou nesta onda, e
auditoria que escorrega para o código vizinho não termina. Estão na lista de exceções do teste,
com nome, o que significa que sair da lista é trabalho declarado e entrar nela sem querer é
impossível.

**Qual seria a correção:** `index [:coluna], all_tenants?: true` em cada recurso, com migration
`CONCURRENTLY`. Candidato natural à Frente 13 (refactors/limpeza).

### D2 — `API_PUBLIC_ORIGIN` build-time × runtime, sem guarda

**O que é:** um risco que **este diff introduziu**. A CSP é fixada no build (`kit.csp`), então a
origem entra por `[build.args]`; a mesma variável existe em `[env]` para o runtime montar a URL
do socket. Nada verifica que as duas batem. Divergir bloqueia o WebSocket **em silêncio** — o
erro só aparece no console do browser.

**A sonda:** o teste `sem origem definida usa o default de desenvolvimento` mostra o
comportamento: sem o `ARG`, o build sai com `localhost:4010` no `connect-src` de produção.

**Por que não foi corrigido:** a guarda em código exige comparar o valor **assado** com o de
runtime, o que pede `$env/static/private` — que falha o build quando a variável não existe e
quebraria `npm run dev`. É decisão de arquitetura (como o projeto quer tratar config
build-time), não conserto de bug, e a skill manda não abrir isso no meio de uma rodada.

**Mitigação já no lugar:** o [doc 17](17-deploy-fly.md) ganhou o passo de verificação explícito —
conferir que o `connect-src` traz o par do host real e **não** `localhost` —, que roda no momento
exato em que o erro seria introduzido.

### D3 — o teste de FK vigia tabelas que o projeto não escreve

**O que é:** o contrato novo varre **todas** as FKs do schema `public`. Se uma dependência (Oban,
por exemplo) criar tabela com FK, o teste falha pedindo decisão sobre algo que não é do projeto.

**A sonda:** hoje `oban_jobs` não tem FK — as 33 FKs do schema são todas de recursos do projeto,
então não há falso positivo agora.

**Por que não foi corrigido:** filtrar por lista de tabelas próprias enfraqueceria justamente o
que o teste existe para pegar (FK nova sem decisão). Preferi o falso positivo raro e barulhento
ao falso negativo silencioso — mas é escolha, e fica registrada.
