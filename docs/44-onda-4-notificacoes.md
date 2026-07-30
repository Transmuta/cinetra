# 44 — Onda 4: Notificações (Frente 10)

A onda que o [doc 35](35-plano-execucao-backlog.md) sequenciou como *"perf antes dos gatilhos"*.
Fecha os quatro itens de estrutura que o bate-volta das notificações ([doc 32](32-auditoria-bate-volta-notificacoes.md) §5)
deixou como P1–P4 e os gatilhos que sobraram da §3 do [doc 31](31-notificacoes.md).

**Estado:** construída e verificada em 2026-07-26, e **auditada** em seguida — o bate-volta está
em [`45`](45-bate-volta-onda-4.md) e corrigiu cinco causas (duas delas de correção, não de
performance). Números depois da auditoria: API **1009 testes / 0 falhas / 91,1%**, gate `:rls`
**20/0** como `cinetra_app`, web **1275 testes / 0 falhas / 91,5% stmts**, `svelte-check` 0
erros, `mix format --check-formatted` e `--warnings-as-errors` limpos.

---

## 1. As três decisões de produto que abriram a onda

O doc 35 lista gates a resolver **antes** da frente. Foram decididos em 2026-07-26:

| Gate | Decisão | Por quê |
| --- | --- | --- |
| **#48** — limiar de "urgente na fila" | **Só `urgente`** | `alta` é frequente em clínica movimentada. O custo de um sino que apita demais não é volume: é o usuário parar de olhar (doc 31 §4) |
| **#51** — quais lembretes por cron | **Os dois** (resumo diário + "sessão em 15 min") | O doc 31 §3d marcava o segundo como 🔴 *"a tela do dia já mostra; ruído alto"*. A objeção segue de pé e está escrita no `SessionSoonJob`; desligar é tirar **uma linha** do crontab |
| **#54** — retenção da caixa | **Lidas 90d, não-lidas 365d** | Lida é histórico; não-lida é trabalho pendente. O teto de um ano existe só para a caixa **abandonada** não crescer para sempre |

---

## 2. Perf/estrutura (#52–#55)

### #55 — o índice, e as duas vezes em que ele não anexou

O achado P4 pedia `[clinic_id, recipient_id, inserted_at desc]`. Entregue como **dois** índices —
um para a caixa, um parcial para as não-lidas — e **sem** o `desc`: as duas primeiras colunas são
igualdade, então o btree serve o `ORDER BY … DESC` lendo ao contrário (*Index Scan Backward*),
como o `session_starts_at` do [doc 43](43-bate-volta-onda-3.md) §7.

O índice foi criado, e a primeira sonda pelo caminho da app deu **`idx_scan = 0`**. Duas causas
distintas, as duas só visíveis medindo:

**(a) O `LIMIT` não valia nada enquanto havia `count: true`.** O `countable` do Ash vira
`COUNT(*) OVER ()`, uma window function que lê o recorte **inteiro** — o `LIMIT` só apara no fim.
Com 20.065 linhas na caixa:

| caminho | plano | buffers | tempo |
| --- | --- | --- | --- |
| lista **com** `count: true` | Index Scan Backward + WindowAgg | 10.265 | 12,9 ms |
| lista **sem** o count | Index Scan Backward | **26** | **0,11 ms** |

Ou seja: **o #55 dependia do #54**, e não o contrário. Quem exibe "X–Y de Z" paga o total; a caixa
do sino não exibe, e passou a não pagar (`Api.Pagination.page_opts/1` ganhou `count:`).

**(b) O índice parcial não anexava por causa de um cast** — a mesma lição do doc 35
("D-A — o diagnóstico correto"), cobrada de novo. O AshPostgres emite

```sql
WHERE (n0."read_at"::timestamp IS NULL) AND clinic_id = $1 AND recipient_id = $2
```

