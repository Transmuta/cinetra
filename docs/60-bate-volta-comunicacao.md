# 60 — Bate-volta da comunicação com o paciente (doc 52, fase 1)

Auditoria em rodadas contra a **stack rodando**, não contra a leitura do diff. Alvo: tudo que a
fatia de comunicação escreveu — domínio `Api.Messaging`, os três controllers novos, o plug de
corpo cru, as migrations, a config de runtime e o lado web.

**Onde parou:** rodada 5. As duas caças por checklist e a caça adversarial acharam **9 causas-raiz**;
oito foram corrigidas e re-sondadas, uma fica para decisão humana (§5).

---

## 1. A varredura

### Segurança — feita no loop principal, ao vivo

| Item | Estado | Sonda |
| --- | --- | --- |
| Rota pública sem sessão: resposta do paciente | 🔴 **CONFIRMADO** | §2, causa A |
| Rota pública sem sessão: webhook | REFUTADO | Assinatura Svix confere antes de qualquer leitura; sem headers → 401 |
| Estreiteza da exceção da RLS | REFUTADO | Com a GUC do provider: `count(*) = 1`. Com GUC vazia: `0` |
| `message_opt_outs` global legível por qualquer tenant | REFUTADO (é a intenção) | Sem rota; policy do recurso proíbe toda ação. O que revela é um endereço que pediu para não ser contatado |
| `global? true` vira buraco? | REFUTADO | A RLS fecha: sem GUC, zero linhas |
| Cross-tenant na timeline | REFUTADO | `GET` de bloco de outra clínica → **404**, corpo vazio |
| Cross-tenant no disparo | REFUTADO | `POST` → **404**, `count(*) = 0` mensagens criadas |
| Token de resposta vaza dado? | REFUTADO | Devolve clínica, **primeiro nome**, data e hora. Sem ficha, sem contato, sem outros participantes |
| Segredo em log | REFUTADO | 0 ocorrências de `whsec_`/`re_…` em 400 linhas |
| Recursos novos na AshJsonApi | NÃO SE APLICA | Sem bloco `json_api`; `mix phx.routes` mostra só as 5 rotas explícitas |
| Timing attack na assinatura | REFUTADO | `Plug.Crypto.secure_compare/2` |
| Replay de webhook | REFUTADO | Timestamp de ontem → 401 |
| Fail-closed sem segredo | REFUTADO | Segredo `nil` → 401 |

### Performance — caça delegada

| Item | Estado | Número medido |
| --- | --- | --- |
| N+1 no `Notifier` | **CONFIRMADO** | Turma de 4: 12 queries de messaging (8 leituras + 4 inserts) |
| N queries de opt-out na timeline | **CONFIRMADO** | Turma de 4 sem mensagem: 4 queries por abertura de drawer |
| Índice parcial de opt-out anexa? | REFUTADO | `idx_scan` +10 exato em 10 chamadas; `Index Scan`, 4 buffers, 0,058 ms |
| Índice do provider sob a policy nova | REFUTADO | O `OR` vira `Filter`, o `Index Cond` sobrevive; `idx_scan` 4 → 14 |
| Índice para o cron de lembrete | 🔴 **CONFIRMADO** | **134,8 ms / 16.863 buffers para 15 linhas** |
| Colisão de crontab | REFUTADO (medido) | 3 de 5 slots por ~1 s; sem starvation |
| Índices de FK | **CONFIRMADO** | 2 de 7 sem índice liderando, ambas CASCADE |
| I/O externo na transação da GUC | 🔴 **CONFIRMADO** | `in_transaction? = true`, conexão `idle in transaction` |
| `opted_out?` sem `LIMIT` | **CONFIRMADO** | Traz as 10 colunas para perguntar "existe?" |
| `messages` sem poda | **CONFIRMADO** | Sem entrada em `lib/api/housekeeping/` nem no crontab |

### Refatoração — caça delegada

| Item | Estado |
| --- | --- |
| DRY contra `Api.Notifications` | **CONFIRMADO** — `agora/1` literal, `Poda.clinicas()` 3ª cópia, `bulk_pacote` duplicado, `with_clinic` tratado de dois jeitos |
| Helpers de teste duplicados | **CONFIRMADO** — `paciente_com/2` em 6 arquivos, um já divergente |
| Rules do Ash | **CONFIRMADO** — 4 violações |
| `rescue` largo | CONFIRMADO como cheiro; REFUTADO como "os testes não pegam" |
| Testes decorativos | REFUTADO — as 3 regras principais ficam vermelhas quando mutadas |
| Migrations | REFUTADO — nenhum `CREATE INDEX` em tabela com dado |
| Gate de cobertura | REFUTADO — `coveralls.json` e `vite.config.ts` intocados |
| Comentário que mente | **CONFIRMADO** — 2 |
| Web DRY | **CONFIRMADO** — `fetchJson` 3ª cópia, clone de tela, defaults escritos 6× |

