# 97 — Execução da auditoria do backend (doc 96): o que entrou

**Data:** 2026-07-31, com a **quarta leva em 2026-08-01** (§7)
· **Base:** [`96-auditoria-backend.md`](96-auditoria-backend.md) (47 achados) · **Branch:** `develop`

Este documento registra as correções dos achados do doc 96. As §§3–6 são das **duas primeiras
levas** (2026-07-31) e ficaram como foram escritas; a **§7 é a leva final** (2026-08-01), que fechou
o que restava — inclusive a verificação pendente da §5.

> **Leia a §7 antes da §4.** A §4 lista como aberto o que a §7 fechou depois, e a tabela §4.1 chega
> a contradizer a §4.0-bis sobre T-0 — ela é o retrato de 31/07, não do estado atual. O placar de
> hoje está na §7.1.

Toda correção seguiu a regra do [CLAUDE.md](../CLAUDE.md): teste vermelho antes do conserto. Onde o
vermelho foi **provado por execução**, a saída está colada.

---

## 1. Estado dos gates

| Gate | Antes (31/07) | Depois das 2 levas | Depois da leva final (§7) |
| --- | --- | --- | --- |
| `mix compile --force --warnings-as-errors` | ✅ | ✅ | ✅ |
| `mix format --check-formatted` | ✅ | ✅ | ✅ |
| `mix test` | ⚠️ **1704 testes, 4 falhas** (ver §2) | ✅ 1714 · 0 falhas | ✅ **1759 · 0 falhas** |
| `mix test --only rls` (como `cinetra_app`) | ✅ | ✅ | ✅ |
| `mix coveralls` (piso 80) | ✅ | ✅ 89,9% | ✅ **89,9%** |
| `npm run check` (web) | ✅ | ✅ | ✅ **0 erros** |
| `npm run coverage` (web) | ✅ | ✅ | ✅ **2424 testes** |

Diff das duas primeiras levas: **58 arquivos, +1144 −280**. Da leva final: **89 arquivos alterados
(+2306 −1121) e 9 arquivos novos** — inclui o web, por causa de H-5.

---

## 2. O achado que não estava no doc 96: a suíte reprovava dois dias por semana

Não estava na lista porque a auditoria rodou numa quinta. Ao rodar o baseline numa **sexta**, 4
testes falharam em 3 arquivos, todos com a mesma mensagem:

```
** (MatchError) ... "Esse horário está fora do expediente (08:00–12:00)."
```

A causa não era o relógio — era o **calendário**. `Api.Generators.amanha_as/2` devolvia
literalmente "amanhã", e o seed do onboard abre **seg–sex**. Rodando numa sexta, "amanhã" caía no
sábado e toda escrita de agenda era recusada. O CI de sexta e de sábado reprovava por motivo que
não tinha nada a ver com a regra sob teste.

**Provado** revertendo minhas mudanças e rodando o mesmo arquivo: 2 falhas idênticas, sem nenhuma
alteração minha no repositório.

**Conserto:** a fábrica virou `proximo_dia_util_as/2` — pula sábado e domingo, e o **nome passa a
dizer a verdade** (é o tema E-4 do próprio doc 96). 10 call sites atualizados em 5 arquivos.

> Isto tem consequência para a leitura do doc 96: a afirmação "todos os gates verdes, e nenhum dos
> 47 achados é pego por gate nenhum" era verdadeira **na quinta**. A suíte tinha uma quinta falha
> estrutural que só aparecia no fim de semana.

---

## 3. Primeira leva (16 itens)

### 3.1 Segurança

**S-1 · ALTA — dado bancário e documento do profissional deixaram de vazar**
`professional.ex` (novo bloco `field_policies`) + `professionals_controller.ex`

O recorte foi feito **no recurso**, não só no serializador: `@ficha_contratual` (20 campos — CPF,
RG, CNPJ, razão social, banco/agência/conta/PIX, endereço, emergência) só é legível por
`owner`/`admin`, ou pelo próprio profissional (a preparation `OwnProfessionalOnly` já garante, de
forma fail-closed, que ele só enxerga a própria linha).

A fronteira **não repete a regra de papel** — ela apenas omite o que o domínio recusou:

```elixir
|> Map.reject(fn {_campo, valor} -> match?(%Ash.ForbiddenField{}, valor) end)
```

Duplicar o RBAC na fronteira criaria duas verdades que envelhecem em ritmos diferentes — foi assim
que o vazamento nasceu.

**Vermelho provado:** `vazou cpf para a recepção: "11144477735"`.
**3 testes novos:** recepção não vê; owner vê; o próprio profissional vê a dele (os dois últimos
são o controle contra excesso de restrição).

**S-2 · ALTA — token de resposta do paciente não vai mais para o log**
`request_logger.ex`

A barreira reconhecia UUID e número; o `Phoenix.Token` de `/api/reply/:token` não casava com
nenhum dos dois e saía inteiro — credencial de 30 dias num log com 30 dias de retenção.

Em vez de acrescentar mais um regex de formato (lista que envelhece), entrou o corte por
**segmento opaco**: acima de 32 caracteres vira `:token`. O piso fica acima do maior segmento
literal do router (`sign-out-everywhere`, 19) e abaixo de qualquer token emitido. UUID nunca chega
lá — o `identificador?/1` casa antes e devolve `:id`, que é o rótulo mais útil.

