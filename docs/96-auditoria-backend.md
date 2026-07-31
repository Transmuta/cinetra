# 96 — Auditoria do backend: riscos, refatoração, reúso e código morto

**Data:** 2026-07-30 · **Escopo:** `api/lib/api/` (domínios Ash), `api/lib/api_web/` (HTTP/WS) e
`api/config/`. Duas varreduras independentes e paralelas — uma pelo eixo de domínio/OTP, outra pelo
eixo de borda HTTP —, consolidadas aqui com as sobreposições fundidas.

**Nada foi corrigido.** Este documento é o levantamento. Pela regra do
[CLAUDE.md](../CLAUDE.md#bug-encontrado--teste-de-regressão-sempre), **cada bug daqui vira primeiro
um teste vermelho**, depois o conserto. Os achados marcados "reproduzido" já vêm com o roteiro.

## Estado dos gates no momento da auditoria

| Gate | Resultado |
| --- | --- |
| `mix compile --force --warnings-as-errors` | ✅ exit 0 |
| `mix format --check-formatted` | ✅ exit 0 |
| `mix test` | ✅ 18 doctests, 1704 testes, 0 falhas (135,9 s) |
| `mix test --only rls` (como `cinetra_app`) | ✅ 0 falhas |

Tudo verde. **Nenhum dos 47 achados abaixo é pego por gate nenhum** — é exatamente esse o ponto do
levantamento.

Tamanho: 28.590 linhas em `lib/` (22.609 de domínio, 5.806 de web) contra 29.722 de teste.

---

## Sumário por severidade

| | Segurança | Tenancy | Bugs | HTTP | Perf | Ash | Reúso | Morto | Estrutura | Config/Obs | **Total** |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **ALTA** | 3 | 2 | 7 | — | 1 | — | — | — | — | — | **13** |
| **MÉDIA** | 4 | 1 | 4 | 5 | 5 | 5 | 3 | 2 | 3 | 4 | **36** |
| **BAIXA** | 3 | — | 2 | 6 | 2 | — | 1 | 1 | 1 | 2 | **18** |

Três achados foram **provados em execução** (saída colada nas seções): B-1, T-0 e T-1. Dois estão
marcados **não confirmado** e dizem por quê.

---

## Ordem de ataque sugerida

1. **S-1** — dado bancário e CPF de profissional expostos a qualquer membro. É vazamento de dado
   pessoal em produção, hoje, e a correção é conhecida (o padrão já existe no repo).
2. **B-1** e **B-2** — a sessão paga que some do pacote (reproduzida) e o nome que nunca aparece nas
   notificações. Uma custa dinheiro do paciente, a outra é conserto de uma linha.
3. **B-3 / B-4 / B-8** — reenvio de WhatsApp pago, mensagem que trava a fila para sempre, e a
   corrida que gera mensagem duplicada. Os três atingem dinheiro; os três são pequenos.
4. **S-2 / S-3** — token de paciente no log (30 dias de retenção) e credencial exportada no trace.
5. **T-1 / T-0** — a GUC que falta em `Sessions.segura/3`, e o modelo de falha do RLS descrito
   errado em cinco lugares da documentação.
6. **B-5 / B-7** — a trilha de auditoria que promete fail-closed e é fail-open, e a dedup
   anti-abuso que amplifica o abuso.
7. **P-1 / P-2** — os dois pontos onde a fila de espera não escala.

---

# 1. Segurança e privacidade

## S-1 · ALTA — CPF, RG, banco, agência, conta e PIX de todo profissional vão para qualquer membro

**Local:** [`professionals_controller.ex:163-209`](../api/lib/api_web/controllers/professionals_controller.ex#L163)
· [`professional.ex:150-153`](../api/lib/api/directory/professional.ex#L150)

Três peças alinhadas, todas verificadas:

- a rota usa `with_member_scope` — **qualquer papel** passa;
- a policy do recurso é `authorize_if {HasClinicRole, roles: :any}` para `action_type(:read)`;
- **não existe `field_policies`** no recurso;
- `prof_json/2` serializa a ficha inteira: `cpf`, `rg`, `razao_social`, `cnpj`, `banco`, `agencia`,
  `conta`, `conta_tipo`, `pix`, além de endereço completo e contato de emergência.

Um usuário de papel `recepcao` ou `profissional` que abra a tela de Profissionais recebe a **chave
PIX e a conta bancária de todos os colegas**. O `AccessMatrix`
([`access_matrix.ex:98-101`](../api/lib/api/accounts/access_matrix.ex#L98)) de fato concede
`profissional: :leitura, recepcao: :leitura` nessa área — mas "ler o diretório" e "ler os dados
bancários" foram colapsados numa permissão só, e a matriz publicada ao usuário não avisa isso.

Que é regressão e não decisão, o próprio repositório atesta: a mesma leitura é deliberadamente
restringida em [`members_controller.ex:34`](../api/lib/api_web/controllers/members_controller.ex#L34)
— `query: [select: [:id, :nome]]`, com o comentário *"as 38 colunas da ficha eram carregadas e
descartadas"*.

**Correção:** `field_policies` no recurso para o bloco contratual/bancário (`owner`/`admin`) e, na
fronteira, dois serializadores — ficha completa para quem administra, versão de diretório (nome,
exibição, crefito, cor, ativo, contato) para os demais.

**Teste primeiro:** um teste de controller que autentica como `recepcao`, chama
`GET /api/professionals` e afirma que `pix`/`conta`/`cpf` **não** estão no corpo. Ele fica vermelho
hoje.

---

## S-2 · ALTA — O token de resposta do paciente vai verbatim para o log

**Local:** [`request_logger.ex:116-123`](../api/lib/api_web/request_logger.ex#L116) ×
[`router.ex:300-301`](../api/lib/api_web/router.ex#L300)

`RequestLogger.rota/1` existe para tirar identificador do path — o moduledoc (linhas 20-23) diz que
é *"a barreira que impede `patient_id` de sair do processo"*. `identificador?/1` reconhece **UUID e
número**. O token de `/api/reply/:token` é um `Phoenix.Token` base64: não casa com nenhum dos três
regexes e passa inteiro.

**Provado ao vivo:**

```
$ curl -s -o /dev/null "http://localhost:4010/api/reply/SFMyNTY.g2gDdAAAAAFkAAptZXNzYWdlX2lkbQAAACQwMTk4..."
$ docker compose logs api --since 30s
requisição request_id=GMc4nm9oEGUGFLcAAFDB trace_id=93f8092ad6b5782f4262cc2c1a5b3243
  method=GET route=/api/reply/SFMyNTY.g2gDdAAAAAFkAAptZXNzYWdlX2lkbQAAACQwMTk4LWZha2UtdG9rZW4... status=404
```

O token vale **30 dias** ([`reply_token.ex:28`](../api/lib/api/messaging/reply_token.ex#L28)) e em
produção essa linha vai para o Loki com 30 dias de retenção (doc 62). Quem tiver acesso ao Grafana
pode replayar `POST /api/reply/<token>` e **responder pelo paciente** (`confirmou`,
`quer_remarcar`), o que ainda dispara notificação para a recepção
([`patient_reply_controller.ex:105-112`](../api/lib/api_web/controllers/patient_reply_controller.ex#L105)).
É credencial em log — exatamente a classe que o módulo foi escrito para evitar.

**Correção:** sanitizar por posição (o segmento após `reply` vira `:token`), ou tratar como opaco
todo segmento acima de ~40 caracteres. Teste de regressão em `rota("/api/reply/SFMy...")`.

---

## S-3 · ALTA (condicional) — Com trace ligado, o token do magic link e o `patient_id` vão para o Tempo

**Local:** [`tracing.ex:46-47`](../api/lib/api/tracing.ex#L46) ·
[`alloy.alloy:258-275`](../deploy/observability/alloy.alloy#L258)

`OpentelemetryBandit.setup()` grava, em todo span de servidor, `url.path` **e** `url.query`
(`deps/opentelemetry_bandit/lib/opentelemetry_bandit.ex:231,327-328`). Nas rotas deste projeto:

- `GET /api/auth/magic-link/callback?token=…` → **o token que assina a sessão** vira `url.query`;
- `GET /api/patients/<uuid>` → `patient_id` cru em `url.path` — o que o `RequestLogger` sanitiza no
  log e ninguém sanitiza aqui;
- `GET /api/reply/<token>` → o token do S-2, de novo.

O processador que removeria isso está escrito no Alloy **mas comentado de propósito**
(`alloy.alloy:267-269`), e o comentário logo acima admite o problema: *"os atributos PADRÃO das
bibliotecas — que incluem `url.path` com o UUID na rota"*.

**Ressalva honesta:** `OTEL_EXPORTER_OTLP_ENDPOINT` tem default vazio
(`compose.dokploy.yml:208`), então hoje o exportador é `:none` e nada sai. **O risco é de uma
variável de ambiente** — e a documentação do projeto incentiva ligá-la.

**Correção:** descomentar a poda de `url.path` **antes** de ligar o OTLP, e acrescentar
`delete_key(attributes, "url.query")` — que não está nem no exemplo comentado, e é o pior dos dois
(o path carrega identificador; a query carrega credencial).

---

## S-4 · MÉDIA — O pipeline `:authenticated` não autentica

**Local:** [`router.ex:11-18`](../api/lib/api_web/router.ex#L11)

Nenhum dos quatro plugs `halt`a por falta de sessão: `load_from_session` não exige usuário;
`VerifyTokenSubject.call/2` tem cláusula de passagem sem `current_user`
([`verify_token_subject.ex:35`](../api/lib/api_web/plugs/verify_token_subject.ex#L35)); `LoadScope`
faz `assign(conn, :scope, nil)` ([`load_scope.ex:32-33`](../api/lib/api_web/plugs/load_scope.ex#L32)).
**Todo 401 do sistema vem da guarda do controller**, não do pipeline.

Isso só é seguro enquanto toda rota do escopo tiver guarda — e já existe uma que não tem: o
`forward "/", ApiWeb.AshJsonApiRouter` mais o Swagger UI.

**Provado ao vivo, sem cookie nenhum:**

```
$ curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4010/api/json/swaggerui
200
$ curl -s http://localhost:4010/api/json/open_api | head -c 60
{ "components": { "responses": { "errors": { ...
```

**O impacto hoje é baixo** — `Api.Meta` está vazio e o Traefik só roteia `/socket` e `/webhooks`
para a API (`compose.dokploy.yml:11-14`). O risco é o **próximo** recurso adicionado ao `Api.Meta`:
ele nasce roteado e anônimo, dependendo só da própria policy. O moduledoc de `Api.Meta` já registra
a lição da auditoria doc 13 (o recurso `Ping` publicava escrita anônima) — a plumbing que causou
aquilo continua de pé.

**Correção:** plug `RequireScope` que 401 quando `conn.assigns[:scope]` é nil. Redundante em 100%
das rotas atuais — e é por isso que é barato.

---

## S-5 · MÉDIA — `memberships` é a única tabela por-tenant sem RLS

**Local:** verificado no banco

```sql
select relname, relrowsecurity from pg_class ...;
-- 17 tabelas com t: appointments, patients, professionals, messages, audit_events, ...
-- memberships | f
-- clinics     | f
```

A tabela que decide **quem tem acesso a quê** não tem o backstop que toda tabela de dado tem.
`MembersController.update/2` e `delete/2`
([`members_controller.ex:64-91`](../api/lib/api_web/controllers/members_controller.ex#L64)) chamam
`Accounts.get_membership`/`update_membership` **sem** `in_clinic` e **sem** verificar
`membership.clinic_id == scope.clinic_id`. A fronteira de tenant ali é 100% a expressão da policy
([`membership.ex:150-157`](../api/lib/api/accounts/membership.ex#L150)) — correta hoje, mas é uma
camada, não duas, contra a norma do resto do projeto (ADR-018,
[`migrations.md` §3](../.claude/rules/migrations.md)).

Efeito observável: um `owner` de A que tente `PATCH /members/<id de B, onde ele é membro>` recebe
**403** (a read passa, o update recusa), enquanto um id da clínica C responde **404** — o par
distingue "existe numa clínica que você conhece" de "não existe". Vazamento marginal, mas é o
sintoma da camada faltando.

**Correção:** RLS em `memberships` com a política das demais; ou — se a leitura cross-clinic for
necessária para o `/me` (é: `list_active_memberships` roda sem tenant) — documentar a exceção em
[`00-decisoes.md`](00-decisoes.md) e acrescentar a checagem explícita de `clinic_id` no controller.

---

## S-6 · MÉDIA — `handle_in("offering")` aceita chave arbitrária, amplifica broadcast e derruba o canal

**Local:** [`waitlist_channel.ex:72-80`](../api/lib/api_web/channels/waitlist_channel.ex#L72)

```elixir
def handle_in("offering", %{"entry_id" => entry_id}, socket) when is_binary(entry_id) do
  {:ok, _ref} = ApiWeb.Presence.track(socket, entry_id, %{user_id: ..., nome: ...})
```

Dois defeitos no mesmo ponto:

1. **Amplificação.** O único guard é `is_binary/1` — não valida UUID, não checa que a entrada é
   desta clínica, não tem teto por socket. Cada `track` gera um `presence_diff` **transmitido a
   todos os assinantes de `waitlist:<clinic_id>`**: 1 mensagem do atacante → N mensagens por membro
   conectado, e o mapa de presença cresce sem limite na memória do nó, replicando por PubSub.
2. **Crash.** `Phoenix.Tracker.track/5` devolve `{:error, {:already_tracked, …}}` quando o mesmo pid
   já rastreia aquele `topic`+`key`. Dois `offering` com o mesmo `entry_id` sem `stopped_offering`
   entre eles → `MatchError` → o processo do canal morre. Isso contradiz o comentário quatro linhas
   abaixo (`:88`): *"Mensagem desconhecida (ou malformada) não derruba o canal"* — a bem-formada e
   repetida derruba.

O moduledoc acertou a metade difícil (o **nome** vem do servidor, não do corpo, `:47`) e deixou
passar a fácil (a **chave** vem do corpo sem validação).

**Correção:** `Ecto.UUID.cast/1` + conferir que a entrada é da clínica do socket; casar o retorno do
`track` em vez do match rígido; teto de chaves por socket.

---

## S-7 · MÉDIA — Replay de webhook Zernio pode ressilenciar um paciente

**Local:** [`zernio_signature.ex:47-59`](../api/lib/api/messaging/zernio_signature.ex#L47)

Usa `Plug.Crypto.secure_compare/2` e é fail-closed sem segredo — correto. Mas **não cobre
timestamp**, ao contrário da Svix ([`svix.ex:38-50`](../api/lib/api/messaging/svix.ex#L38), que
valida timestamp antes do HMAC com tolerância de 300 s). O moduledoc (`:19-25`) argumenta que replay
é inócuo, e isso tem um furo: `Api.Messaging.revoke_opt_out/3` existe e reverte um opt-out, então um
`message.received` com "SAIR" capturado e reentregue **depois** da revogação silencia o paciente de
novo. A condição que o próprio moduledoc põe como gatilho para a tabela de eventos vistos já está
satisfeita.

---

## S-8 · BAIXA — Cookie de sessão sem `Secure`, emitido até em 401

**Local:** [`endpoint.ex:8-14`](../api/lib/api_web/endpoint.ex#L8)

```
$ curl -s -D - -o /dev/null http://localhost:4010/api/patients
HTTP/1.1 401 Unauthorized
set-cookie: _api_key=XCP.U0N-LcaRcOLp81I5y3CQ...; path=/; HttpOnly; SameSite=Lax
```

Faltam `secure: true` e `max_age`. O impacto prático é contido (o browser só toca a API em
`/socket`, e o BFF reemite no domínio dele com `Secure`), mas a ausência não está registrada como
decisão — está ausente por omissão do gerador. E o `set-cookie` num **401** é o que o BFF já teve de
contornar (`web/src/lib/server/api.ts:67-71`: *"a API seta `_api_key` (sessão VAZIA) mesmo quando
REJEITA o login"*); um `configure_session(conn, drop: true)` na guarda de 401 eliminaria o
contorno.

## S-9 · BAIXA — Nenhuma resposta com dado de paciente carrega `Cache-Control: no-store`

Grep por `put_resp_header("cache-control"` em `lib/api_web/` volta vazio (exceto o `retry-after` de
`rate_limit.ex:39`). O que sai é o default do `Plug.Session`:
`max-age=0, private, must-revalidate` — que **permite armazenamento**. Para
`GET /api/patients/:id` (ficha completa) e `GET /api/attachments/:id/download` (URL assinada de
laudo), o correto é `no-store`.

## S-10 · BAIXA — O alerta de segurança mais crítico do sistema é inacionável

**Local:** [`verify_token_subject.ex:47-50`](../api/lib/api_web/plugs/verify_token_subject.ex#L47)

```elixir
Logger.warning("Sessão rejeitada: jti↔sub não confere (possível forja de token com secret vazada).")
```

Sem `jti`, sem `sub`, sem IP, sem user-agent. E este plug roda **antes** do `LoadScope`, então o
`Logger.metadata` de `clinic_id`/`actor_id` ainda não foi carimbado — a linha sai só com
`request_id` e `trace_id`. Se este alerta disparar em produção, é o pior momento possível para
descobrir que ele não diz de quem se trata.

---

# 2. Multi-tenancy e RLS

## T-0 · ALTA — O modelo de falha do RLS está documentado errado em cinco lugares

**Provado**, em duas metades:

```
-- psql, mesma conexão
begin; select set_config('cinetra.clinic_id','<uuid>',true); ... commit;
select coalesce(current_setting('cinetra.clinic_id', true),'<null>');  →  ''   (não NULL)
select count(*) from appointments;  →  ERROR: invalid input syntax for type uuid: ""
```

```
# mix test --only rls, como cinetra_app
role e GUC antes da leitura: [["cinetra_app", ""]]
get_appointment! SEM in_clinic, com tenant::
  {:raised, "** (Postgrex.Error) ERROR 22P02 (invalid_text_representation)
             invalid input syntax for type uuid: \"\""}
```

Duas consequências:

1. **`Api.Repo.on_transaction_begin/1` não cobre leitura solta.** O Ash não abre transação para
   `read` (nenhuma ação declara `transaction? true`), então a GUC automática nunca dispara. A regra
   do projeto ("todo `read` por-tenant dentro de `in_clinic`") continua certa — mas o `@doc` de
   [`repo.ex:44-52`](../api/lib/api/repo.ex#L44) sugere um alcance que não existe na prática.

2. **15 das 17 tabelas com RLS falham levantando, não devolvendo 0 linhas.** Só `messages` e
   `message_opt_outs` usam `NULLIF(current_setting(...),'')` (conferido em `pg_policies`). Mas
   [CLAUDE.md](../CLAUDE.md), [`migrations.md` §3](../.claude/rules/migrations.md),
   [`repo.ex:70`](../api/lib/api/repo.ex#L70), [`tenancy.ex`](../api/lib/api/tenancy.ex),
   [`scheduling.ex:566`](../api/lib/api/scheduling.ex#L566) e o moduledoc de
   [`rls_smoke_test.exs:28-30`](../api/test/api/rls_smoke_test.exs#L28) afirmam todos que o modo de
   falha é *"zero linhas, silenciosamente"*.

Isso é verdade só em **conexão fria**. Em conexão reciclada do pool — o caso comum em produção —
o sintoma é **500 intermitente**. Quem depurar procurando lista vazia vai procurar a coisa errada, e
a asserção "não-vazio" do gate `:rls` deixa de ser a que pega.

**Correção:** decidir uma forma e uniformizar as policies (todas com `NULLIF` → sempre 0 linhas, ou
nenhuma → sempre exceção), e corrigir os cinco textos.

---

## T-1 · ALTA — `Api.Packages.Sessions.segura/3` lê `appointments` sem GUC

**Local:** [`sessions.ex:76-84`](../api/lib/api/packages/sessions.ex#L76)

```elixir
defp segura(appt, pkg, clinic_id) do
  bloco = Api.Scheduling.get_appointment!(appt.id, tenant: clinic_id, authorize?: false, load: [:attendances])
```

Tem `tenant:` (o filtro do Ash), **não tem GUC**. O caminho:

```
materializer.ex:41  perform/1 (Oban)
packages.ex:406     somar_sessao/3            (o "+1" síncrono)
  └ materializer.ex:83   in_clinic(...)  → só o PLANO
  └ materializer.ex:96   create_sessions(...)   ← FORA do in_clinic (o comentário :94-95 diz isso)
      └ sessions.ex:63   schedule_appointment   (transação própria, COMMITA → GUC volta a '')
      └ sessions.ex:68   if pkg.status == :pausado, do: segura(...)
          └ sessions.ex:78  get_appointment!    ← SEM GUC
```

Sob `cinetra_app` isso **levanta** (prova em T-0). Dispara justamente no caso A-6 que o moduledoc de
`sessions.ex:41-49` existe para tratar: o usuário pausa o pacote na janela entre criar a série e o
job rodar.

**O gate `:rls` não pega** — e esse é o achado secundário. O sandbox roda o teste inteiro numa
transação, então o `SET LOCAL` de `materializar` fica **pendurado** e cobre a leitura seguinte. O
cenário exato (criar série → pausar → `sem_guc()` → `drain_queue`) rodou com
`%{success: 1, failure: 0}` e as 2 presenças criadas. É a limitação já registrada em
[`migrations.md` §3](../.claude/rules/migrations.md) (débito **D-15**), e vale **ampliá-la**: o gate
também não pega **leitura que acontece depois de uma escrita, dentro do mesmo job**.

**Correção:** `Api.Tenancy.in_clinic(clinic_id, fn -> ... end)` em volta do `get_appointment!`.

---

## T-2 · MÉDIA — `message_opt_outs` tem RLS e é lida/escrita sem GUC; hoje só funciona por acidente

**Local:** [`messaging.ex:78-133`](../api/lib/api/messaging.ex#L78) ·
[`opt_out.ex:104-120`](../api/lib/api/messaging/opt_out.ex#L104)

O comentário de `messaging.ex:78-79` diz *"`OptOut` não é por-tenant (é o único do projeto)"*.
Verdade no Ash, **falso no Postgres** — a policy é:

```sql
USING (clinic_id IS NULL OR clinic_id = nullif(current_setting('cinetra.clinic_id', true),'')::uuid)
```

Sem GUC, só as linhas globais são visíveis. E as ações `:registrar`/`:revogar` **não têm**
`change Api.Tenancy.SetTenantGuc`, ao contrário de todas as ações de `Message` e `Notification`.

No dia em que uma clínica tiver número próprio (o cenário C10/C11 que `opt_out.ex:25-30` prevê):
`opted_out?` responde `false` para opt-out por-clínica → **continuamos mandando mensagem paga para
quem pediu para parar**; `revoke_opt_out` não enxerga; `register_opt_out!` bate no `WITH CHECK`.

Latente porque os dois produtores gravam global (`webhooks.ex:144` e `:227` omitem `:clinic_id`).
Agrava: `opted_out?` é chamada de `dispatch.ex:137`, que ora roda **dentro** de um `with_clinic`
(`reminder_job.ex:62`), ora fora (`messages_controller.ex:69,146`) — o mesmo predicado responde
diferente conforme o chamador.

---

## T-3 · O resto da varredura está limpo

Varredura exaustiva de `Ash.read/get/load/count/exists?/bulk_*` e `Repo.query*` em `lib/`:
**nenhum** `Repo.all/one/get/update_all/delete_all/insert_all`. Todos os jobs (messaging,
notifications, housekeeping), `Fanout`, `Reminders`, `Warm`, `Bulk`, `Preview`, `Audit`,
`Materializer` (plano), os wrappers de domínio, as changes/validations e todos os controllers estão
sob `in_clinic`/`with_clinic`/`with_message`/`with_provider_message`, ou leem só tabelas globais.

`slot_finder.ex`, `availability.ex`, `impact_analysis.ex` e `periods.ex` são **puros** — zero acesso
a banco.

Nota: o comentário de [`records.ex:435-437`](../api/lib/api/records.ex#L435) justifica um
`in_clinic` dizendo que `memberships` tem RLS. Não tem (ver S-5). Inofensivo, mas ensina errado.

---

# 3. Bugs e riscos de correção

## B-1 · ALTA — Cancelar um bloco não alcança a presença segurada; a sessão paga some do pacote

**Local:** [`cascade_to_attendances.ex:42`](../api/lib/api/scheduling/appointment/changes/cascade_to_attendances.ex#L42)

```elixir
appointment |> Ash.load!([:attendances], authorize?: false, tenant: cs.tenant)
```

`Attendance` tem a preparation global `HideHeldAttendances`
([`attendance.ex:216`](../api/lib/api/scheduling/attendance.ex#L216)), que filtra `pkg_hold == false`.
`Ash.load!` de relação passa por ela. A irmã `RemoveParticipants` abre a porta explicitamente
([`remove_participants.ex:98`](../api/lib/api/scheduling/appointment/changes/remove_participants.ex#L98):
`Ash.Query.set_context(%{include_held: true})`); a `CascadeToAttendances` **não**. É assimetria entre
duas cascatas que deveriam ver o mesmo conjunto.

**Reproduzido.** Turma com Maria (pacote pausado ⇒ presença segurada) + colega,
`transition_appointment(:cancel)`:

```
DEPOIS do cancel (estado CRU no banco):
  [maria,  "prevista",  true,  "cancelado"]   ← órfã: viva, segurada, em bloco cancelado
  [colega, "cancelada", false, "cancelado"]
presencas do pacote (include_held): [prevista: true]
status apos resume: :ativo
presencas do pacote APOS resume (cru): [["prevista", true, "cancelado"]]
```

O `resume_package` **não recupera**: `held_targets/2`
([`packages.ex:238`](../api/lib/api/packages.ex#L238)) faz
`Enum.reject(&(&1.status == :cancelado))` sobre os blocos, o par cai fora, e
`enqueue_reproject(..., 0)` não reprojeta nada. **A sessão paga desaparece** — e a ficha continua
desenhando a bolinha como `:segurada` para sempre ([`packages.ex:708`](../api/lib/api/packages.ex#L708)),
num pacote `:ativo`.

**Correção:** `set_context(%{include_held: true})` na leitura, espelhando `remove_participants.ex:96-101`.

**Teste primeiro:** o roteiro acima, afirmando que a presença segurada fica `:cancelada`.

---

## B-2 · ALTA — `Fanout.user_name/1` nunca resolve o nome: as notificações dizem sempre "Um novo membro"

**Local:** [`fanout.ex:519-524`](../api/lib/api/notifications/fanout.ex#L519)

```elixir
defp user_name(user_id) do
  case Api.Accounts.get_user(user_id, authorize?: false, not_found_error?: false) do
    %{nome: nome} when is_binary(nome) -> nome
    _ -> "Um novo membro"
  end
end
```

`get_user/2` é code interface **não-bang**: devolve `{:ok, %User{}}`. Confirmado ao vivo:

```
retorno de get_user/2: {:ok, %Api.Accounts.User{nome: "Fulano da Silva", ...}}
```

Uma tupla nunca casa com `%{nome: nome}` → **o fallback é o único caminho**. Efeito: `member_joined`
(`fanout.ex:329`) e `member_removed` (`fanout.ex:382`) produzem *"Um novo membro entrou na clínica
como Recepção"*. Nenhum teste cobre (`grep -rn "Um novo membro" test/` → vazio). O irmão
[`slot_opened_job.ex:88-92`](../api/lib/api/notifications/slot_opened_job.ex#L88) faz certo.

**Correção:** `{:ok, %{nome: nome}} when is_binary(nome) -> nome`.

---

## B-3 · ALTA — Retry do `SendJob` reenvia mensagem paga quando a gravação de `:enviado` falha

**Local:** [`send_job.ex:128-143`](../api/lib/api/messaging/send_job.ex#L128)

```elixir
{:ok, provider, provider_id} ->
  Api.Repo.with_clinic(message.clinic_id, fn -> Messaging.do_mark_sent!(...) end)
  :ok                                   # resultado descartado
```

Se `do_mark_sent!` levantar (deadlock, timeout de pool, RLS), a exceção sobe e o `perform/1` estoura.
O Oban reenfileira (`max_attempts: 3`), a mensagem ainda está `:pendente`, o guard de
`send_job.ex:100` (`when status != :pendente`) não pega, e `Transport.entregar` roda de novo —
**segunda mensagem de WhatsApp paga** para o mesmo número. Se o `with_clinic` devolver `{:error, _}`
sem levantar, o valor é descartado na linha 141 e o job responde `:ok`: mensagem entregue e
eternamente `:pendente`.

**Correção:** casar o retorno explicitamente; e `Idempotency-Key` no Resend, como já existe na Zernio
([`zernio.ex:139`](../api/lib/api/messaging/zernio.ex#L139)).

---

## B-4 · ALTA — `Oban.insert` descartado: a mensagem trava a fila daquela presença para sempre

**Local:** [`dispatch.ex:326`](../api/lib/api/messaging/dispatch.ex#L326)

```elixir
Api.Messaging.SendJob.enqueue(message, agendar_para: agendado_para)
message
```

`enqueue/2` devolve `{:ok, job} | {:error, changeset}`. Se o insert falhar, a linha em `messages` já
existe como `:pendente` **sem job**. A partir daí `na_fila?/2` (`dispatch.ex:296-297`) bloqueia
**toda** tentativa futura com `{:skip, :ja_na_fila}`, e não há caminho de recuperação: nem cron, nem
botão de reenviar. A tela mostra "Na fila" indefinidamente.

**Correção:** inserir o job na mesma transação da criação da `Message` (`after_transaction` da ação
`:enqueue`), ou marcar `:falhou` quando o insert falhar.

---

## B-5 · ALTA — A trilha de acesso a anexo promete fail-closed e é fail-open

**Local:** [`records.ex:458-461`](../api/lib/api/records.ex#L458) ·
[`acesso.ex:177-190`](../api/lib/api/audit/acesso.ex#L177)

```elixir
defp registrar_evento(scope, acao, anexo),  do: Api.Audit.Acesso.anexo_tocado(scope, acao, anexo)
defp registrar_evento!(scope, acao, anexo), do: Api.Audit.Acesso.anexo_tocado(scope, acao, anexo)
```

Byte a byte idênticas. E `gravar/7` termina em `Logger.warning(...)` + `:ok` — **nunca levanta,
nunca devolve erro**. Mas o doc de `attachment_download/2`
([`records.ex:348`](../api/lib/api/records.ex#L348)) afirma o contrário: *"se a trilha não pode ser
escrita, o acesso não acontece"*. **A URL assinada do laudo é emitida mesmo com o `INSERT` da trilha
recusado.** Três lugares — o nome com `!`, o doc, e a implementação — dizendo duas coisas.

**Correção:** decidir e escrever uma só. Fail-closed exige um `anexo_tocado!/3` que propague o erro;
fail-open exige apagar `registrar_evento!/3` e corrigir o doc.

---

## B-6 · ALTA — `adjust_grade/3` cancela as futuras fora de transação

**Local:** [`packages.ex:500-508`](../api/lib/api/packages.ex#L500)

```elixir
with {:ok, atrs} <- grade_params(grade),
     :ok <- checar_profissional(...),
     {:ok, _grade} <- update_package_schedule(pkg.schedule, atrs, scope: scope) do
  Enum.each(futuras, fn alvo -> {:ok, _notes} = Api.Packages.Bulk.cancelar_sessao(scope, alvo) end)
  enqueue_from(pkg, scope, today, length(futuras))
```

Sem transação em volta. Uma falha no meio do `Enum.each` (o `{:ok, _notes} =` levanta) deixa parte
das sessões canceladas, a grade já reescrita e **nenhum job enfileirado** — exatamente o estado
"pacote vendido com N, zero na agenda" que o comentário de `packages.ex:495-499` diz ter consertado
ao reordenar as checagens. A reordenação fechou a recusa *previsível*; a atomicidade continua aberta.

O irmão `resume_package/2` faz certo ([`packages.ex:172-195`](../api/lib/api/packages.ex#L172):
`Api.Repo.transaction` envolvendo cancelamentos + `enqueue_reproject`). **Correção:** o mesmo
desenho.

---

## B-7 · ALTA — A dedup do `acesso_negado` usa o path cru: enumerar IDs derrota a dedup e infla `audit_events`

**Local:** [`tenant_scope.ex:306-311`](../api/lib/api_web/tenant_scope.ex#L306) ·
[`acesso.ex:93-97,120-128`](../api/lib/api/audit/acesso.ex#L93)

`forbidden/1` grava `acesso_negado(scope, conn.request_path)`, e a dedup para eventos sem
`record_id` casa por **`label`** — que é o path **com os UUIDs dentro**. O comentário promete
*"deduplicado em 30 min por (usuário, caminho)"*, mas o caso de uso que a função existe para detectar
é **varredura por IDOR**, que produz um path distinto por tentativa.

Resultado: **uma linha por request** na tabela que o próprio `Api.Audit` chama de a que mais cresce,
mais uma query síncrona de dedup por 403. O mecanismo anti-abuso é o amplificador do abuso.

**Correção:** [`request_logger.ex:105-114`](../api/lib/api_web/request_logger.ex#L105) já normaliza
segmentos UUID/numéricos para `:id`, no mesmo diretório. Usar `rota(path)` como `label` e o path cru
em `meta["caminho"]`.

---

## B-8 · MÉDIA — TOCTOU na barreira de mensagens, sem constraint que a feche

**Local:** [`dispatch.ex:233-241`](../api/lib/api/messaging/dispatch.ex#L233) (leitura) ×
`:309-324` (escrita) · [`message.ex:80-101`](../api/lib/api/messaging/message.ex#L80)

`barreira/3` lê numa transação e `enqueue_message!` escreve em outra. Dois POSTs simultâneos (duplo
clique da recepção, retry do cliente) passam os dois. **Não há índice único nem `identity`** sobre
`(attendance_id, kind)` filtrado por `status = 'pendente'` — os `custom_indexes` são todos de apoio
a FK e timeline.

O comentário de `dispatch.ex:295` registra a medição do caso **sequencial** (*"quatro linhas
idênticas para o mesmo paciente"*); a trava em memória resolve aquele, não este. Em WhatsApp cada
duplicata é paga.

**Correção:** `UNIQUE (attendance_id, kind) WHERE status = 'pendente'` + tratar a violação como
`{:skip, :ja_na_fila}` — a mesma classe de garantia que `appointments_no_overlap` já dá na agenda.

---

## B-9 · MÉDIA — Erros engolidos que viram "sucesso"

| Local | Padrão | Efeito |
| --- | --- | --- |
| [`send_job.ex:74-77,95`](../api/lib/api/messaging/send_job.ex#L74) | `ler/2` faz `\|> elem(1)`; `case … _ -> :ok` | erro de banco/RLS na leitura → job `completed`, mensagem nunca enviada, sem retry, sem log |
| [`fanout.ex:432-447`](../api/lib/api/notifications/fanout.ex#L432) | `with {:ok, n} <- create_notification(…)` **sem `else`** | `{:error, changeset}` sai como valor e é ignorado pelos ~6 chamadores. Zero log |
| [`fanout.ex:528-539`](../api/lib/api/notifications/fanout.ex#L528) | `rescue _ -> 0` sobre `who_fits` | qualquer erro → "ninguém cabe" → aviso de vaga nunca sai. Silêncio total |
| [`webhooks.ex:239-252`](../api/lib/api/messaging/webhooks.ex#L239) | `rescue erro -> Logger.warning(…); :ok` | falha de gravação vira **200**, o provider não reentrega, o estado congela |
| [`materializer.ex:51-54`](../api/lib/api/packages/materializer.ex#L51) | `{:error, _motivo} -> :ok` | **deliberado e documentado** — registrado só para contraste |

---

## B-10 · MÉDIA — `elem(1)` / match rígido sobre resultado de transação (11 lugares)

`send_job.ex:95`, `webhooks.ex:209`, `reminder_job.ex:70`, `patient_reply_controller.ex:83`,
[`tenancy.ex:35`](../api/lib/api/tenancy.ex#L35), `directory.ex:171,194,217,242`,
`records.ex:161,188`, `waitlist.ex:249`.

`Api.Repo.with_clinic/2` é `transaction/1`: devolve `{:ok, _} | {:error, _}`. `elem(1)` num rollback
devolve o *reason*; `{:ok, _} =` levanta `MatchError`. Em
[`reminder_job.ex:52-54`](../api/lib/api/messaging/reminder_job.ex#L52) o reason vira
`total + <atom>` → **`ArithmeticError` fora do `rescue` de `:71-77`: uma clínica com erro derruba a
rodada de todas.**

`Api.Tenancy.in_clinic/2:35` é o de maior alavancagem — é o wrapper de toda leitura por-tenant do
projeto. Ver **E-2** para a correção estrutural.

---

## B-11 · MÉDIA — Escrita Ash dentro de transação externa, contra o que `Api.Tenancy` documenta

`reminder_job.ex:62-69`, `send_job.ex:132,153`, `webhooks.ex:240`, `patient_reply_controller.ex:77`.

O `@doc` de `in_clinic/2` ([`tenancy.ex:20-21`](../api/lib/api/tenancy.ex#L20)) diz: *"Só para
leitura: envolver escrita numa transação externa quebra o caminho de erro"*. Nesses quatro pontos há
escrita dentro — e nos três últimos o `with_clinic` externo é **redundante**, porque as ações
`:mark_sent`, `:advance` e `:record_reply` já carregam `change Api.Tenancy.SetTenantGuc`
(`message.ex:208,226,270`).

No `ReminderJob` há um agravante: a conexão fica presa por toda a varredura de uma clínica, com um
`Dispatch.dispatch` (escrita + `Oban.insert`) por presença lá dentro.

---

## B-12 · MÉDIA — Corrida na capacidade da turma

**Local:** [`group_capacity.ex:77-90`](../api/lib/api/scheduling/appointment/validations/group_capacity.ex#L77)

`check/4` conta participantes numa transação própria; o `manage_relationship` grava em outra. Dois
`add_participant` concorrentes numa turma com uma vaga passam os dois. O
`identity :one_per_patient_per_appt` impede duplicata do mesmo paciente, **não** o estouro do teto.

O padrão certo já existe no projeto:
[`rollup_block_status.ex:38-41`](../api/lib/api/scheduling/attendance/changes/rollup_block_status.ex#L38)
usa `Ash.Query.lock(:for_update)` no bloco. Aplicar o mesmo no `before_action` de `:add_participant`
serializaria a contagem.

---

## B-13 · BAIXA — `archive_package/2` e `remove_session/2` sem atomicidade

[`packages.ex:329-349`](../api/lib/api/packages.ex#L329) — lê `futuras`, checa vazio e escreve fora
de transação (TOCTOU com um agendamento novo no meio).
[`packages.ex:439-461`](../api/lib/api/packages.ex#L439) — cancela a sessão e **depois** chama
`set_package_total`; se o segundo falhar, a sessão sumiu e o total não baixou.

## B-14 · BAIXA — `CampoValido` usa o relógio de parede

[`campo_valido.ex:61`](../api/lib/api/records/patient/validations/campo_valido.ex#L61) —
`Date.utc_today()` em vez de `changeset.context[:now]`, quebrando a disciplina do relógio injetável
que `StampExcludedAt` e `SessionStarted` seguem.

---

# 4. Contrato HTTP

## H-1 · MÉDIA — Quatro formatos distintos de corpo de erro na mesma API

| Origem | Corpo |
| --- | --- |
| `TenantScope` (convenção do projeto) | `{"error":"invalid","details":[{"field":…,"message":…}]}` |
| `ApiWeb.ErrorJSON` (rota inexistente, exceção Ash) | `{"errors":{"detail":"Not Found"}}` |
| `AshJsonApi` em `/api/json/*` | `{"errors":[{"code":…,"status":"404"}],"jsonapi":{"version":"1.0"}}` |
| Ad-hoc nos controllers | `{"error":"missing_token"}`, `{"error":"no_active_clinic"}`, `{"error":"assinatura_invalida"}` |

[`tenant_scope.ex:233-248`](../api/lib/api_web/tenant_scope.ex#L233) documenta a consolidação de
*cinco* lugares que montavam o 422 à mão e se declara *"fonte única do corpo 422"*. A consolidação
parou no 422: 400, 404 fora das guardas, 409 e 503 seguem sem fonte única, e `ErrorJSON` — a mais
alcançável de todas, porque pega toda exceção não tratada — nunca entrou na conversa.

## H-2 · MÉDIA — Três corpos diferentes para 401

```
$ curl http://localhost:4010/api/auth/me      → {"error":"not_authenticated"}   [401]
$ curl http://localhost:4010/api/patients     → {"error":"unauthenticated"}     [401]
```

mais `{"error":"unauthorized"}` em [`verify_token_subject.ex:55`](../api/lib/api_web/plugs/verify_token_subject.ex#L55).

`ApiWeb.TenantScope.unauthorized/1` (`:277-279`) se declara *"401 padrão da fronteira… **Fonte única
do corpo**"* — e o `AuthController`, que a importa (linha 12, só `error_response: 2`), reimplementou
a sua em `auth_controller.ex:251-253`, usada em **5** call sites. O BFF já depende da divergência:
`web/src/routes/page.server.test.ts:47` fixa `not_authenticated`.

## H-3 · MÉDIA — `GET /patients/:patient_id/packages`: id de outra clínica → 200 vazio; id malformado → exceção

**Local:** [`packages_controller.ex:27-39`](../api/lib/api_web/controllers/packages_controller.ex#L27)
→ [`packages.ex:756-764`](../api/lib/api/packages.ex#L756)

O irmão exato, `GET /patients/:patient_id/history`, resolve o paciente primeiro e documenta por quê
([`patients_controller.ex:79-81`](../api/lib/api_web/controllers/patients_controller.ex#L79)):
*"Sem isto, um id de outra clínica (ou lixo) devolvia **200 com lista vazia**"*. O de pacotes passa o
`patient_id` cru para `Ash.Query.filter`. Dois defeitos numa rota:

- **id de outra clínica** (UUID válido) → `200 {"packages":[]}`, indistinguível de "não tem pacote";
- **id não-UUID** → `list_packages!` levanta `Ash.Error.Invalid`/`InvalidFilterValue` → **400** com
  corpo `{"errors":{"detail":"Bad Request"}}` (outro formato) e stacktrace no log.

É o mesmo bug que o `AuditController` já corrigiu e documentou
([`audit_controller.ex:74-77`](../api/lib/api_web/controllers/audit_controller.ex#L74)).
**Correção:** `Records.fetch_clinic_patient/3` antes da listagem — a função já trata id malformado
como `{:ok, nil}`.

## H-4 · MÉDIA — `GET /packages/:id/sessions` é a única rota que resolve id por função `!`

**Local:** [`packages_controller.ex:136`](../api/lib/api_web/controllers/packages_controller.ex#L136)

```elixir
_pkg = Packages.get_patient_package!(scope, id, load: [])   # comentário: "404 se não é desta clínica"
```

Id de outra clínica → 404 **com corpo `{"errors":{"detail":"Not Found"}}`** e crash logado, contra o
`{"error":"not_found"}` de todos os irmãos; id malformado → **400**, não 404. A intenção no
comentário está certa; o mecanismo é o errado. Mesma classe em
[`appointment_types_controller.ex:27`](../api/lib/api_web/controllers/appointment_types_controller.ex#L27)
e [`messages_controller.ex:193`](../api/lib/api_web/controllers/messages_controller.ex#L193).

Bônus: `Packages.list_sessions/2` refaz o mesmo `get_package!`
([`packages.ex:635`](../api/lib/api/packages.ex#L635)) — duas leituras da mesma linha por request.

## H-5 · MÉDIA — `camelCase` em dois controllers, `snake_case` em todos os outros

[`messages_controller.ex:79-124,164-170`](../api/lib/api_web/controllers/messages_controller.ex#L79)
e [`patient_reply_controller.ex:147`](../api/lib/api_web/controllers/patient_reply_controller.ex#L147):
17 chaves camelCase (`attendanceId`, `patientId`, `semEnvio`, `erroTexto`, `enfileiradoEm`,
`agendadoPara`, `descarteMotivo`, `respondidoEm`, …) contra ~200 snake_case no resto. O `patientId`
da timeline e o `patient_id` de `AgendaJSON.participants` são **o mesmo campo do mesmo domínio com
dois nomes**.

## H-6 · BAIXA — `409` para "sem clínica ativa" contraria a regra escrita pelo projeto

[`auth_controller.ex:201-202`](../api/lib/api_web/controllers/auth_controller.ex#L201). O
[`tenant_scope.ex:98-100`](../api/lib/api_web/tenant_scope.ex#L98) define: *"422 = 'seu pedido está
errado'; 409 = 'seu pedido estava certo, o mundo mudou'. Reservado a concorrência"*. "Você não tem
clínica ativa" não é concorrência — e o corpo não segue nem a forma do 409 do projeto.

## H-7 · BAIXA — `403 no_active_membership` no `switch-tenant` mistura autorização com validação

[`auth_controller.ex:107-108`](../api/lib/api_web/controllers/auth_controller.ex#L107). Pedir troca
para uma clínica sem vínculo é 422 (ou 404) — o ator não está proibido de nada, o alvo é que não
existe para ele. Como está, o cliente não distingue "sem permissão" de "não é sua".

## H-8 · BAIXA — Forma de `page` divergente, e duas cópias moram no domínio

- `patients_controller.ex:31` → `%{limit, offset, total, more}`
- `notifications_controller.ex:38` → `%{limit, offset, more}` (sem `total`)
- [`audit.ex:129-133`](../api/lib/api/audit.ex#L129) → sem `total`, montado **no domínio**
- [`waitlist.ex:69`](../api/lib/api/waitlist.ex#L69) → com `total`, também **no domínio**

A ausência de `total` é justificada ([`pagination.ex:66-77`](../api/lib/api/pagination.ex#L66),
`count: false` custa 400× menos buffers) — o problema é o cliente ter de saber, endpoint a endpoint,
se o campo existe. E duas formas são montadas fora da fronteira, contra a regra que o próprio
`AppointmentsController` enuncia (`:261-264`: *"A fronteira nomeia o wire… e não o domínio"*).

## H-9 · BAIXA — `POST /appointments/:id/messages` responde 201 mesmo quando nada foi criado

[`messages_controller.ex:50-51`](../api/lib/api_web/controllers/messages_controller.ex#L50). Se todos
os participantes caem em `{:skip, motivo}`, nenhuma `Message` nasce e a resposta ainda é
`201 Created`.

## H-10 · BAIXA — `401` com header `Location` (redirect que browser nenhum segue)

[`auth_controller.ex:50-53`](../api/lib/api_web/controllers/auth_controller.ex#L50) e
[`auth_strategy_controller.ex:24-28`](../api/lib/api_web/controllers/auth_strategy_controller.ex#L24).
`Phoenix.Controller.redirect/2` faz `send_resp(conn.status || 302, …)` — com `put_status(:unauthorized)`
antes, sai **401 + Location**. Funciona porque o BFF usa `redirect: 'manual'` e olha só o status, e
os testes fixaram o comportamento. Registrado porque o código *parece* fazer um redirect que não faz.

---

# 5. Rate limiting e borda

## L-1 · MÉDIA — Webhooks: sem rate limit, com corpo de até 8 MB retido duas vezes

[`router.ex:283-293`](../api/lib/api_web/router.ex#L283) (escopo sem estágio de limite) +
[`endpoint.ex:58-65`](../api/lib/api_web/endpoint.ex#L58) (sem `length:`) +
[`cache_raw_body.ex:39-48`](../api/lib/api_web/plugs/cache_raw_body.ex#L39)

```
$ curl -o /dev/null -w "%{http_code}\n" -X POST --data-binary @big.json .../webhooks/zernio   # 7,5 MB
401                       # real 0m0.126s → leu e bufferizou tudo antes de recusar
$ ... --data-binary @bigger.json  # 9 MB
413                       # confirma o teto default de 8 MB do Plug.Parsers
```

`/webhooks/*` é o **único caminho de escrita publicamente alcançável** pelo Traefik e está fora dos
dois estágios de rate limit, por decisão registrada (`router.ex:279-282`: a rajada do provider
estouraria os 200/min). A decisão é boa; o efeito colateral não foi considerado: cada requisição
anônima retém ~8 MB de corpo cru em `conn.private[:raw_body]` **mais** o mapa decodificado. Uma
centena de conexões concorrentes é pressão de memória num A1 sem nada na frente.

**Correção:** `CacheRawBody` já é seletivo por caminho — dar a ele um teto próprio (256 KB; nenhum
evento de Resend/Zernio chega perto) resolve sem tocar nas rotas autenticadas. É fail-closed: corpo
maior que o teto não fecha assinatura de qualquer forma.

## L-2 · MÉDIA — O estágio de borda roda depois de o corpo já ter sido lido e decodificado

[`endpoint.ex:58`](../api/lib/api_web/endpoint.ex#L58) (`Plug.Parsers`) × `:70` (`plug ApiWeb.Router`).
O `router.ex:32-34` justifica o estágio `:edge` dizendo que sem ele *"cada requisição barrada ainda
pagava as 5 queries da stack de sessão"*. Verdadeiro para o **banco**, falso para o **corpo**: o
`Plug.Parsers` é plug do endpoint e roda antes do router, então mesmo a requisição que vai levar 429
já teve até 8 MB lidos, alocados e decodificados. **Correção:** o limitador de borda precisa ser plug
de endpoint, entre `Plug.Telemetry` e `Plug.Parsers` — o que também lhe daria a cobertura que hoje
não tem (health checks e webhooks).

## L-3 · MÉDIA — WebSocket e `join` de canal ficam inteiramente fora de qualquer rate limit

[`endpoint.ex:30`](../api/lib/api_web/endpoint.ex#L30) (`socket "/socket"`) precede `plug ApiWeb.Router`.
Os dois limitadores são plugs de pipeline do router; o transporte de socket é montado antes.
Consequências: handshakes anônimos em `/socket` (rota **pública** no Traefik) sem teto; e **cada
`join` faz uma query ao banco** ([`channel_scope.ex:75-80`](../api/lib/api_web/channels/channel_scope.ex#L75)),
permitindo `join`/`leave` em laço com um token válido de 15 min. **Correção:** contar `join` por
`user_id` no `Api.RateLimiter.Global` dentro de `ChannelScope.authorize/2` — ponto único por onde os
três canais passam.

## L-4 · MÉDIA (não confirmado) — No default do deploy, a chave de IP é escrita pelo cliente

[`client_ip.ex:38,46-53`](../api/lib/api_web/client_ip.ex#L38) × `compose.dokploy.yml:164`

O default de `trusted_client_ip_headers` é `[]`, o fallback é `x-forwarded-for`, e lê-se o
**primeiro** elemento. O compose define `TRUSTED_CLIENT_IP_HEADER: ${CLIENT_IP_HEADER:-}` — **vazio
por padrão**. O Traefik *acrescenta* ao XFF que chegou, não substitui; logo, com o default do stack,
o primeiro elemento é o que o cliente mandou, e os dois limitadores — inclusive o anti-brute-force do
magic link — viram por-atacante-escolhe-o-balde.

O [`runtime.exs:195-201`](../api/config/runtime.exs#L195) descreve esse mecanismo — para o caso do
Cloudflare. O que não está fechado é o **default**. Não há config de proxy em `deploy/` que permita
confirmar o comportamento real, daí "não confirmado".

Relacionado ao débito **D-16** já registrado, mas com um ângulo novo: ali a discussão é sobre qual
header confiar; aqui é que **no default vigente nenhum é confiável**. **Correção:** ler o **último**
salto do XFF (o único que o Traefik garante) em vez do primeiro.

## L-5 · BAIXA — Negação de 429 não deixa rastro investigável

[`rate_limit.ex:37-43`](../api/lib/api_web/rate_limit.ex#L37) — `deny/2` responde e `halt`a sem
`Logger`. O `RequestLogger` registra `status=429` sem IP (ver O-1), sem a chave que estourou e sem o
limite. Num incidente de brute-force, o log responde "houve 429" e não responde "de quem".

---

# 6. Performance

## P-1 · ALTA — `GET /api/waitlist/slots` recomputa o expediente uma vez por item da fila

[`waitlist.ex:254-262`](../api/lib/api/waitlist.ex#L254) →
[`slot_finder.ex:117`](../api/lib/api/waitlist/slot_finder.ex#L117)

`run_finder/5` é chamado **por entry**, e dentro dele `slots_for/7` chama
`Availability.day_periods(date, prof, sources)` — cujo resultado depende só de `(prof, date)`, nunca
do entry. Com a página cheia (teto 200) e 15 profissionais ativos × 14 dias: **42.000 composições de
expediente idênticas por request**, cada uma varrendo `clinic_exceptions`/`professional_exceptions`/
`professional_hours` linearmente.

O moduledoc resolveu o N+1 de **banco** (`appts_index/5` tem a forma certa); o N+1 de **CPU** ficou
de pé.

**Correção:** materializar `%{{prof_id, Date} => {:open, periods} | {:closed, reason}}` uma vez em
`slots_by_entry/2`, ao lado do `appts_index`, e trocar `slot_finder.ex:117` por `Map.fetch!/2`. Cai
de `entries × N × 14` para `N × 14`. Junto: `slot_finder.ex:111` faz `acc = acc ++ day_slots` seguido
de `length(acc)` a cada dia — append quadrático, gratuito.

## P-2 · MÉDIA — `who_fits/5` lê a fila inteira sem teto, com agregado carregado, e filtra em Elixir

[`waitlist.ex:337-344`](../api/lib/api/waitlist.ex#L337). `list_waitlist_entries` é a ação `:read`
default — **sem paginação**, ao contrário da `:queued`
([`waitlist_entry.ex:67-75`](../api/lib/api/waitlist/waitlist_entry.ex#L67), `max_page_size: 200`).
`entry_load/0` puxa `:rules` e o paciente com o agregado `:faltas` (`LEFT JOIN LATERAL` sobre
`attendances`). O consumidor `GET /api/waitlist/candidates` devolve a lista inteira sem teto. **É a
única lista do projeto sem teto.**

## P-3 · MÉDIA — `Poda.em_lote/4` recursa dentro de uma transação só: o lote não protege nada

[`poda.ex:36-40`](../api/lib/api/housekeeping/poda.ex#L36) × `:55-70`. `por_clinica/1` envolve
`fun.(clinic_id)` num `with_clinic` (uma transação) e `em_lote/4` recursa até esgotar **lá dentro**.
O moduledoc (`:14-16`) justifica o lote dizendo que *"anos de histórico numa transação só seguram
conexão do pool e incham o WAL"* — mas o `LIMIT 5000` reduz o tamanho de cada `DELETE`, **não o da
transação**. Uma clínica com 300 mil eventos ainda produz um COMMIT de 300 mil linhas com a conexão
presa. As duas podas rodam 03:00 e 03:15 na fila `housekeeping: 2`.

**Correção:** inverter — laço de lotes fora, cada `DELETE` no próprio `with_clinic`. É a estrutura
que `PruneAttachments` (`:55-66`) já usa e documenta.

## P-4 · MÉDIA — N+1 de queries em `ja_confirmada?/1`

[`notifier.ex:250,254-260`](../api/lib/api/messaging/notifier.ex#L250) —
`Enum.reject(vivas, &ja_confirmada?/1)`, uma query por participante. Num `add_participant` de turma
de 8, são 8 `SELECT TRUE … LIMIT 1`. Uma leitura só com `attendance_id in ^ids` + `MapSet` resolve —
é o desenho que `Dispatch.barreira` já usa e documenta (`dispatch.ex:247-248`).

## P-5 · MÉDIA — Varreduras de tabela inteira em cron

[`poda.ex:44-46`](../api/lib/api/housekeeping/poda.ex#L44) — `Api.Accounts.list_clinics!()` carrega
**todas** as clínicas. Chamado por `SessionSoonJob` (a cada 5 min → **288×/dia**), `ReminderJob` e
`DailyDigestJob` (24×/dia cada). Cabe `Ash.stream!`.
[`prune_attachments.ex:77-81`](../api/lib/api/housekeeping/prune_attachments.ex#L77) — `Ash.read!` de
todos os pendentes de uma clínica, sem limite.

## P-6 · MÉDIA — `future_conflicts/2` varre a agenda futura inteira dentro da transação de escrita

[`scheduling.ex:1277-1290`](../api/lib/api/scheduling.ex#L1277) — `find_appointments!(stream?: true)`
seguido de `Enum.map` materializa tudo. Roda **dentro** do `Api.Repo.transaction` de
`update_clinic_hours/2` (`:1383`) e `update_professional_hours/3` (`:1599`). Salvar o expediente
custa uma varredura de todo o futuro, com `total` sem teto por decisão de produto. Aceitável hoje;
vira problema com anos de agenda.

## P-7 · MÉDIA — Oban: dedup e cron sobrepostos

- [`slot_opened_job.ex:38`](../api/lib/api/notifications/slot_opened_job.ex#L38) —
  `unique: [period: 60, fields: [:worker, :args]]`, mas `args` inclui `"actor_id"` (`:48-52`). Dois
  usuários tocando o mesmo bloco geram **dois jobs → duas notificações "vaga livre"**. Falta
  `keys: [:clinic_id, :appointment_id]`.
- `config/config.exs:119` e `:127` — `DailyDigestJob` e `ReminderJob` no mesmo `{"0 * * * *"}`, na
  mesma fila, ambos varrendo clínica a clínica, um deles segurando transação. O projeto já aplicou o
  desencontro deliberado nas podas (`:110-111`); vale aqui.

Fora isso, a config está correta: filas certas nos 8 workers, e `max_attempts: 1` nos crons de
relógio é a escolha adequada (a janela é derivada do relógio e ladrilha).

## P-8 · BAIXA — Leituras redundantes

- [`waitlist_controller.ex:112`](../api/lib/api_web/controllers/waitlist_controller.ex#L112) —
  `all_slots/2` chama `list_entries/2`, que faz `COUNT(*) OVER ()` + `list_professionals!` completo,
  e **descarta os dois**.
- [`waitlist_controller.ex:19-40`](../api/lib/api_web/controllers/waitlist_controller.ex#L19) —
  `list_entries` (que já traz `page.count`) **e** `entry_counts(scope)`, cujo `:todas` é o mesmo número.
- `packages_controller.ex:136` + `packages.ex:635` — o mesmo `get_package!` duas vezes por request.
- [`session_soon_job.ex:56-60`](../api/lib/api/notifications/session_soon_job.ex#L56) — resolve o
  fuso de toda clínica **antes** do teste barato de `Reminders.por_dono_da_coluna`, invertendo a
  lição documentada em `reminders.ex:94-104`.

## P-9 — Índices: não foi possível medir

O banco de dev está praticamente vazio (`appointments` 234 linhas, `patients` 0) e
`pg_stat_user_indexes.idx_scan = 0` em quase tudo. A modelagem lida é sólida e justificada linha a
linha (`all_tenants?: true` para checagem de FK, prefixo estrito não pedindo índice próprio,
`CONCURRENTLY` nas migrations quentes). Medir de verdade exige volume — ver
[`migrations.md` §2](../.claude/rules/migrations.md).

---

# 7. Aderência ao Ash

## A-1 · MÉDIA — `AvailabilityRule` abre a escrita para qualquer ator

[`availability_rule.ex:80-82`](../api/lib/api/waitlist/availability_rule.ex#L80):
`policy action_type([:create, :update, :destroy]) do authorize_if always() end`.

O moduledoc justifica (*"só o `WaitlistEntry` gerencia"*), mas `always()` é uma afirmação sobre quem
chama, não uma garantia — e o domínio já expõe `define :list_availability_rules`. O idiomático que
expressa a invariante real é `authorize_if accessing_from(Api.Waitlist.WaitlistEntry, :rules)`.

## A-2 · MÉDIA — Bangs do Ash em controller escapam da escada de erro

Ver **H-4** — `packages_controller.ex:136`, `appointment_types_controller.ex:27`,
`messages_controller.ex:193`.

## A-3 · MÉDIA — `professional_id` cru em filtro de coluna `uuid`

[`availability_controller.ex:84-96`](../api/lib/api_web/controllers/availability_controller.ex#L84)
→ [`scheduling.ex:1132-1139`](../api/lib/api/scheduling.ex#L1132). `fetch_professionals/1` só faz
split/trim/reject; o valor vai direto para `Ash.Query.filter(Professional, id in ^ids)` +
`list_professionals!` (bang). É a classe que o `AuditController` documenta ter consertado em si
mesmo. **E não há `test/api_web/controllers/availability_controller_test.exs` — é o único controller
de tenant sem teste próprio.**

## A-4 · MÉDIA — Query crua onde havia code interface / ação de leitura

- [`notifier.ex:254-259`](../api/lib/api/messaging/notifier.ex#L254) — `Ash.Query.for_read(:read) |>
  filter(…) |> Ash.exists?` para "esta presença já tem confirmação?". A `Message` já tem
  `:for_attendance` (`message.ex:138-146`) e o domínio já expõe `list_attendance_messages`. É a
  **mesma pergunta** que `Dispatch.alcancadas/2` responde por outro caminho — duas definições de "já
  falamos com esta pessoa".
- [`reminder_job.ex:100-106`](../api/lib/api/messaging/reminder_job.ex#L100) — filtro
  `status == :prevista` + recorte por `session_starts_at` soltos num worker; cabia uma
  `read :na_janela` em `Attendance`.
- [`notifications.ex:60-64`](../api/lib/api/notifications.ex#L60) — `Ash.Query.for_read(:unread) |>
  Ash.count!` ignorando o `define :list_unread_notifications` da linha 22.
- [`acesso.ex:144-150`](../api/lib/api/audit/acesso.ex#L144) — monta a query à mão para
  `:recent_duplicate`, enquanto o `define` correspondente fica sem chamador (ver M-1).

## A-5 · MÉDIA — Upsert manual onde o Ash tem `upsert?`

[`messaging.ex:100-119`](../api/lib/api/messaging.ex#L100) — `if opted_out? … else register_opt_out!`
é upsert escrito à mão, **com corrida** (a Zernio reentrega até 7× em 24 h) e **sem índice único**
(`opt_out.ex:73-76` é parcial mas não único). `create :registrar` com `upsert?: true` + `identity`
resolve no banco e elimina a leitura extra por mensagem.

## A-6 — O que está verificadamente certo (para não gerar retrabalho)

- **Policies:** nenhum `authorize_if` empilhado acidental. Os dois casos de empilhamento
  (`membership.ex:128-135`, `user.ex:32-39`) são OR **deliberado e documentado**. O AND real está
  expresso por policies separadas — `appointment.ex:422-427` é o exemplo canônico e está correto.
- **Ação sem policy = proibida:** `set_pkg_hold` e `apply_participant_rollup` ficam fora de
  `@write_actions` de propósito; são cascatas internas com `authorize?: false`.
- **`authorize?: false`** (153 ocorrências): todos os inspecionados são lookups de invariante
  cross-recurso com `tenant:` explícito e sem actor, ou operações de sistema. Nenhum vazamento de
  fronteira HTTP.
- **Hooks:** todo efeito externo (e-mail/WhatsApp/PubSub) sai por `Ash.Notifier`, pós-commit. O único
  `before_action` estrutural é `SetTenantGuc`, que é onde deve estar. `Api.Audit.Capture` roda em
  `after_action` **dentro** da transação, e o moduledoc argumenta corretamente por quê.
- **`String.to_atom`:** zero. Os três `to_existing_atom` estão atrás de whitelist fechada validada
  antes da conversão.
- **Tenant nunca vem do corpo/URL:** nenhum controller aceita `clinic_id`/`actor` de `params`;
  `LoadScope` é a única fonte.
- **Rotas:** nenhuma rota órfã e nenhuma action de controller inalcançável (cruzamento completo das
  22 rotas × controller × action). Toda action de domínio tem guarda de escopo.
- **Canais:** os 3 fazem as duas guardas (`same_clinic` + releitura do vínculo) via `ChannelScope`, e
  o recorte A7 vale nos dois modos de push.
- **Webhooks:** fail-closed — assinatura antes de qualquer leitura de banco.
- **Validação de entrada:** `whitelist/2` aplicada em todos os corpos de escrita, com `Map.has_key?`
  em vez de truthiness; `parse_int/1` recusa negativo; `parse_window/4` tem teto.

---

# 8. Duplicação e reutilização

## R-1 · MÉDIA — `Api.Params.get/2` reimplementado dentro de `Api.Scheduling`

[`scheduling.ex:237-239`](../api/lib/api/scheduling.ex#L237) ×
[`params.ex:67-68`](../api/lib/api/params.ex#L67)

```elixir
defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))   # scheduling
def  get(params, key),  do: Map.get(params, key, Map.get(params, Atom.to_string(key))) # params
```

Idênticas. `Api.Params` nasceu do bate-volta da Onda 3 (doc 43 §5e) precisamente para acabar com as
quatro cópias divergentes desse padrão — e a cópia voltou.

## R-2 · MÉDIA — `uuid?/1` duplicado e três variantes soltas de `Ecto.UUID.cast`

```
$ grep -rn "defp uuid?\|Ecto.UUID.cast" lib/
lib/api/scheduling.ex:556-557    defp uuid?(...)          ┐ idênticas
lib/api/packages/bulk.ex:367-368 defp uuid?(...)          ┘
lib/api/directory.ex:136         case Ecto.UUID.cast(id)  ┐
lib/api/records.ex:112           case Ecto.UUID.cast(id)  ├ mesmo "id malformado → {:ok, nil}"
lib/api/records.ex:217           case Ecto.UUID.cast(id)  ┘
lib/api_web/controllers/audit_controller.ex:82            (variante que devolve 422)
```

E `availability_controller.ex` é onde a validação **falta** (A-3), e `packages_controller.ex` onde
falta na listagem (H-3).

## R-3 · MÉDIA — Quatro implementações de "só os dígitos"

```
lib/api/cpf.ex:22                                    String.replace(value,   ~r/\D/, "")
lib/api/records/preparations/filter_patients.ex:51   String.replace(trimmed, ~r/\D/, "")
lib/api/messaging/dispatch.ex:206                    String.replace(valor,   ~r/\D/, "")
lib/api/messaging/zernio.ex:182                      defp somente_digitos(destino)
```

`Api.Cnpj.normalize/1` usa `~r/[^0-9A-Z]/` e **não** é duplicata (CNPJ alfanumérico, regra diferente
de propósito).

## R-4 · BAIXA — Outras repetições verificadas

- `records.ex:458` × `:460` — `registrar_evento/3` e `registrar_evento!/3` byte a byte (é o **B-5**).
- `reminder_job.ex:110-115` × `session_soon_job.ex:77-82` — `agora/1` idêntico; cabe em
  `Api.Notifications.Reminders`.
- Desembrulho `{:ok, {:ok, %{}}}` copiado em `fanout.ex:491,505`, `slot_opened_job.ex:69`, com
  variante `elem(1)` em `send_job.ex:87` e `webhooks.ex:202`. `Api.Tenancy.in_clinic/2` já faz isso;
  ninguém ali o usa.
- `directory.ex:169-256` — quatro funções com a moldura
  `{:ok, x} = Api.Repo.with_clinic(clinic_id, fn -> get_… end)` idêntica.
- `waitlist.ex:357-360` (`priority_rank/1`) × `waitlist_entry.ex:189-198` (calculation `prio_rank`) —
  a mesma ordenação em duas representações; dívida assumida no doc do recurso.
- `falhas.ex:33-39` — comentário duplicado literalmente (resto de merge).
- `prune_attachments.ex:84-93` reimplementa a ordem "objeto antes da linha" de
  `Api.Records.delete_attachment/2`, e o comentário `:65-66` admite.
- **Camada web:** `%{error: "bad_request"}` escrito à mão em três lugares (`tenant_scope.ex:93`,
  `packages_controller.ex:273-274`, `attachments_controller.ex:227`) — o `TenantScope` não expõe
  `bad_request/1` público, então dois controllers o recriaram. E `parse_date` duplicado entre
  `tenant_scope.ex:213-222` e `packages_controller.ex:276-277`, com `parse_datetime` órfão em
  `waitlist_controller.ex:206-213`.

---

# 9. Código morto

Tudo abaixo verificado com `grep -rn <nome> lib test` — nenhuma ocorrência além da definição.

## M-1 · MÉDIA — Símbolos deletáveis hoje

| Símbolo | Local | Evidência |
| --- | --- | --- |
| `def max_rotulo/0` | [`audit.ex:74`](../api/lib/api/audit.ex#L74) | 3 hits: `@max_rotulo` em `:36` e `:68`, e a definição |
| `def entregue?/1` | [`message.ex:379`](../api/lib/api/messaging/message.ex#L379) | 1 hit. O `@doc` diz *"Usada pela timeline e pelo 'reenviar'"* — o commit `542b64f` removeu esse consumidor |
| `def default_limit/0` | [`pagination.ex:22`](../api/lib/api/pagination.ex#L22) | `@default_limit` é lido em `:44`; o acessor não |
| `def list_held_sessions/2` | [`scheduling.ex:1451`](../api/lib/api/scheduling.ex#L1451) | única menção é o `@doc` da função que a substituiu (`:1491`) |
| `define :list_users` | [`accounts.ex:17`](../api/lib/api/accounts.ex#L17) | o comentário em `:14-16` já explica que ficou obsoleto no doc 63 |
| `define :list_recent_duplicates` | [`audit.ex:42`](../api/lib/api/audit.ex#L42) | a action vive, mas é chamada por `Ash.Query` cru em `acesso.ex:144-150` |
| `define :list_availability_rules` | [`waitlist.ex:34`](../api/lib/api/waitlist.ex#L34) | regras sempre chegam por `load: [:rules]` |
| `define :get_package_schedule` | [`packages.ex:32`](../api/lib/api/packages.ex#L32) | — |
| `define :get_attendance` | [`scheduling.ex:51`](../api/lib/api/scheduling.ex#L51) | — |
| `defp registrar_evento!/3` | [`records.ex:460`](../api/lib/api/records.ex#L460) | clone exato de `:458` (e **B-5**) |
| `def max_age/0` | [`reply_token.ex:31`](../api/lib/api/messaging/reply_token.ex#L31) | — |
| `ApiWeb.Telemetry.metrics/0` + `periodic_measurements/0` | [`telemetry.ex:22-61`](../api/lib/api_web/telemetry.ex#L22) | ver abaixo |

**`ApiWeb.Telemetry.metrics/0` (40 linhas)** merece nota: nenhum reporter o consome (o
`ConsoleReporter` está comentado, `:15-16`), `periodic_measurements/0` devolve `[]`, e as métricas
que declara (`phoenix.endpoint.stop.duration`, `phoenix.router_dispatch.*`,
`phoenix.channel_joined.*`, `vm.memory.total`) são **exatamente** as que o `Api.PromEx` de fato
exporta via `Plugins.Phoenix` e `Plugins.Beam`. Quem procurar "onde estão definidas as métricas de
HTTP" encontra primeiro a lista morta.

## M-2 · MÉDIA — Superfície AshJsonApi montada servindo domínio vazio

[`meta.ex:14-20`](../api/lib/api/meta.ex#L14), `ash_json_api_router.ex:3`,
[`router.ex:50-58`](../api/lib/api_web/router.ex#L50). `Api.Meta` tem `routes do end` e
`resources do end`. Mesmo assim `/api/json` é montado com `forward` + `SwaggerUI`. Custo: dois
módulos, duas deps (`ash_json_api`, `open_api_spex`) e duas rotas públicas que não servem nada
(ver **S-4**). `open_api_spex` só aparece nessa linha do router.

## M-3 · BAIXA — Scaffolding de `mix phx.new` numa API JSON

`Plug.Static` servindo `priv/static` ([`endpoint.ex:37-42`](../api/lib/api_web/endpoint.ex#L37)) —
provado: `GET /robots.txt` → **200**. E `Plug.MethodOverride` (`:67`), sem uso: nenhuma rota depende
de `_method`. Superfície sem função.

## M-4 — API de domínio sem rota (decisão humana, não deleção automática)

- `Api.Records.list_clinic_attachment_events/2` ([`records.ex:403`](../api/lib/api/records.ex#L403))
  — 8 referências, **todas em `test/`**. O `@doc` diz *"o histórico deste anexo é uma pergunta da
  ficha"*; a ficha não pergunta, e não há rota. É o mesmo padrão que a migration
  `20260728070000_drop_attachment_events.exs` diz ter consertado.
- `Api.Scheduling.list_professional_exceptions/2` ([`scheduling.ex:1696`](../api/lib/api/scheduling.ex#L1696))
  — existem `POST`/`DELETE /professionals/:id/exceptions`, **nenhum `GET`**.
- `Api.Messaging.revoke_opt_out/3` ([`messaging.ex:127`](../api/lib/api/messaging.ex#L127)) — só um
  teste. Sem rota; e ganharia uma quebrada em produção (**T-2**).

Já verificados como **padrão legítimo** ("o teste ancora a constante"), não código morto:
`Api.Audit.Acesso.janela_minutos/0`, `AppointmentType.cores/0`, `AppointmentType.icones/0`,
`Templates.kind_de/1`.

## M-5 — `priv/` está limpo

```
$ find api/priv -type f -name "*.ex*" | grep -v "^api/priv/repo/migrations/"
(vazio)
$ find api/priv -type f | grep -vE "^api/priv/(repo/migrations|resource_snapshots|gettext|static|sql)/"
(vazio)
```

`priv/` respeita integralmente a **regra 1** de [`migrations.md`](../.claude/rules/migrations.md) —
71 migrations geradas, snapshots, gettext, static e dois `.sql` de setup de role. **Zero** `.ex`/`.exs`
escrito à mão.

Também limpo: nenhum `defp` órfão, nenhum módulo órfão, nenhum alias/import morto (coerente com
`--warnings-as-errors` verde), nenhum atributo de recurso não lido, nenhum `TODO`/`FIXME`/
`IO.inspect`/`dbg`.

---

# 10. Refatorações estruturais

## E-1 · MÉDIA — `Api.Scheduling` faz cinco coisas

[`scheduling.ex`](../api/lib/api/scheduling.ex) — 1733 linhas, **38 funções públicas** + 21 code
interfaces, com cinco responsabilidades convivendo:

1. escrita e ciclo de vida da agenda (`schedule_appointment`, `transition_appointment`, `transition_participant`);
2. leitura de tela (`load_agenda`, `load_counts`, `load_visible_appointment`, `list_patient_sessions`);
3. **relatórios** (`load_summary` + 9 privadas `summary_*`);
4. expediente/exceções (`update_clinic_hours`, `update_professional_hours`, `future_conflicts`, as 8 de exceção);
5. helpers de pacote (`list_held_sessions`, `list_package_attendances`, `list_sessions_including_held`, `clinic_holidays`).

O bloco de relatórios (~220 linhas, zero acoplamento com o resto além de `list_appointments!`) sai
inteiro para `Api.Scheduling.Reports` sem tocar em nada. O de expediente sai para
`Api.Scheduling.Hours`. Os helpers de pacote são superfície pública **só para `Api.Packages`** —
cabem num `Api.Scheduling.PackageBridge` explícito.

**Nota importante:** as funções em si estão **bem fatoradas** — a maior tem ~35 linhas. O problema é
o número de responsabilidades no módulo, não o tamanho das funções. Vale o mesmo para `packages.ex`
(780), `bulk.ex` (618), `fanout.ex` (610).

## E-2 · MÉDIA — Um `Api.Repo.unwrap/1` fecha uma classe inteira de bug

O padrão `{:ok, x} = with_clinic(…)` / `|> elem(1)` aparece em **11 lugares** (**B-10**), com
semântica divergente entre eles. Um helper único que case `{:ok, v} -> v` e
`{:error, e} -> {:error, e}` (ou levante com mensagem útil) elimina os `MatchError` silenciosos e o
`ArithmeticError` do `ReminderJob`.

## E-3 · MÉDIA — Ampliar o alcance declarado do gate `:rls`

[`migrations.md` §3](../.claude/rules/migrations.md) já registra que o gate não pega leitura interna
posterior no mesmo fluxo (débito **D-15**). Esta auditoria acrescenta duas coisas concretas:

1. ele também **não pega leitura depois de escrita dentro do mesmo job** (**T-1** — o cenário rodou
   verde);
2. o modo de falha real é **exceção**, não lista vazia (**T-0**), o que torna a asserção "não-vazio"
   do arquivo insuficiente.

Um teste que rode as leituras críticas **com a GUC explicitamente zerada logo antes** (o `sem_guc()`
já existe, [`rls_smoke_test.exs:156`](../api/test/api/rls_smoke_test.exs#L156)) e afirme que **não
levanta** cobriria a classe.

## E-4 · BAIXA — Nomes e docs que mentem

Quatro casos onde o nome ou o doc contradiz o código:

- `registrar_evento!/3` — o `!` não levanta (**B-5**);
- o `@doc` de `Message.entregue?/1` — cita um consumidor que já foi removido (**M-1**);
- o `@doc` de `Api.Repo.on_transaction_begin/1` — sugere alcance que não existe (**T-0**);
- o moduledoc de `Waitlist.find_slots/2` — afirma **não haver recorte por papel** enquanto
  [`waitlist.ex:238-239`](../api/lib/api/waitlist.ex#L238) lê os profissionais com `scope:`, e
  `Professional` tem `prepare OwnProfessionalOnly` global
  ([`professional.ex:161-169`](../api/lib/api/directory/professional.ex#L161)). **Efeito real:** um
  `profissional` chamando `GET /waitlist/slots` recebe `[]` para todo item cuja preferência não o
  inclua — subnotificação silenciosa —, e o `WaitlistChannel` (`:18-20`) afirma o oposto. Decidir e
  alinhar os três textos ao código, ou o código aos textos.

---

# 11. Configuração e observabilidade

## C-1 · MÉDIA — Fail-fast existe para 3 variáveis e falta nas que decidem redirect e origem do WebSocket

[`runtime.exs:220-280`](../api/config/runtime.exs#L220)

`SECRET_KEY_BASE`, `DATABASE_URL` e `TOKEN_SIGNING_SECRET` levantam se faltarem. As que decidem para
onde o login redireciona e qual origem o socket aceita, não:

```elixir
host = System.get_env("PHX_HOST") || "example.com"                # :227
web_app_url = System.get_env("WEB_APP_URL") || "https://#{host}"  # :273
config :api, ApiWeb.Endpoint, check_origin: [web_app_url]         # :280
```

Com as duas ausentes em produção a aplicação **sobe normalmente** e: todo magic link redireciona para
`https://example.com`, e o `check_origin` do WebSocket vira `["https://example.com"]` — **tempo real
morto, com tudo verde no health check**. É exatamente o modo de falha que o comentário das linhas
276-279 descreve e não protege. O mesmo vale para `GOOGLE_REDIRECT_URI`, com default
`http://localhost:5173/auth` (`:31`) **em todos os ambientes, inclusive prod**.

O `compose.dokploy.yml` já adotou o remédio certo para o Resend
(`RESEND_API_KEY: ${…:?sem ela nenhum e-mail sai}`, `:174`) e escreveu a justificativa. `PHX_HOST` e
`WEB_APP_URL` não ganharam nem o `raise` nem o `:?`.

## O-1 · MÉDIA — O log da requisição não tem o IP do cliente

[`request_logger.ex:81-86`](../api/lib/api_web/request_logger.ex#L81) e `config/prod.exs:29-42`

A linha carrega `method`, `route`, `status`, `duration_ms`, `request_id`, `trace_id`, `clinic_id`,
`actor_id`. **Não carrega IP.** `ApiWeb.ClientIp.get/1` já resolve o IP corretamente e é usado **só**
como chave de rate limit.

Efeito direto: para um 401 ou 429 anônimo — o caso de brute-force no magic link e o do webhook sem
assinatura — o log não tem **nenhum** identificador de origem (`actor_id` e `clinic_id` são nulos). A
pergunta operacional "quem está batendo na porta" não tem resposta na API. Combinado com **L-5**, a
defesa contra brute-force funciona e é inauditável.

**Correção:** `client_ip: ApiWeb.ClientIp.get(conn)` no metadata de `registrar/2` e na lista de
`prod.exs`. Cardinalidade alta, mas o Loki indexa por label, não por campo do JSON — é campo, não
label.

## O-2 · BAIXA — Ruído de exportador OTLP no nível `:info`

Observado no container: `[info] OTLP grpc export failed with error: {:shutdown, :nxdomain}` repetido
a cada poucos segundos. Em dev é incômodo. Em produção, com `OTEL_EXPORTER_OTLP_ENDPOINT` apontando
para um Alloy caído, vira volume constante no Loki em `:info` — o sinal de que a observabilidade
quebrou, afogado no mesmo canal que ele deveria alertar. Vale throttle, ou `:warning` com dedup.

## O-3 — O que está certo na observabilidade

O `x-request-id` chega na resposta (confirmado); o `trace_id` é carimbado no processo inteiro pelo
plug, não só na linha final; o `rescue` no handler de telemetria
([`request_logger.ex:49-57`](../api/lib/api_web/request_logger.ex#L49)) evita que uma linha ruim
desanexe o logger inteiro — que é o modo de falha mais silencioso possível; o filtro de health check
normaliza a barra final. O buraco é o **formato de token** (**S-2**), não o mecanismo.

---

# 12. Relação com débitos já registrados

Estes achados **tocam** débitos aceitos em [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md) e não
devem ser recontados como novos:

| Achado | Débito | Relação |
| --- | --- | --- |
| **T-1**, **E-3** | **D-15** — o gate `:rls` não alcança leitura interna | T-1 é uma instância nova da classe; E-3 amplia o alcance conhecido do débito com dois fatos medidos |
| **L-4** | **D-16** — `x-forwarded-for` confiado pelo primeiro item | Ângulo novo: no **default vigente do compose** nenhum header é confiável, não só a escolha de qual confiar |
| **S-9**, **L-1** | **D-8** — emissão de URL assinada sem rate limit | Mesma família (borda sem teto) |

---

# 13. Próximos passos

1. **Triar** este documento com decisão humana: o que vira correção agora, o que vira débito aceito
   em [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md), o que é descartado.
2. Para cada item aceito, **o teste vermelho vem primeiro** — CLAUDE.md, sem exceção. Os achados
   B-1, T-0 e T-1 já vêm com roteiro de reprodução executável.
3. **T-1 não se prova com `mix test`, nem com `mix test --only rls`** (medido). Prova-se por `psql`
   sob o role `cinetra_app`, conforme [`migrations.md` §3](../.claude/rules/migrations.md).
4. **T-0** exige decisão antes de código: uniformizar as policies para uma das duas semânticas, e só
   então corrigir os cinco textos que a descrevem.