**O que a rodada 2 (adversarial) achou que a 1 não teria achado:** a causa A. Nenhuma checklist a
pega — os 7 testes da rota estavam verdes, o typecheck limpo e a cobertura acima do piso. Ela só
aparece **dirigindo o app**: criar a confirmação pelo botão, esperar o e-mail e clicar no link.

---

## 2. As causas-raiz, e o que foi feito

### A 🔴 — A GUC não acompanha o caminho sem sessão

**O que era.** O link do e-mail respondia `link_invalido`. O token estava correto
(`{:ok, "019fa692-…"}`); a RLS é que fechava:

```
leitura SEM GUC (o que a rota faz):  0
leitura COM a GUC da clínica:        1
```

`PatientReplyController` lia sem tenant e sem GUC, a policy comparava `clinic_id = NULL` e não
casava linha. **A rota pública de resposta do paciente estava morta em produção** com a suíte
verde — o sandbox conecta como `postgres`, que bypassa RLS.

É a mesma classe do webhook, que já tinha exceção. O erro foi não ver que eram **dois** caminhos
que resolvem o tenant a partir de um identificador externo.

**Conserto.** `Api.Repo.with_message/2` (irmã de `with_provider_message/2`) e uma terceira cláusula
na policy. Teste vermelho primeiro, no gate `:rls`, que é onde isso teria sido pego.

**Re-sonda** (a mesma que achou):

```
GET /api/reply/<token>  →  {"clinica":"Clínica Agenda Demo","paciente":"Maria","data":"20/07/2026","hora":"13:15"}
GET /confirmar/<token>  →  http=200, "Confirmar presença"
POST resposta           →  resposta gravada: confirmou | 2026-07-28T03:23:32Z
timeline da recepção    →  • confirmacao enviado | resposta: confirmou | automatico: False
```

E a exceção continua estreita: com a GUC do `message_id`, `count(*) = 1`; com ela vazia, `0`.

### D 🔴 — I/O externo dentro da transação da GUC

`SendJob` envolvia leitura + entrega + gravação num `with_clinic/2` só. Com um adapter que dorme,
a caça mediu `in_transaction? = true` e a conexão `idle in transaction` — cinco envios lentos
segurariam cinco conexões pelo tempo da rede alheia.

**Conserto.** Três passos: lê sob GUC, **sai**, entrega, volta sob GUC para gravar.

**Re-sonda:** `ADAPTER: in_transaction? = false`, e o resultado gravado (`enviado | t | resend`).

### C 🔴 — Faltava índice para a varredura por janela de tempo

O cron de lembrete filtra `attendances` por `session_starts_at`, e nenhum índice existente permite
range sem igualdade antes. Medido na clínica de volume: **134,804 ms, 16.863 buffers, 15 linhas**
(`Rows Removed by Filter: 10170`).

**Conserto.** `attendances (clinic_id, session_starts_at)`, com `CONCURRENTLY` (tabela quente,
regra do projeto). **Não** parcial em `status`: o AshPostgres emite a coluna com cast e um índice
parcial que não anexa falha em silêncio (lição do doc 35).

**Re-sonda:** `Bitmap Index Scan on attendances_clinic_session_starts_at_index`, **0,082 ms,
13 buffers** — de 134,8 ms para 0,08 ms.

### B — A mesma pergunta feita de dois jeitos

`opted_out?` fazia `list |> Enum.any?` (dez colunas, sem `LIMIT`) enquanto o `ja_confirmada?` do
mesmo domínio já usava `Ash.exists?`.

**Conserto.** `Ash.exists?` nos dois. **Re-sonda:** o SQL virou `SELECT TRUE FROM "message_opt_outs" …`
e o índice continua anexando (`idx_scan 34 → 44`, +10 exato).

O **lote** (uma query para N participantes) **não** foi feito: exigiria mudar a assinatura de
`Dispatch.avaliar/2`, que é a "autoridade única" da regra, e o ganho medido depois do `exists?` é
de ~0,06 ms por participante. Fica em §5.

### G — FK sem índice liderando

`messages.patient_id` sem índice (Seq Scan, 2.859 buffers, 55,9 ms no cascade) e
`messages.appointment_id` só em segunda posição de um composto (233 buffers, 4,6 ms).
**Conserto:** os dois índices, via `custom_indexes` do recurso.

### I — Três migrations reescrevendo a mesma policy

O SQL aparecia 6× entre `up`/`down`, e o `down` da última reintroduzia a versão que estoura
`22P02`. Como nada estava commitado: **squash em uma**, com a policy final e o porquê no moduledoc.

### E — Comentários que mentiam