**2 testes novos**, incluindo o que impede o corte de comer nome de rota longo.

**S-8 · BAIXA — cookie de sessão com `Secure` e `max_age`** — `endpoint.ex`. Faltavam por omissão
do gerador, não por decisão. Não quebra o BFF: a comunicação é server-to-server e nunca lê esse
cookie pelo browser.

**S-10 · BAIXA — o alerta de forja de token virou acionável** — `verify_token_subject.ex`. Ganhou
`client_ip`, rota, método e user-agent. O `jti` **não** entrou nesta leva (ver §4). O `sub`
deliberadamente fica de fora: ele identifica o titular, e o alvo de uma forja não é
necessariamente quem a fez.

### 3.2 Multi-tenancy

**T-1 · ALTA — `Sessions.segura/3` passou a ler sob GUC** — `sessions.ex`

A leitura acontece **depois** do commit do `schedule_appointment`, quando o `SET LOCAL` daquela
transação já morreu. Sem GUC, sob `cinetra_app`, a RLS **levanta** `22P02`. Envolvida em
`Api.Tenancy.in_clinic/2`.

⚠️ **Este conserto não é provado pela suíte** — nem por `mix test --only rls`. O sandbox roda o
teste inteiro numa transação, e a GUC da escrita anterior fica pendurada, cobrindo a leitura de
graça. É a limitação do débito **D-15**, ampliada no doc 96 (leitura **depois de escrita, no mesmo
job**). A prova exige `psql` sob o role restrito, conforme
[`migrations.md` §3](../.claude/rules/migrations.md). **Fica como verificação pendente.**

### 3.3 Bugs

**B-1 · ALTA — a sessão paga não vira mais órfã** — `cascade_to_attendances.ex`

A cascata lia as presenças com `Ash.load!`, que passa pela preparation `HideHeldAttendances`. A
cascata irmã `RemoveParticipants` já abria a porta com `include_held`; esta não. Cancelar um bloco
deixava a presença segurada viva (`:prevista`) pendurada num bloco `:cancelado`, e o
`resume_package` não a recuperava — **a sessão paga desaparecia** e a ficha seguia desenhando a
bolinha como "segurada" para sempre.

**Vermelho provado:** `presença sobrou prevista (pkg_hold=true) num bloco cancelado`.

**B-2 · ALTA — as notificações de equipe voltaram a ter nome** — `fanout.ex`

`Accounts.get_user/2` é code interface **não-bang** e devolve `{:ok, %User{}}`; o `case` casava
contra `%{nome: nome}`, então o fallback era o único caminho. Conserto de uma linha.

**Vermelho provado:** `"Um novo membro entrou na clínica como recepção."`

**B-3 · ALTA — o retry não reenvia mais mensagem paga** — `send_job.ex`

O resultado da transação de gravação era descartado e o `:ok` vinha incondicional. Agora ele é
casado, e — decisão explícita — a falha ao **gravar** não propaga: se propagasse, o Oban
retentaria, a mensagem ainda estaria `:pendente`, o guard não pegaria e o transporte rodaria de
novo (**segunda mensagem paga**). Entre reenviar ao paciente e registrar o desencontro no log, o
log é o mal menor. O que sobra é um `Logger.error` com `provider_message_id`, alto o bastante para
virar chamado.

**B-4 · ALTA — a mensagem não trava mais a fila para sempre** — `dispatch.ex`

O `Oban.insert` era descartado. Sem job, a linha ficava `:pendente` e `na_fila?/2` passava a
recusar toda tentativa futura com `{:skip, :ja_na_fila}` — sem cron, sem botão de reenviar. Agora
o erro marca `:falhou`, que é o que devolve o controle à recepção.

**B-5 · ALTA — a trilha do anexo faz o que o doc promete** — `acesso.ex` + `records.ex`

`registrar_evento!/3` era clone **byte a byte** do sem bang, e o `gravar/7` nunca levantava — o
`@doc` de `attachment_download/2` prometia um fail-closed que não existia. Entrou
`Acesso.anexo_tocado!/3`, com `propagar?: true`, e o download virou um `with`: a URL só vai para o
cliente **depois** de a trilha gravar. Os demais eventos seguem best-effort, agora de forma
deliberada e documentada.

**B-6 · ALTA — `adjust_grade/3` virou atômico** — `packages.ex`

A reordenação anterior fechou a recusa previsível; a atomicidade continuava aberta. Cancelamentos
e `enqueue_from` foram para dentro de `Api.Repo.transaction`, o mesmo desenho que
`resume_package/2` já usava. `enqueue_from` fica **dentro** de propósito: se a transação aborta, o
job não deve existir, ou materializaria sobre uma grade que voltou atrás.

**B-7 · ALTA — a dedup anti-abuso parou de amplificar o abuso** — `acesso.ex` + `tenant_scope.ex`

A dedup casa por `label`, e o label era o path **cru, com os UUIDs dentro** — então ela funcionava
para rota fixa e nunca casava justamente na varredura por IDOR, que é o que o evento existe para
detectar. Uma linha por request na tabela que mais cresce, mais uma query síncrona por 403.

