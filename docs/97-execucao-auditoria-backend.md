# 97 — Execução da auditoria do backend (doc 96): o que entrou

**Data:** 2026-07-31 · **Base:** [`96-auditoria-backend.md`](96-auditoria-backend.md) (47 achados)
· **Branch:** `develop`

Este documento registra as correções dos achados do doc 96, em **duas levas**. Ele é honesto sobre
o corte: **36 itens entraram, 11 continuam abertos**, e a §4 diz por quê em cada caso — com dois
deles **deliberadamente não consertados** depois de tentativa (§4.0).

Toda correção seguiu a regra do [CLAUDE.md](../CLAUDE.md): teste vermelho antes do conserto. Onde o
vermelho foi **provado por execução**, a saída está colada.

---

## 1. Estado dos gates

| Gate | Antes | Depois |
| --- | --- | --- |
| `mix compile --force --warnings-as-errors` | ✅ | ✅ |
| `mix format --check-formatted` | ✅ | ✅ |
| `mix test` | ⚠️ **1704 testes, 4 falhas** (ver §2) | ✅ **1714 testes, 0 falhas** |
| `mix test --only rls` (como `cinetra_app`) | ✅ | ✅ |
| `mix coveralls` (piso 80) | ✅ | ✅ **89,9%** |

Diff: **58 arquivos, +1144 −280** (inclui `deploy/observability/alloy.alloy` e uma fixture do BFF).

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

## 6. Próximo passo sugerido

1. **Decidir T-0.** É o que destrava T-1 (a verificação da §5), S-5, e a redação de cinco
   documentos que hoje descrevem errado o modo de falha do RLS. Não é decisão de implementador:
   muda o comportamento de **todo** o sistema em produção.
2. **B-8 e S-5**, que vêm juntos porque são migration — e migration em tabela quente pede o
   cuidado de [`migrations.md` §2](../.claude/rules/migrations.md).
3. **B-12**, com o desenho certo (`before_action` ou constraint), agora que a limitação do
   caminho errado está documentada no código.
4. **E-1** (quebrar `Api.Scheduling`), que é a maior dívida estrutural e não tem risco funcional —
   o bloco de relatórios sai inteiro, sem tocar em mais nada.