Três, e os três levariam alguém a decidir errado:
`opt_out.ex` dizia que a tabela ficava **fora** da RLS (a migration a põe **sob**); a migration do
webhook listava `global? true` como alternativa **descartada** (o código adotou); e
`reminder_job.ex` dizia *"é ele que o índice serve"* quando o índice não existia.

### F — DRY não aproveitado

Feito: os três helpers de teste (`paciente_com/2` em 6 arquivos, um já divergente) foram para
`Api.Generators`; o `Ash.load!` do controller virou `load:` na code interface.

**Não feito, e é decisão de engenharia registrada:** a supressão do `bulk_pacote`. A extração
piora o código — função não casa em head de cláusula, e a `defguard` equivalente fica menos
legível do que a linha que substituiria. O risco real (trocar a marca e esquecer um dos dois
notifiers → 40 e-mails, sem erro) ficou preso por **teste**.

> **E o teste nasceu decorativo.** A primeira versão passava com a marca renomeada, porque a dedupe
> de confirmação já suprimia o segundo envio — o setup derrotava a própria asserção. Só se viu
> mutando a marca. Corrigido (desliga o automático, garante zero mensagens, religa) e provado:
> verde com o código certo, **vermelho com a marca renomeada**.

---

## 3. Os gates, depois de tudo

| | |
| --- | --- |
| Backend | 1263 testes, **2 falhas pré-existentes** (§5), 90,1% |
| Gate `:rls` como `cinetra_app` | as mesmas 2, nenhuma da fatia |
| Web | 1592 testes, 0 falhas, 90,6% |
| `mix format --check-formatted` · `svelte-check` | limpos |

---

## 4. O que ficou para decisão humana

**H — `messages` nasce sem poda.** ✅ **Decidido em 2026-07-28: fica como débito, sem número por
ora.** Retenção é pergunta transversal e jurídica, e o projeto já tem três réguas decididas em três
momentos (trilha 365, caixa 90/365, anexos diária); uma quarta decidida isolada seria mais uma que
ninguém sabe justificar. Vai para uma passada única, com orientação jurídica, valendo para todos os
casos. Registrado em [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md) como **D-11**, com o volume
medido (~19 MB/ano/clínica) e a ressalva que importa: a linha **é** a prova de que se avisou, então
a poda apaga evidência, não lixo.

**B-lote — a query por participante.** Depois do `exists?` custa ~0,06 ms por participante (turma
de 4 = 4 lookups de índice). Batê-la em lote exige mudar a assinatura de `Dispatch.avaliar/2`, que
é deliberadamente a autoridade única da regra "esta pessoa recebe?". Trocar clareza da regra de
negócio por 0,2 ms não me parece bom negócio — mas a decisão é de quem vai manter.

**Web DRY transversal.** `fetchJson<T>` está na 3ª cópia (`messages.ts` ≡ `notifications.ts` ≡
`clinics.ts`) e o `SubmitFunction` das telas de config na 3ª. A extração é boa e toca **telas fora
desta fatia** — é refatoração própria, não rabo desta.

**`rescue` largo nos dois pontos best-effort.** Converte bug de programação em `Logger.warning` +
`:ok`. Os testes pegam (provado), mas em produção nada distingue "provider caiu" de "chamei função
errada". Estreitar para as classes esperadas mexe no contrato best-effort — decisão.

---

## 5. Duas falhas que **não são desta fatia**

`Api.RlsSmokeTest`, bloco *"massa por pacote e histórico sob RLS"*: `bulk_adjust` e `bulk_cancel`
estão **vermelhos na árvore de trabalho**. Cinco sondas os desatribuem desta fatia:

1. falham com o `Api.Messaging.Notifier` **desanexado** do `Appointment`;
2. falham na versão **commitada** do arquivo de teste;
3. falham com o banco de teste **recriado do zero**;
4. `git status` de `api/lib/api/packages/` e `api/lib/api/scheduling/` está **limpo** (exceto a
   linha do notifier);
5. há trabalho **de outra sessão em voo** exatamente nessa área — `api/test/api/tenant_guc_test.exs`
   e `docs/58-bate-volta-guc-no-destroy.md`, ambos não commitados, ambos mencionando `bulk`/`warm`.

A correção pertence a quem está com aquela fatia na mão.

---

## 6. Dado de teste deixado no banco de dev

Anunciado durante a auditoria, nada apagado sem aviso:

- **meu**: `UPDATE` numa ficha (Maria Silva ganhou e-mail e consentimento), 3 confirmações criadas
  pela tela, um `UPDATE oban_jobs SET scheduled_at` para adiantar o envio, e uma linha de sonda
  inserida e **removida**;
- **da caça de performance**: 4 pacientes `PerfProbe`, **50.000** linhas em `message_opt_outs`,
  **100.000** em `messages` e 6 agendamentos. É volume de medição, não dado de trabalho — vale
  limpar antes de usar o dev para outra coisa.
