# Bate-volta — a GUC de tenant no `destroy` (commit `c109dbc`)

Alvo: `api/lib/api/records/attachment.ex` + `api/test/api/rls_smoke_test.exs`, o conserto do
`DELETE` de anexo que falhava sob RLS no servidor real. Escopo fechado, 106 linhas.

## 1. Onde parou, e por quê

Foi até a **rodada 5**. A rodada 1 não achou nada nas três listas — o diff é uma linha de DSL e
testes. A **rodada 2 (adversarial) achou a causa-raiz**: o conserto tratava o sintoma num
recurso, e nada no projeto detectava a mesma forma no próximo. A rodada 3 consertou a causa; a
rodada 5 achou um ponto cego no próprio conserto.

## 2. A varredura

### Segurança

| Item | Estado | Sonda |
|---|---|---|
| Bypass do BFF / ataque direto na API | NÃO SE APLICA | nenhum endpoint novo no diff |
| Tenant vindo do cliente | REFUTADO | `with_attachment/3` resolve por `fetch_clinic_attachment(scope, id)`; o `id` da URL nunca vira tenant |
| IDOR / BOLA (policy) | REFUTADO | `policy always()` + `HasClinicRole` cobre `action_type(:destroy)`; leitura do bloco `policies` |
| IDOR / BOLA (RLS, ADR-018) | REFUTADO | `psql -U movimento_app`, GUC da Clínica Beta, `DELETE` de anexo da Moving → **`DELETE 0`**, `count(*) = 0` |
| Broken function level authz | REFUTADO | reflexão: o `:destroy` tem policy; nenhuma action nova |
| Mass assignment | NÃO SE APLICA | `destroy` não aceita atributo |
| CORS / CSRF | NÃO SE APLICA | sem rota nova |
| Auth (magic link, OAuth, sessão, timing) | NÃO SE APLICA | diff não toca autenticação |
| XSS | NÃO SE APLICA | sem render no diff |
| **SQL injection na GUC** | REFUTADO | `Api.Repo.set_clinic_guc/1` usa `query!("SELECT set_config($1, $2, true)", [...])` — parametrizado, com guard `is_binary` |
| SSRF / open redirect / path traversal | NÃO SE APLICA | sem URL de entrada; a `chave` deriva de ids (pré-existente) |
| Vazamento de `clinic_id` / em log | REFUTADO | o diff não acrescenta `Logger` nem campo de response |
| Secrets em código | REFUTADO | único literal novo é o fixture `@pdf` |
| Headers de segurança | NÃO SE APLICA | sem resposta HTTP nova |
| DoS | REFUTADO | ver performance: +1 query por linha, medido |
| Dependência vulnerável | NÃO SE APLICA | `mix.exs`/`mix.lock` intocados |

### Performance

| Item | Estado | Sonda |
|---|---|---|
| N+1 | REFUTADO | log do `DELETE` real: 4 transações, nenhuma em laço |
| Seq scan / índice faltando | NÃO SE APLICA | nenhuma query nova; o `DELETE` usa a PK |
| Paginação ausente | NÃO SE APLICA | sem `read` novo |
| `SELECT *` desnecessário | NÃO SE APLICA | — |
| Aggregate/calculation caro | NÃO SE APLICA | — |
| Índice em FK | NÃO SE APLICA | sem migration |
| **Custo do hook no `destroy`** | CONFIRMADO (aceito) | `QueryCounter` na poda: **19 queries com o `on:`, 16 sem**, para 3 linhas → **+1 `set_config` por linha**, ~0,1 ms cada |
| Pool / transação longa | REFUTADO | o `set_config` entra na transação que já existia; nada de I/O externo acrescentado |
| Crescimento sem poda | NÃO SE APLICA | `PruneAttachments` já existe |

### Refatoração