Agora o `label` é a rota normalizada (`/api/patients/:id`) e o caminho cru vai em
`meta["caminho"]`. A normalização mora na **fronteira**, não no domínio: `Api.Audit` não deve saber
o que é um path do Phoenix.

**Vermelho provado:** com o caminho antigo, 100 ids diferentes → 100 linhas.

**B-9/B-10 (parcial) · MÉDIA — o `SendJob` deixou de engolir erro de leitura** — `send_job.ex`

O `|> elem(1)` apagava a diferença entre "não existe" e "não consegui ler": erro de banco/RLS
virava job `completed`, sem envio, sem retry e sem log. Agora `{:ok, nil}` e `{:error, _}` são
casos distintos, e o erro devolve `{:error, _}` — que é o que faz o Oban retentar.

### 3.4 Observabilidade

**O-1 · MÉDIA — `client_ip` na linha de requisição** — `request_logger.ex` + `prod.exs`. É o único
identificador de origem que existe num 401/429 **anônimo**, onde `clinic_id` e `actor_id` são
nulos por definição. No Loki é campo, não label — não infla o índice.

**L-5 · BAIXA — o 429 deixa rastro** — `rate_limit.ex`. Antes a negação respondia e `halt`ava sem
log nenhum: a defesa contra brute-force funcionava e era inauditável.

---

## 3.5 Segunda leva (20 itens)

### Segurança

| Achado | O que entrou |
| --- | --- |
| **S-3** ALTA | A poda de atributo do Alloy **saiu de comentário e passou a rodar**, antes do lote. `url.path` (o `patient_id` cru) e — o que nem estava no exemplo — **`url.query`, onde viaja o token do magic link**. O exportador ainda está inerte (`OTEL_EXPORTER_OTLP_ENDPOINT` vazio), e é por isso que a poda entra agora: quando ligarem a variável, ela já está de pé. |
| **S-4** MÉDIA | Plug `ApiWeb.Plugs.RequireScope` + pipeline `:require_scope` no escopo `/api/json`, o único sem guarda de controller. Redundante em toda rota que já tem guarda — e é por isso que é barato. |
| **S-6** MÉDIA | `handle_in("offering")` valida o UUID e **casa** o retorno de `Presence.track/3`. Fechava dois furos: amplificação de broadcast por chave arbitrária, e `MatchError` derrubando o canal quando o mesmo `offering` chegava duas vezes. |
| **S-9** BAIXA | `TenantScope.no_store/1`, aplicado à ficha completa do paciente e à URL assinada do laudo. O default do `Plug.Session` (`must-revalidate`) **autoriza armazenar**. |

### Contrato HTTP

| Achado | O que entrou |
| --- | --- |
| **H-1** MÉDIA | `TenantScope.bad_request/1` virou público — era copiado à mão em `PackagesController` e `AttachmentsController`. |
| **H-2** MÉDIA | **Um** corpo de 401 na API inteira (`unauthenticated`). O `AuthController` reimplementava o seu em 5 call sites e o `VerifyTokenSubject` montava um terceiro. A fixture do BFF que fixava `not_authenticated` foi atualizada — ela não é lógica, o BFF só olha o status. |
| **H-3** MÉDIA | `GET /patients/:id/packages` resolve o paciente antes de listar. Id de outra clínica devolvia **200 com lista vazia**; id malformado virava 400 com corpo de outro formato. |
| **H-4** MÉDIA | `Packages.fetch_patient_package/3` (não-bang, no molde de `fetch_clinic_patient/3`) substitui o único ponto do projeto que resolvia id por função `!`. |
| **H-6** BAIXA | "Sem clínica ativa" virou **422**. A régua do projeto reserva 409 a concorrência, e está escrita no próprio `TenantScope`. |
| **H-7** BAIXA | `switch-tenant` para clínica sem vínculo virou **404**. O ator não está proibido de nada — o alvo não existe para ele. |
| **H-9** BAIXA | `POST /appointments/:id/messages` só responde **201** quando alguma mensagem nasceu; se todos caíram em `{:skip, _}`, é 200. |

### Rate limit, performance e Ash

| Achado | O que entrou |
| --- | --- |
| **P-1** ALTA | O expediente por `(prof, dia)` é composto **uma vez por request**, ao lado do `appts_index`, em vez de por item da fila. Cai de `entries × N × 14` para `N × 14` — com a página cheia eram **42.000 composições idênticas**. Junto, o `acc ++ day_slots` (append quadrático) virou acumulação invertida. |
| **L-1** MÉDIA | Teto de corpo **próprio** para webhook (256 KB) no `CacheRawBody`. É o único caminho de escrita público e estava fora dos dois estágios de rate limit, retendo até 8 MB por requisição anônima. |
| **L-4** MÉDIA | O `x-forwarded-for` passa a ser contado **a partir do fim**, com o número de saltos confiáveis em config explícita (`:trusted_proxy_hops`, default 1 = Traefik). Ler o primeiro item entregava a chave de rate limit ao atacante. **Nuance que a auditoria não tinha:** "último elemento" só vale com um salto — com dois, o cliente é o penúltimo. Por isso virou configuração, com teste para os dois casos. |
| **P-5** MÉDIA | `Poda.clinicas/0` virou `Ash.stream!` — é chamada por cron que roda **288×/dia**. |
| **P-7** MÉDIA | `unique` do `SlotOpenedJob` ganhou `keys: [:clinic_id, :appointment_id]`. Com `args` inteiro, o `actor_id` fazia dois usuários gerarem **duas notificações do mesmo fato**. |
| **A-1** MÉDIA | `AvailabilityRule` trocou `authorize_if always()` por `accessing_from(WaitlistEntry, :rules)` — a invariante real, em vez de uma afirmação sobre quem chama. |
| **A-3** MÉDIA | `professional_id` do `AvailabilityController` é validado como UUID antes de ir para `Ash.Query.filter` sobre coluna `uuid`. |