e o Postgres só usa índice parcial quando prova que o predicado do índice **implica** o da query —
prova que ele não faz através do cast. Com `where: "read_at IS NULL"` o índice existia íntegro e
**nunca era escolhido**:

| predicado do índice | plano | buffers | tempo |
| --- | --- | --- | --- |
| `read_at IS NULL` | Seq Scan | 1.542 | 5,4 ms |
| `(read_at)::timestamp IS NULL` | **Index Only Scan** | **184** | **1,9 ms** |

Testada e **descartada** a alternativa de eliminar o cast alargando a coluna para
`timestamp(6)`: o cast sobrevive e o índice continua sem anexar. O predicado casa o SQL emitido, e
o acoplamento a esse detalhe do AshPostgres está escrito no recurso — se um upgrade parar de
emitir o cast, o índice deixa de anexar **em silêncio**, sem nenhum teste vermelho.

Prova final, pelo caminho da app (`Api.Notifications.list_inbox/2` e `unread_count/1` rodando como
`cinetra_app`, 40.071 linhas):

```
notifications_inbox_index    idx_scan 4   idx_tup_read  218
notifications_unread_index   idx_scan 1   idx_tup_read 4000
```

> **Gotcha da própria sonda:** ler `pg_stat_user_indexes` de dentro da mesma conexão devolve o
> snapshot **cacheado** — o contador aparece zerado mesmo com o índice em uso. Três medições
> erraram assim antes de a leitura passar a ser feita numa sessão nova.

### #54 — paginação e poda

A caixa não tinha teto. Medido: `list_inbox` trazendo **20.065 linhas em 583 ms**. Pior, o caminho
do badge (`?unread=1`, chamado no load do layout em **toda navegação**) trazia as **4.065**
não-lidas inteiras pela HTTP para ler **um número** — a lista era descartada no BFF.

- ação `:inbox` paginada (50/200, os números de `Api.Pagination`), `:unread` idem;
- o envelope `page` é o de pacientes/trilha/fila **menos o `total`** — divergência deliberada e
  escrita, pelo custo medido acima;
- `fetchUnreadCount` passou a pedir `limit=1`; o número vem do `COUNT` no índice parcial;
- a tela ganhou Anterior/Próxima no mesmo gesto da fila (`?page=`, `replaceState`).

A poda é `Api.Housekeeping.PruneNotifications` (cron diário 03:15, 15 min depois da trilha). O
mecanismo — varrer por clínica sob a GUC, apagar em lotes por `ctid` — saiu para
`Api.Housekeeping.Poda`, porque era a **segunda** cópia de três sutilezas de RLS que envelhecem
mal em duplicata.

### #53 — "marcar todas" em O(1)

Era `1 SELECT + N×(SELECT da policy + UPDATE)` em série. Virou um `COUNT` + um `UPDATE`, com teto
fixado em teste (`queries == 2`).

Ação própria (`:mark_all_read`) em vez de `bulk_update` sobre o `:mark_read`, por dois motivos que
se somam: o `:mark_read` é idempotente **por comparação** (lê o `read_at` atual para decidir), que
é justamente o round-trip a eliminar — aqui a idempotência vem do **filtro** (`read_at IS NULL`),
feita no banco sobre o conjunto inteiro; e o `SetTenantGuc` é um `before_action`, e hook derruba a
ação do caminho atômico. A GUC não falta: quem chama roda dentro do `in_clinic` — e o gate `:rls`
prova isso com um teste próprio, porque a policy é filter-check e o `Ash.can` do UPDATE em massa
roda um SELECT sob RLS antes de escrever.

### #52 — o `who_fits` saiu do caminho do cancelamento

Responder "quem cabe nesta vaga" custa ler a fila inteira com seus `load`s — 6 queries e uma
transação **com a fila vazia**, dentro da resposta que o usuário está esperando. Foi para
`Api.Notifications.SlotOpenedJob`, em fila Oban própria (`notifications`, não `housekeeping`: um
aviso de vaga atrás de uma poda que varre clínica a clínica chegaria tarde demais).