| Item | Estado | Sonda |
|---|---|---|
| DRY — segunda fonte da verdade | CONFIRMADO | a asserção estrutural do `Attachment` no `rls_smoke_test` vs. o contrato geral (ver §3) |
| Constante repetida (`@pdf`) | CONFIRMADO (não corrigido) | fixture de magic bytes em `rls_smoke_test.exs` e `attachments_controller_test.exs` |
| Regra/authz fora da action | REFUTADO | a mudança é declarativa, dentro do recurso |
| Elixir (pattern matching, erros como valor, `String.to_atom`, nomes) | NÃO SE APLICA | o diff de produção é uma opção de DSL |
| Ash (code interface, multitenancy pelo mecanismo, change em módulo próprio) | REFUTADO | `SetTenantGuc` já é módulo próprio; multitenancy pelo `:attribute` |
| Comentário que contradiz o código | REFUTADO | releitura contra `SetTenantGuc` e `records.ex:379-395` |
| Docs no repo, nunca cloud | OK | este arquivo |

**O que a rodada 2 achou que a 1 não tinha achado:** tudo o que importa. A rodada 1 fechou sem
CONFIRMADO de segurança; foi o ângulo adversarial — *"quantos outros `destroy` por-tenant estão
sem GUC?"*, respondido por reflexão do Ash em vez de grep — que virou o resultado do bate-volta.

## 3. As causas-raiz

**Uma só, e não é o `Attachment`.** Change global do Ash roda em `[:create, :update]`; `:destroy`
fica de fora por padrão. O projeto usa `change Api.Tenancy.SetTenantGuc` em bloco global em 12
recursos, e **nada detectava** quando isso deixava um `destroy` por-tenant sem GUC — falha que só
existe no servidor real (`movimento_app`, NOBYPASSRLS) e que a suíte não vê, porque o sandbox
conecta como `postgres`.

A sonda que estabeleceu isso, por reflexão sobre todos os recursos por-tenant com `destroy`:

```
Api.Records.Attachment .destroy        -> GUC ok      (corrigido em c109dbc)
Api.Scheduling.Attendance .remove      -> *** SEM GUC ***
Api.Scheduling.ScheduleException .destroy -> GUC ok
Api.Waitlist.WaitlistEntry .dequeue    -> GUC ok
Api.Waitlist.AvailabilityRule .destroy -> GUC ok
Api.Notifications.Notification .clear  -> *** SEM GUC ***
```

Os dois "SEM GUC" são **deliberados** e seguros hoje — mas por conta do chamador, não da
declaração:

- `Notification.clear` — sem hook para o `Ash.bulk_destroy!` ir pelo caminho atômico; a GUC vem
  do `in_clinic` de `clear_all/1`, e o gate `:rls` já prova ("limpar a caixa alcança as linhas");
- `Attendance.remove` — único chamador é `RemoveParticipants`, um `after_action` dentro da
  transação do `Appointment`, onde o `SetTenantGuc` do bloco (update) já rodou. **Não é coberto
  pelo gate `:rls`** (`grep` por remoção de participante no arquivo: nenhuma ocorrência).

## 4. O que foi corrigido (rodada 3)

**Só teste — nenhuma linha de produção mudou nesta rodada.**

Novo `api/test/api/tenant_guc_test.exs`, no mesmo espírito do `on_delete_test.exs` que já existia:
deriva os recursos por-tenant dos próprios domínios, exige a GUC em todo `destroy` e obriga quem
abre exceção a **escrever o motivo** em `@sem_guc_por_desenho`. Mais dois testes que impedem a
lista de apodrecer (quem ganhou GUC sai dela; exceção para ação que sumiu acusa).

Vermelho antes do verde — mutação removendo o `on:` do `Attachment`:

```
1) test todo destroy por-tenant seta a GUC, ou está declarado como exceção
   Estes `destroy` de recurso por-tenant não põem a GUC de tenant na transação:
       Api.Records.Attachment.destroy
```

E a asserção estrutural específica saiu do `rls_smoke_test.exs` — com o contrato geral no ar, ela
era segunda fonte da mesma verdade. Os três testes comportamentais do anexo ficam lá, que é o
papel daquele arquivo.