### Tenancy, reúso, código morto e config

| Achado | O que entrou |
| --- | --- |
| **T-2** MÉDIA | `change Api.Tenancy.SetTenantGuc` nas ações `:registrar` e `:revogar` de `OptOut` — eram as únicas escritas do projeto sem ele, numa tabela que **tem RLS** apesar do comentário que diz o contrário. |
| **R-1/R-2** MÉDIA | `Api.Params.get/2` volta a ter uma definição só (a cópia dentro de `Api.Scheduling` tinha ressuscitado), e `uuid?/1` — idêntico em `Scheduling` e `Packages.Bulk` — foi para `Api.Params`. |
| **M-1/M-3** MÉDIA | Removidos: `Audit.max_rotulo/0`, `Pagination.default_limit/0`, `ReplyToken.max_age/0`, `Message.entregue?/1`, 5 code interfaces sem chamador, o `ApiWeb.Telemetry.metrics/0` de 40 linhas (que **duplicava** o que o PromEx exporta), e o scaffolding `Plug.Static`/`Plug.MethodOverride`. Cada símbolo confirmado por grep antes de sair. |
| **C-1** MÉDIA | `PHX_HOST` e `WEB_APP_URL` passam a **levantar** em produção, como `SECRET_KEY_BASE`. Com o default `example.com`, a app subia verde com magic link quebrado e WebSocket morto. `GOOGLE_REDIRECT_URI` perdeu o default de localhost em prod. |

---

## 4. O que **não** entrou (11), e por quê

### 4.0 Tentados e **revertidos de propósito**

**B-12 · MÉDIA — corrida na capacidade da turma.** Cheguei a aplicar `Ash.Query.lock(:for_update)`
e **revertí**: validação do Ash roda **antes** da transação da ação, e `count_participants/2` abre
transação própria — o lock seria liberado no commit dela, antes da escrita. Um lock ali seria
*aparência* de conserto. Fechar de verdade exige mover a checagem para um `before_action` ou uma
constraint no banco; as duas mexem no contrato de erro da ação. **A limitação ficou escrita no
código**, no lugar onde o próximo leitor vai procurar.

**P-3 · MÉDIA — a transação da poda.** O `LIMIT 5000` reduz o `DELETE`, não a transação: a recursão
acontece dentro do `with_clinic` de `por_clinica/1`. Inverter muda a assinatura de `por_clinica/1` e
os quatro chamadores. Documentado no código, não corrigido às pressas.

### 4.0-bis Terceira leva: T-0 entrou; B-8 foi implementado e **revertido**

**T-0 · ALTA — RESOLVIDO.** Migration `20260731120000_rls_fail_closed_uniforme`: `nullif` nas 15
tabelas que liam a GUC crua. **A decisão foi manter `nullif`, não removê-lo**, contra a intuição
inicial — porque o projeto já havia raciocinado isso por escrito em
`20260728011500_messaging_rls.exs`, após incidente ao vivo, e porque `message_opt_outs` **depende**
disso (as linhas globais precisam ser legíveis sem tenant).

**Provado ao vivo, sob `cinetra_app`:**

```
-- sem GUC
select count(*) from appointments;            →  0        (antes: ERROR 22P02)
-- com a GUC setada e COMMITADA (o caso do pool reciclado)
select nullif(current_setting('cinetra.clinic_id', true),'');  →  <vazia>
select count(*) from appointments;            →  0        (antes: ERROR 22P02)
```

Os cinco textos que descreviam "zero linhas, silenciosamente" **passaram a ser verdade** — não
precisaram ser reescritos. Teste de regressão em `rls_smoke_test.exs`, varrendo as 17 tabelas com a
GUC explicitamente vazia e exigindo que **nenhuma levante**. Isso também torna a verificação
pendente de **T-1** (§5) inequívoca: o esperado é 0 linhas.

**S-5 · MÉDIA — fechado por outro caminho.** RLS por `clinic_id` em `memberships` é impossível: a
tabela é lida **cross-clinic** por desenho (o `/me` lista todos os vínculos; o `LoadScope` resolve o
ativo **antes** de existir tenant). Uma policy por tenant derrubaria o login. Entrou a segunda
camada que faltava de fato: `MembersController.fetch/2` compara `clinic_id` explicitamente, e
id de outra clínica passa a dar **404** em vez de 403 — fechando também o vazamento marginal que
distinguia "existe numa clínica que você conhece" de "não existe".