O notifier continua decidindo **se** a vaga abriu (só ele tem o changeset). O job **relê** o bloco
em vez de carregar o resultado nos args: entre o commit e a execução cabem segundos, e nesses
segundos a vaga pode ter sido preenchida ou a fila ter mudado.

A regressão é medida, não descrita: um teste conta as queries em `waitlist_entries` durante o
cancelamento e exige **zero**. Mover o `who_fits` de volta para o notifier fica vermelho na hora.

Cai junto o **P5** (memberships lido 2× por cancelamento), como a auditoria previu.

---

## 3. Os gatilhos (#48, #50, #51, #56)

| # | Evento | Quem recebe |
| --- | --- | --- |
| **#48** | entrou na fila alguém `urgente` | operacional (owner/admin/recepção) |
| **#50** | papel alterado | **o próprio afetado** |
| **#50** | membro removido | owner/admin |
| **#51** | "você tem N atendimentos amanhã" | dono da coluna |
| **#51** | "sua próxima sessão começa às HH:MM" | dono da coluna |

### O par do #50 é assimétrico, e é estrutural

"Papel alterado" vai ao afetado — é o único evento da caixa cujo destinatário é o alvo da ação, e
faz sentido: mexer no papel mexe no que a pessoa pode fazer, e ela descobriria sozinha só ao
esbarrar num botão que sumiu.

"Membro removido" **não** vai ao removido pela caixa. Ela é por-tenant e só se lê com vínculo
ativo; assim que o vínculo cai, aquela caixa fica inalcançável para ele. Avisar por lá seria
escrever numa gaveta trancada. Então a notícia in-app vai à governança, espelhando o
`member_joined`.

E quem saiu é avisado **por e-mail** (`Api.Accounts.AccessRevokedEmailJob`), que é o único canal
que atravessa a remoção. Isso abre uma exceção consciente ao doc 31 §5, que manteve e-mail fora da
v1: a régua de lá é "e-mail por evento de agenda vira spam em uma semana", e mudança de **acesso**
não é evento de agenda — é a única classe em que o destinatário perde o outro canal exatamente no
momento em que precisa saber. É o segundo e-mail do projeto, ao lado do magic link.

Três decisões dentro dele:

- **vai por Oban**, não no request: SMTP é I/O externo, e deixá-lo na resposta do "remover membro"
  seria recriar a dívida que o #52 acabou de tirar do cancelamento;
- **diz qual clínica** — o usuário é global e pode ser membro de várias (ADR-017); "seu acesso foi
  removido" sem dizer de onde deixaria a pessoa sem saber se tem trabalho amanhã;
- **não diz quem removeu**, e **não suprime o autor**. O primeiro porque pôr o nome de um colega
  num e-mail automático de perda de acesso cria atrito que o sistema não tem contexto para mediar;
  o segundo porque aviso de mudança de acesso é registro de segurança — o valor dele é chegar
  sempre, inclusive quando quem recebe não foi quem fez.

**O que este item ainda não resolve:** `Membership` não tem trilha de auditoria (o `AshPaperTrail`
cobre só `Appointment` e `Attendance`). Numa clínica com um owner só, que remove alguém, o
destinatário in-app é conjunto vazio — então a remoção deixa o e-mail e mais nada dentro do
sistema. Ver §4.

### #51 — "19h" é pergunta de fuso, não de UTC

Cada clínica tem o seu fuso (ADR-009), então um cron único em UTC serviria a hora certa para uma e
a errada para as demais. O resumo acorda **de hora em hora** e só trabalha nas clínicas cujo
relógio local marca a hora configurada.