**Re-sondas (rodada 5):**

- app rodando, `DELETE` real depois do conserto — a GUC agora entra na transação do `DELETE`:
  ```
  begin
  SELECT set_config($1, $2, true) ["movimento.clinic_id", "019f5e60-…"]
  DELETE FROM "attachments" AS a0 WHERE (a0."id" = $1) AND (a0."clinic_id"::uuid = $2::uuid)
  commit
  Sent 204 in 323ms
  ```
- gate `:rls` como `movimento_app`: **28 testes, 0 falhas**;
- suíte completa: **1183 testes + 18 doctests, 0 falhas**;
- `mix format --check-formatted` e `mix compile --warnings-as-errors` limpos.

## 5. O que ficou para você

**(a) O contrato novo tem ponto cego — 2 domínios fora da vigilância.** `@dominios` no
`tenant_guc_test.exs` é lista à mão, copiada do `on_delete_test.exs`, e não bate com a fonte
única:

```
Application.get_env(:api, :ash_domains)
  [Api.Meta, Api.Accounts, Api.Directory, Api.Scheduling, Api.Records,
   Api.Waitlist, Api.Packages, Api.Notifications, Api.Messaging]
fora da minha lista: [Api.Meta, Api.Messaging]
```

Impacto **hoje é zero** (nenhum recurso por-tenant com `destroy` nesses dois — sonda confirmou),
mas `Api.Messaging` é a frente de comunicação em construção, então o ponto cego tende a importar
em breve. Não corrigi por dois motivos: a correção certa é `Application.get_env(:api,
:ash_domains)` nos **dois** arquivos, e o `on_delete_test.exs` está fora do alvo desta auditoria —
mexer nele é o escorregão que o método existe para evitar; e a rodada 5 não conserta. Correção
proposta: trocar `@dominios` por `Application.fetch_env!(:api, :ash_domains)` nos dois, o que
apaga a duplicação e o ponto cego de uma vez.

**(b) `Attendance.remove` é a mesma forma, ainda desprotegida pelo gate.** Seguro hoje por
construção do único chamador. O que falta é um teste no `rls_smoke_test.exs` que remova
participante sob `movimento_app` — assim, se a remoção ganhar porta própria (fora de
`in_clinic`), o gate acusa em vez de a clínica descobrir em produção. Não fiz porque é
funcionalidade fora do alvo do commit auditado.

**(c) O custo do hook na poda é aceito, não resolvido.** +1 `set_config` por linha (19 vs 16
queries para 3 linhas), redundante porque `PruneAttachments` já roda dentro de `with_clinic`. Não
há como o Ash pular uma change global por chamador sem separar a ação, e separar `destroy` em
duas ações para economizar 0,1 ms por linha numa poda noturna é pior do que pagar.

**(d) `@pdf` duplicado** entre `rls_smoke_test.exs` e `attachments_controller_test.exs`. Deixei:
divergir aqui quebra teste alto (o `farejar/1` reprova), então não é a duplicação silenciosa que
a regra mira. Extrair para o `DataCase` é mexer em infra compartilhada por ganho marginal.

**(e) Fora do alvo, observado durante as sondas.** Duas coisas do estado atual da árvore, nenhuma
relacionada ao commit auditado:

- `mix compile` emite `Spark.Error.DslError` em `Api.Messaging.Message.Version` — *"Attribute
  clinic_id used in multitenancy configuration does not exist"*. É warning do paper trail sobre o
  recurso da frente de comunicação (não commitada);
- **9 linhas `:pendente`** em `attachments`, da clínica Moving — restos dos uploads que a CSP
  bloqueou antes do conserto de ambiente. É exatamente o órfão previsto pelo desenho (linha sem
  objeto, o barato); `PruneAttachments` as recolhe após 24 h. Só não confunda com bug quando
  aparecerem no banco.