**B-8 · MÉDIA — implementado, medido e REVERTIDO.** O índice único parcial
`(attendance_id, kind) WHERE status = 'pendente'` foi criado, e dois testes o derrubaram — nesta
ordem, e cada um ensinou uma coisa:

1. `"remarcar duas vezes avisa duas vezes"` — o índice precisava do recorte por `kind`, porque
   remarcação e cancelamento estão **fora** de `@com_barreira` de propósito (cada um anuncia um
   fato novo). Corrigido: `AND kind IN ('confirmacao','lembrete')`.
2. `SendJobTest` (6 testes) — e este é o que mata a proposta: criar o agendamento já enfileira uma
   confirmação automática, e `dispatch/4` (o **reenvio manual da recepção**) grava uma SEGUNDA
   pendente para a mesma presença. A barreira não bloqueia esse caminho.

Conclusão: **"duas pendentes do mesmo tipo" não é estado inválido hoje**. O índice proposto pela
auditoria proíbe mais do que a regra de domínio, e a premissa de B-8 estava incompleta. Fechar a
corrida de verdade exige antes decidir se o reenvio manual **substitui** a pendente em vez de somar
— pergunta de produto. A migration foi removida; a análise ficou escrita em `dispatch.ex`, no ponto
exato.

### 4.1 Exigem decisão humana ou migration

Nada abaixo foi tentado pela metade — todos estão intactos como o doc 96 os descreve.

### 4.1 Exigem decisão humana antes de código

| Achado | Decisão pendente |
| --- | --- |
| **T-0** (ALTA) | Uniformizar a semântica do RLS exige escolher **uma** das duas: `NULLIF` em todas as policies (sempre 0 linhas) ou em nenhuma (sempre exceção). Hoje 15 tabelas levantam e 2 devolvem vazio. É migration em 17 tabelas mais a correção de 5 textos — e a escolha muda o modo de falha de **todo** o sistema em produção. Não é decisão de implementador. |
| **S-5** (MÉDIA) | RLS em `memberships` esbarra no `/me`, que lê vínculos **cross-clinic** sem tenant. Ou se abre exceção documentada, ou se muda o `/me`. |
| **B-5** (feito) → **S-7** (MÉDIA) | Replay de webhook Zernio pede tabela de eventos vistos (nova migration) ou timestamp na assinatura — que depende do que a Zernio de fato envia, e isso não está documentado no repositório. |
| **M-4** (BAIXA) | As 3 APIs de domínio sem rota: apagar ou expor é decisão de produto. |

### 4.2 Exigem migration (e portanto janela de deploy)

**B-8** (índice único parcial em `messages`), **S-5**, **T-0**. Nenhuma foi gerada: o projeto exige
`mix ash.codegen`, e migration em tabela quente pede o cuidado de
[`migrations.md` §2](../.claude/rules/migrations.md) (`CONCURRENTLY`).

### 4.3 Não alcançados — sem impedimento, só escopo

- **B-11** — escrita Ash dentro de transação externa (4 pontos; nos 3 últimos o `with_clinic`
  externo é redundante, porque a ação já carrega `SetTenantGuc`).
- **B-13** — atomicidade de `archive_package/2` e `remove_session/2`.
- **H-5** — os 17 campos `camelCase` em dois controllers, contra ~200 `snake_case` no resto. É
  mudança de contrato visível ao BFF e merece ser feita junto com ele.
- **H-8** — a forma do `page` (duas das quatro montadas **no domínio**).
- **H-10** — o `401 + Location` decorativo.
- **L-2** — o estágio de borda como plug de endpoint (hoje o `Plug.Parsers` roda antes dele).
- **L-3** — rate limit no `join` de canal.
- **P-2** — `who_fits/5` sem teto de página. **P-4** — N+1 em `ja_confirmada?/1`.
  **P-6** — `future_conflicts/2` dentro da transação de escrita. **P-8** — leituras redundantes.
- **A-4/A-5** — query crua onde havia code interface; upsert manual em `register_opt_out!`.
- **R-3/R-4** — as quatro implementações de "só os dígitos" e as repetições menores.
- **M-2** — a superfície AshJsonApi servindo `Api.Meta` vazio (agora protegida por `RequireScope`,
  mas ainda montada). **M-4** — as 3 APIs de domínio sem rota (decisão de produto).
- **E-1** — quebrar `Api.Scheduling` (1733 linhas, cinco responsabilidades). **E-2** —
  `Repo.unwrap/1`. **E-3** — ampliar o alcance declarado do gate `:rls`. **E-4** — o moduledoc de
  `Waitlist.find_slots/2`, que ainda contradiz o código sobre recorte por papel.
- **O-2** — o ruído do exportador OTLP em `:info`.

## 5. Verificação que ficou pendente

**T-1 não está provado.** A correção é a certa e está documentada, mas nem `mix test` nem
`mix test --only rls` a exercitam — pelo motivo que o **D-15** já registra. Provar exige, com o
stack de pé:

```bash
# sem a GUC: tem de dar 0 (ou levantar 22P02, conforme T-0 for decidido)
docker compose exec -T -e PGPASSWORD=cinetra_app db \
  psql -U cinetra_app -d cinetra_dev -c "select count(*) from appointments;"
```