O "sessão começando" roda a cada 5 min sobre a janela `[agora+15, agora+20)`. A janela **ladrilha**
a linha do tempo: todo bloco cai em exatamente uma rodada, o que substitui uma tabela de "já
avisei". Um cron de minuto daria mais precisão e 12× mais varreduras — o preço que o D-L cobrou do
cron anterior. Como o texto diz a **hora exata** e não "em 15 minutos", a largura da janela não
chega ao usuário como informação errada.

**O teste do ladrilho achou um bug de verdade.** A primeira versão lia a agenda pela ação
`:in_range`, que filtra por **sobreposição** (`starts_at < to and ends_at > from`) porque foi feita
para desenhar a grade. Uma sessão de 50 min sobrepõe três janelas de 5 min seguidas → o
profissional recebia o mesmo aviso três vezes. O mesmo erro contaria uma sessão de 23:30–00:20 em
**dois** dias no resumo. O recorte por `starts_at` foi para dentro da query, em
`Reminders.blocos_por_profissional/3`.

### #56 — deep-link fino

Todo aviso de agenda caía em `/agenda` no estado padrão, ou seja, **hoje**: abrir "seu paciente de
quinta foi remarcado" mostrava a agenda de hoje e a pessoa navegava até lá na mão. O `data` da
notificação já trazia o `date` desde o começo — faltava usá-lo. Agora `/agenda?date=…`, e
`waitlist_urgent` abre `/fila?prio=urgente`. A data é validada antes de virar destino: `data` é
jsonb livre.

A massa por pacote segue no padrão — são N sessões em datas diferentes, não há um dia para onde
levar.

---

## 4. O que ficou aberto, e com que gatilho

| Item | Estado | Gatilho para reabrir |
| --- | --- | --- |
| `session_soon` pode ser ruído (doc 31 §3d) | **Entregue por decisão, com a objeção registrada** | Reclamação de usuário ou desuso medido. Desligar = tirar a linha do crontab |
| Índice parcial acoplado ao `::timestamp` do AshPostgres | **Aceito, medido e escrito** | Qualquer upgrade de `ash_postgres`: re-medir `idx_scan` pelo caminho da app. Falha em silêncio |
| Notificar por **e-mail** quem foi removido da clínica | ✅ **FEITO** (2026-07-26) | — |
| **Trilha de auditoria no `Membership`** | **Aberto** | Hoje a remoção de um membro não deixa registro nenhum: o `AshPaperTrail` cobre só `Appointment` e `Attendance`, e a notificação in-app tem destinatário vazio quando quem remove é o único owner/admin. O `TrailMixin` já existe e é o mesmo gesto dos outros dois recursos. Reabre quando "quem tirou o acesso de quem, e quando" precisar de resposta — que é a primeira pergunta de qualquer auditoria de acesso |
| Dedupe/agrupamento por agendamento (doc 31 §5) | **Não feito** | Duas remarcações no mesmo bloco ainda viram duas linhas |
| `D1`/`D2` do doc 32 (DRY do `connectNotifications`, guardas de canal) | **Adiados** | `D2` reabre no 4º canal, como já estava escrito |

---

## 5. Sobre o método

Três coisas desta onda que valem para a próxima:

- **O índice foi a parte fácil; provar que ele anexa foi o trabalho.** Duas causas independentes o
  mantiveram inerte, e nenhuma das duas aparece em teste — só em `EXPLAIN` com o SQL que a app
  **emitiu** (copiado do log, não digitado) e em `idx_scan` lido numa sessão nova.
- **Um teste de borda pagou a onda.** O ladrilho da janela do `session_soon` parecia formalidade e
  achou um aviso triplicado que teria chegado como spam ao profissional.
- **Perf primeiro estava certo, mas por um motivo diferente do previsto.** A ordem do doc 35 era
  "perf antes dos gatilhos" por trilha de código; o que se descobriu é que a paginação era
  **pré-requisito** do índice. Entregar o #55 antes do #54 teria produzido um índice íntegro e
  inútil — exatamente o desfecho do D-A na Onda 2.