Enquanto **T-0** não for decidido, o resultado esperado desse comando é ambíguo — e essa
ambiguidade **é** o achado T-0.

---

## 6. Próximo passo sugerido (escrito em 31/07 — **todos foram feitos**, ver §7)

1. **Decidir T-0.** É o que destrava T-1 (a verificação da §5), S-5, e a redação de cinco
   documentos que hoje descrevem errado o modo de falha do RLS. Não é decisão de implementador:
   muda o comportamento de **todo** o sistema em produção.
2. **B-8 e S-5**, que vêm juntos porque são migration — e migration em tabela quente pede o
   cuidado de [`migrations.md` §2](../.claude/rules/migrations.md).
3. **B-12**, com o desenho certo (`before_action` ou constraint), agora que a limitação do
   caminho errado está documentada no código.
4. **E-1** (quebrar `Api.Scheduling`), que é a maior dívida estrutural e não tem risco funcional —
   o bloco de relatórios sai inteiro, sem tocar em mais nada.

---

# 7. Leva final (2026-08-01) — o que sobrava

Entre a leva 2 e esta, cinco commits fecharam mais achados sem atualizar este documento: **B-8**
(`8dbb055` — a reversão descrita na §4.0-bis era diagnóstico errado), **M-4** (`d6e12a4`), **E-1
parcial** (`ac914c7` — os relatórios saem, 1723 → 1497 linhas), **E-4** e **R-3** (`485415e`),
**P-2** e **B-12** (`1cf7eb9`), e **P-4**, que deixou de existir junto com o gatilho em `5f1c381`.
**B-14** também já estava consertado. Esta leva partiu daí.

## 7.1 Placar

| Situação | Achados |
| --- | --- |
| **Corrigidos** (47 no total) | todos, menos os quatro abaixo |
| **Débito aceito, registrado** | **B-12** (D-22) · **P-6** (D-23) |
| **Refutado pela execução** | **A-4 parcial** (dois dos quatro pontos — §7.7) |
| **Medível só com volume** | **P-9** (índices — depende do teste de carga, doc 98) |

## 7.2 T-1: provado ao vivo — a §5 está fechada

Com **T-0** resolvido (o `nullif` uniforme), o resultado esperado deixou de ser ambíguo. Sob
`cinetra_app`, com o stack de pé:

```
sem GUC   : appointments 0 · professionals 0 · messages 0     (nenhuma levanta)
com a GUC : appointments 30  = o mesmo que o superusuário lê para a mesma clínica
```

O **controle positivo importa tanto quanto o negativo**: sem ele, "0 linhas" não distingue *RLS
funcionando* de *tabela vazia*. Os dois comandos e essa lição entraram na
[`migrations.md` §3](../.claude/rules/migrations.md), junto com **E-3** — o alcance declarado do
gate `:rls` passou a incluir a segunda cegueira medida (leitura **depois de escrita no mesmo job**)
e o fato de o modo de falha ser hoje 0 linhas em toda tabela.

## 7.3 Os dois com risco de dado errado

**A-5 · o opt-out virou upsert de verdade.** O `if opted_out?, do: :ok, else: gravar` era
*check-then-act*: duas reentregas simultâneas do mesmo evento (a Zernio manda até 7× em 24 h) leem
"ainda não" as duas e gravam as duas. A ação `:registrar` ganhou `upsert?` sobre uma identity nova,
`:vigente_por_destino` — `(canal, destino, clinic_id)` **recortada nos vigentes** e com
`nils_distinct? false`.

As duas escolhas são o ponto:

- o recorte `where is_nil(revogado_em)` preserva o ciclo legítimo *parar → voltar → parar de novo*.
  Um índice único simples ou proibiria a segunda parada ou, num upsert que sobrescrevesse,
  **apagaria a revogação** — e este recurso não tem `AshPaperTrail` justamente porque a linha *é* o
  histórico;
- `nils_distinct? false` porque `clinic_id` nulo é o caso **normal** aqui (opt-out global, C10/C11),
  não a exceção. No default do Postgres dois nulos não colidem, e a constraint não pegaria
  justamente o caso que existe.

**Vermelho provado:** duas gravações do mesmo destino produziam duas linhas vigentes.

**S-7 · replay de webhook.** O argumento de que replay era inócuo tinha um furo que não era um
evento novo — era uma ação **do outro lado**: `revoke_opt_out/3`. Entre o `SAIR` original e a
reentrega cabe uma revogação, e o replay a desfaz. O sintoma para quem usa é o pior possível: o
paciente pede no balcão para voltar a receber, a recepção reativa, e ele para de receber de novo,
sem erro em lugar nenhum.

Entrou `Api.Messaging.WebhookEvent` — corpos já vistos, chaveados pelo **SHA-256 do corpo cru**. A
chave é o corpo, e não um id do provider, porque não depende de documentação que não temos (a Zernio
não promete campo de id). A barreira mora nos **dois** controllers de webhook, e é consultada
**depois** de processar: marcar antes faria uma falha no processamento consumir a única chance de
reentrega. O Resend também a atravessa, embora o Svix já valide timestamp — a propriedade "um evento
é processado uma vez" não deve depender de qual provider mandou.

Junto veio a quarta poda da madrugada (`PruneWebhookEvents`, 03:45), e uma limitação aceita e
escrita: **um payload guardado por mais de um ano volta a funcionar**. O conserto definitivo não
está do nosso lado — exige a Zernio assinar timestamp.

**Vermelho provado:** `o replay ressilenciou o paciente (doc 96, S-7)`.

## 7.4 B-13 — o pacote vendido com N e zero na agenda

O `−1 sessão` fazia duas escritas sem transação: cancelava a sessão e só então baixava o total.
Falhar não era hipótese remota — `total` tem `min: 1` no recurso, então num pacote de **uma** sessão
o segundo passo *sempre* recusava. Sobrava o pior estado do domínio, o mesmo que o comentário de
`somar_sessao/3` diz ter consertado noutro caminho.

`archive_package/2` tinha o outro formato do mesmo problema: lia as futuras numa transação e
escrevia em outra, com a decisão tomada no meio. O que sobra de janela agora é a do **D-5** (sob
`READ COMMITTED`), contra a anterior, que era do tamanho de duas transações separadas.

Uma lição de implementação ficou no código: **`Repo.transaction` aninhado dentro de `in_clinic/2`
não serve** para quem precisa de `Repo.rollback` — no Ecto a transação de dentro não abre savepoint,
então o rollback derruba a de fora e o motivo chega como `{:error, :rollback}`, perdendo qual foi.
Os dois usam `Api.Repo.with_clinic/2` cru.

**Vermelho provado:** `a sessão foi cancelada e o total não baixou — pacote vendido com 1, zero na
agenda`.

## 7.5 P-3 e B-11 — transação e conexão do pool

**P-3.** `por_clinica/1` abria a transação e `em_lote/4` recursava lá dentro: o `LIMIT 5000` reduzia
o `DELETE`, **não** a transação. Invertido — o laço fora, cada `DELETE` no seu próprio `with_clinic`
—, a poda também virou **retomável**: se a rodada morrer no meio, os lotes já commitados ficam.

O teto do lote virou configuração, e não por gosto: com 5.000 o laço nunca dá a segunda volta em
teste nenhum, ou seja, a recursão que o módulo existe para ter estava sem cobertura. O
`poda_test.exs` novo baixa o teto para 2 e exercita o drenar de verdade — e diz, no moduledoc, o que
**não** consegue provar (que cada lote é uma transação; sob o sandbox tudo é uma só).

**B-11.** Os três `with_clinic` redundantes saíram (`send_job` ×2, `webhooks`, `patient_reply`) — as
ações já carregam `SetTenantGuc`, e a transação de fora só acrescentava a armadilha que
`Api.Tenancy` documenta. O caso real era o `ReminderJob`: a varredura **inteira** de uma clínica
rodava dentro de um `with_clinic`, com um `Dispatch.dispatch` (escrita + `Oban.insert`) por presença
lá dentro. Agora são duas fases — lê sob a GUC, dispara fora.

Isso transfere a responsabilidade da GUC para o `Dispatch`, que já a assume por escrito. Quem
**cobra** a afirmação é um teste `:rls` novo, e ele foi conferido **pela mutação**: tirando o
`in_clinic` da fase 1, fica vermelho sob `cinetra_app` — e continua verde sob `postgres`, que é
exatamente o motivo de o gate existir.

## 7.6 L-3 e L-2 — as duas bordas que faltavam

**L-3.** O transporte do socket é montado antes do router, e os dois limitadores são plugs de
pipeline do router: `join` **nunca passou por teto nenhum**, e cada join custa uma query. O teto
entrou em `ChannelScope.authorize/2` — ponto único por onde os três canais passam, e **antes** da
query que ele protege —, por `user_id`, 120/min. A recusa deixa log, pela mesma razão de L-5: o
canal responde só `:error`, sem status nem corpo.

**L-2.** O estágio de borda virou plug do **endpoint**, entre `Plug.Telemetry` e `Plug.Parsers`.
Como pipeline do router ele cortava antes do **banco**, mas não antes do **corpo**: uma requisição
destinada a levar 429 já tinha lido e decodificado até 8 MB.

A nuance que a auditoria não tinha: as isenções (`/webhooks`, health checks) eram feitas
*escolhendo pipelines scope a scope*. Movendo o estágio para o endpoint elas precisam ser
**explícitas**, senão a mudança reintroduz o que `router.ex` decidiu evitar — a rajada legítima de
uma campanha virando 429. Viraram `@sem_teto_de_borda`, com teste.

**Vermelho provado por ordem de plug**, sem medir memória: com o teto estourado, um corpo JSON
malformado devolvia o **400 do parser**; agora devolve **429**. Não é opinião — é qual plug
respondeu.

## 7.7 Limpeza, idiomática e o que a execução refutou

**M-2 — o AshJsonApi saiu inteiro** (decisão do usuário: não vamos expor Swagger). Foram junto os
módulos `Api.Meta` e `ApiWeb.AshJsonApiRouter`, as deps `ash_json_api` e `open_api_spex`, o
`AshJsonApi.Plug.Parser` do endpoint, a config de MIME `vnd.api+json` e o plug
`ApiWeb.Plugs.RequireScope` — que existia **só** para tapar aquele escopo (o único sem guarda de
controller, S-4). Duas rotas públicas, duas dependências e um plug a menos.

**E-2 — `Api.Repo.unwrap/1`.** As três funções de GUC são `transaction/1`, então tudo volta com uma
casca a mais, e onze pontos a tiravam à mão com semântica divergente. O pior era o `elem(1)`: sobre
`{:error, motivo}` devolve o *motivo cru* como se fosse o valor — foi assim que o `SendJob`
transformou erro de banco em "mensagem não existe". Uma função com as quatro cláusulas escritas uma
vez faz o chamador voltar a decidir **o que fazer com o erro** em vez de decidir, sem querer, **se
ele existe**.

**E-1 (resto) — `Api.Scheduling.Hours`.** O bloco de expediente/exceções (314 linhas) saiu, com
`defdelegate` na fachada, e nem controller nem teste mudaram uma linha. `Api.Scheduling` foi de
1723 → **1220 linhas** somando as duas fatias.

**R-4, P-8 e A-4** entraram no que sobrou de verdade: o `agora/1` idêntico em dois crons virou
`Reminders.instante_dos_args/1`; a moldura repetida quatro vezes em `Api.Directory`; o comentário
duplicado do `Falhas`; a leitura descartada de `all_slots` (que pedia `COUNT(*) OVER ()` e a lista
inteira de profissionais para jogar fora); o `get_package!` duas vezes por request; o fuso resolvido
**antes** do teste barato no `SessionSoonJob`; e a `read :na_janela` da `Attendance`, que tira do
worker um recorte que é do recurso.

**Dois pontos de A-4 a execução refutou**, e vale escrever por quê:

- `Api.Notifications.unread_count/1` — a alternativa "usar o code interface" **materializaria as
  linhas** para contar. `Ash.Query.for_read(:unread) |> Ash.count!` é a forma idiomática de contar
  *por ação*, e os outros dois usos constroem query porque `bulk_update!`/`bulk_destroy!` pedem
  query, não registros;
- `Api.Audit.Acesso.consultar/3` — a ação é **dinâmica** (`:recent_duplicate` ou
  `:recent_duplicate_by_label`) e a pergunta é `exists?`. Code interface não faz nenhuma das duas.

**O-2 já estava resolvido** e o doc 96 não sabia: `Api.Tracing.OtlpFilter` descarta a linha e emite
métrica no lugar — melhor que o throttle sugerido, porque *"o exportador está fora" é estado, não
evento*.

## 7.8 O contrato com o BFF (H-5, H-8, H-10)

Os três num commit só, api+web, porque nenhum deles pode andar sozinho.

**H-5.** As 14 chaves `camelCase` viraram `snake_case` nos dois controllers e nos ~20 arquivos do
web que as consomem. O cuidado que a mudança exigiu: `patientId` também é **nome de variável local**
em meia dúzia de componentes (`PatientAttachments`, `PackageCreateModal`…) — renomear por busca cega
teria quebrado prop de componente. O `svelte-check` foi o instrumento: mudar os **tipos** primeiro e
deixar os 21 erros apontarem cada consumidor real.

**H-8.** As quatro formas de `page` viraram uma, `ApiWeb.TenantScope.page_json/1`, e as duas que
eram montadas **dentro do domínio** (`Api.Audit`, `Api.Waitlist`) voltaram para a fronteira. `total`
sai **sempre**, e vem `nil` quando a leitura não contou — a ausência do campo era o problema real,
porque `undefined` e `null` pedem código diferente para o mesmo fato. Contar continua sendo escolha
do domínio, e cara: `count: false` custa 400× menos buffers.

**H-10.** `put_status(:unauthorized) |> redirect(external: …)` emitia **401 com header `Location`**
— um redirect que browser nenhum segue. Funcionava porque quem lê é o BFF, com `redirect: 'manual'`,
e ele olha só o `set-cookie`. Virou o 401 único da API (`unauthenticated`), e quem escolhe o destino
é o BFF, que já o escolhia.

## 7.9 O que fica em aberto, e por quê

| Item | Situação |
| --- | --- |
| **B-12** | **Débito aceito** (D-22). Capacidade de turma é orientação de sala, não invariante de dinheiro; um a mais a recepção remaneja. A armadilha do remédio óbvio (lock a partir de uma validation) está escrita no código. |
| **P-6** | **Débito aceito** (D-23). `future_conflicts` precisa mesmo rodar dentro da transação de escrita — tirá-la reabre a janela do D-5 onde hoje ela não existe. O horizonte da varredura é decisão de produto. |
| **P-9** | **Não medível em dev** (banco vazio). Destrava com o teste de carga do [doc 98](98-teste-de-carga-em-producao.md): medir `pg_stat_user_indexes` antes/depois, **pelo caminho da aplicação**. |
| **S-7 (resíduo)** | Payload com mais de um ano de idade volta a ser replayável, porque a linha foi podada. Fechar exige a Zernio assinar timestamp — não está do nosso lado. |

E um débito que **nasceu** nesta leva, já registrado: a poda continua sem prova automatizada de que
cada lote é uma transação própria. É a mesma cegueira estrutural do **D-15**, por um caminho
diferente, e está dita no moduledoc do `poda_test.exs` em vez de ficar implícita.
