# 43 — Bate-volta: a Onda 3 (Pacotes → Turma/A2 → Ficha)

Auditoria em rodadas do diff `7636b00..ea8676a` — as etapas 2–5 da A2 ([doc 41](41-turma-presenca-por-participante.md))
e a Frente 7 (histórico da ficha). Consertos em `fc7a0dd`.

**Onde parou:** rodada 5 (verificação). As duas caças acharam, a consolidação agrupou em 8
causas-raiz, a rodada 3 consertou 7 e a 5 re-sondou tudo. Não houve rodada 4 — a fila fechou na 3.

**Método.** Rodada 1 delegada a três eixos em paralelo (segurança, performance, refatoração), cada
um passando a checklist item a item contra a stack rodando. Rodada 2 no loop principal, sem
checklist, seguindo os fluxos e tentando quebrá-los. Nenhum achado entrou sem output de sonda.

---

## 1. A varredura

| Eixo | CONFIRMADO | REFUTADO | NÃO SE APLICA |
| --- | ---: | ---: | ---: |
| Segurança (checklist) | 3 | 14 | 7 |
| Performance (checklist) | 8 | 6 | 4 |
| Refatoração (checklist) | 9 | 12 | 5 |
| **Adversarial (rodada 2)** | **5** | — | — |

**O que a rodada 2 achou que a rodada 1 não tinha achado** — a medida de quanto o ângulo
adversarial pagou:

- a reinserção da massa perdia duração/encaixe/`created_by` (R2-A);
- a massa inundava a caixa do profissional com N avisos de "novo agendamento" (R2-B);
- `participant_removed` era empurrado e ninguém escutava (R2-C);
- `bulk_cancel` num pacote **pausado** deixava um estado em que o botão *Retomar* estourava 500
  (R2-D);
- **pausar** um pacote escondia a turma inteira do colega (SONDA D).

Nenhum deles está em checklist nenhuma: os quatro primeiros nascem de *seguir o fluxo até o fim*,
e o último de perguntar "e se a sessão for compartilhada?".

---

## 2. As causas-raiz

Oito, das quais duas explicam metade dos sintomas.

### CR-1 — a massa escrevia sem autorizador, com parâmetros do cliente 🔴

`Api.Packages.Bulk` usava `authorize?: false` ("quem autoriza é a leitura do pacote"), e
`professional_id`/`forcar` chegavam do corpo do request intactos a `reschedule`/`schedule`.

```
A) can? :reschedule no bloco do colega: false
B) can? :remove_participant no bloco do colega: false
>>> RESULTADO bulk_adjust: {:ok, %{afetadas: 1}}
>>> bloco DEPOIS: [rafael, "2026-08-31 12:00:00", encaixe=true]
```

Um `profissional` — o papel menos privilegiado com acesso à agenda — escrevia na coluna de outro e
desligava a proteção contra dupla-marcação. As duas coisas que o `Ash.can?` acabara de negar.

### CR-2 — "as sessões deste pacote" tinha duas regras opostas 🔴

O ciclo de vida do pacote (pausar/cancelar/retomar) operava sobre o **bloco**; a massa da etapa 3
opera sobre a **presença**. Três portas para o mesmo dano:

```
# cancelar o pacote do dono, numa turma compartilhada
%{status_do_bloco: :cancelado, presencas: [dono: :cancelada, colega: :cancelada]}

# pausar o pacote do dono, na mesma turma
%{pkg_hold: true, bloco_visivel_antes: 1, bloco_visivel_depois: 0, participantes_do_bloco: 2}

# bulk_cancel num pacote pausado → o Retomar que a ficha oferece
{:error, %Ash.Error.Invalid{errors: [%InvalidAttribute{field: :status,
  message: "transição indisponível a partir de \"cancelado\""}]}}  # lib/api/packages.ex:143
```

É o bug do `pkgOf` do protótipo — o mesmo que a etapa 3 foi escrita para corrigir — vivo pela porta
do lado.

### CR-3 — a reinserção da massa criava bloco do zero 🟡

```
ANTES  (bloco original):  %{obs: "trazer exame", dur: 80, encaixe: true,  created_by: true}
DEPOIS (reinserido):      %{obs: nil,            dur: 50, encaixe: false, created_by: false}
```

Mais o custo de escala que o eixo de performance mediu (ver §5).

### CR-4 — o histórico entrava pela ponta errada 🟡

`sort`/`limit` aplicados em memória depois de ler tudo, e `patient_id` malformado subindo
`MatchError`:

```
sessoes=2000 -> devolvidas=50 more?=true | queries=7 linhas_do_banco=4003 | wall=96ms
EXCECAO em list_patient_history: MatchError => vira 500 no controller
```

E, sob o papel `profissional`, o plano virava nested loop dirigido pela agenda inteira dele
(**679 iterações, 1.595 buffers** contra 57 do mesmo dado lido pelo owner).

### CR-5 — "presença viva" e `truthy` sem fonte única 🟡

Cinco escritas do predicado "presença viva" (três novas neste diff) e quatro versões de `truthy`
com contratos divergentes (`forcar: 1` virava `false` em silêncio). O sintoma medido:

```
count_participants (cap 4, 2 vivas): 4
entrar com 2 vagas livres de verdade: :error
```

### CR-6 — o wire ficou pela metade 🟢

Servidor: `event_name(:remove_participant) → "participant_removed"` + `push(socket, evento.event, …)`.
Cliente: `EVENTOS_DE_BLOCO` com cinco nomes, **zero** ocorrências de `participant_removed`.

### CR-7 — o fan-out lia o caro antes do barato 🟢

```
Fanout.participant_missed SEM destinatario: 5 queries
   [] begin · [] set_config · [appointments] SELECT … ← desperdiçada · [] commit
   [memberships] SELECT …                              ← o teste barato, que vinha depois
```

### CR-8 — o eixo de bloco continua vivo ao lado do de presença ⏸

Duas máquinas de estado completas escrevendo `Appointment.status`, com guards só de um lado. Não
entra na fila de conserto — é decisão de escopo (§6).

---

## 3. O que foi corrigido

Sete consertos, **todos com teste vermelho antes**, re-sondados na rodada 5 com a mesma sonda que
achou o achado.

| Causa | Conserto | Re-sonda (rodada 5) |
| --- | --- | --- |
| CR-1 | `Bulk.opts/1` passa `scope:` — as escritas vão pelo autorizador | `{:error, Forbidden}` para o profissional; recepção segue podendo (3 testes) |
| CR-2 | `cancel_package` usa `Bulk.cancelar_sessao/2`; `future_sessions` ignora presença cancelada; `held_sessions` ignora segurada já cancelada | `%{status_do_bloco: :agendado, vivas: 1, colega_ficou: true}` · `retomar: :ok` |
| CR-3 | a reinserção herda `duration_minutos` e `encaixe` do bloco de origem | `antes: %{dur: 80, encaixe: true}` → `depois: %{dur: 80, encaixe: true}` |
| CR-4 | `sort` por aggregate `session_starts_at` + `limit + 1` no SQL; guard de UUID; a rota resolve o paciente pela porta do `show/2` | `ORDER BY … DESC LIMIT $5` no SQL emitido; `148 linhas do banco` para devolver 50; id malformado → **404** |
| CR-5 | `count_participants/2` conta só presença viva | `%{count_participants: 3, entrada: :ok}` |
| CR-6 | `participant_removed` entra em `EVENTOS_DE_BLOCO` | teste do canal falso: o handler recebe |
| CR-7 | inverte o `with`: destinatário (1 query) antes do bloco (4) | `queries <= 2` sem destinatário |

Verde ao fim: api **941/0** (91,8%), gate `:rls` **7/0** como `cinetra_app`, web **1269/1269**
(91,3% stmts), `svelte-check` 0 erros.

---

## 4. O que a rodada 5 achou ✅ **FECHADO (2026-07-25)**

> **Feito: a coluna denormalizada.** `attendances.session_starts_at` (cópia do `starts_at` do
> bloco) com o índice `(clinic_id, patient_id, session_starts_at)`. O aggregate homônimo saiu — os
> dois juntos seriam duas verdades para o mesmo instante. Quem mantém a cópia são os **dois** únicos
> caminhos em que o par (presença, horário) nasce ou muda: `ManageParticipants` na criação e
> `SyncSessionStartsAt` na remarcação. `allow_nil? false` é deliberado — caminho novo que esqueça
> falha alto, em vez de sumir do histórico em silêncio.
>
> Medido **pelo caminho da aplicação** (a lição do doc 35: índice só conta se o SQL que o Ash emite
> o usar), na clínica de 10.185 blocos, como `cinetra_app`:
>
> ```
> Limit (actual time=0.025..0.197 rows=51)  Buffers: shared hit=48
>   -> Index Scan Backward using attendances_clinic_id_patient_id_session_starts_at_index
>        Index Cond: (clinic_id = current_setting(...) AND patient_id = ...)
> ```
>
> `pg_stat_user_indexes.idx_scan` do índice novo subiu a cada chamada de
> `list_patient_history/3` — é a prova de que quem o usa é a aplicação, não o `psql`. Sem sort,
> sem hash join, sem varrer a clínica: **291 buffers → 48**, e as duas curvas (paciente e clínica)
> ficam planas. Wall time pela app: ~15 ms, dominado pelo `load` do bloco/tipo/profissional.
>
> **O caso do papel `profissional` foi re-medido** (era o "não re-medido" de antes): criei a
> membership `:profissional` no banco de dev, vinculada à coluna do paciente. Mesmo plano, mesmo
> índice (`idx_scan` sobe igual), **8 sessões** devolvidas em ~15 ms — o recorte da A7 continua
> valendo e o nested loop de 679 iterações não existe mais.
>
> Migration ajustada à mão em três pontos que o codegen não sabe: coluna nasce nula → backfill
> (`UPDATE … FROM appointments`) → `SET NOT NULL`; `CONCURRENTLY` nos índices
> (`.claude/rules/migrations.md`); e o índice `(clinic_id, patient_id)`, agora prefixo estrito do
> novo, cai junto — a mesma lição de §5f.

O registro original do achado:

**O conserto do CR-4 trocou uma curva de crescimento por outra.** O plano novo, como
`cinetra_app` na clínica de 10.185 blocos:

```
Limit  (actual time=4.742..4.748 rows=51 loops=1)  Buffers: shared hit=291
  ->  Sort  Sort Key: ((sa0.starts_at)::timestamp) DESC   Sort Method: quicksort  Memory: 34kB
        ->  Hash Right Join  (actual rows=71 loops=1)
              ->  Result  (cost=0.01..358.56 rows=51) (actual rows=10185 loops=1)   ← a clínica inteira
                    Buffers: shared hit=231
```

O `ORDER BY … LIMIT` desceu para o SQL (era esse o objetivo: a transferência deixou de crescer com
o histórico do paciente), **mas** a subquery do aggregate é não-correlacionada: ela varre os
agendamentos da clínica para o hash join. Ou seja, o custo saiu de "cresce com o paciente" para
"cresce com a clínica" — melhor no caso que motivou o conserto (paciente antigo), pior numa clínica
grande com paciente novo. A estimativa do planner erra por 200× (`rows=51` contra 10.185 reais),
que é o que induz o hash.

**A correção definitiva é uma coluna denormalizada** `attendances.session_starts_at` (mantida pela
cascata de remarcação) com índice `(clinic_id, patient_id, session_starts_at DESC)` — as duas curvas
ficam planas. É migration + sincronização, ou seja, decisão de schema: não entra numa rodada de
conserto de bate-volta.

**Não re-medido:** o caso do papel `profissional` (o nested loop de 679 iterações). A clínica de
volume do `cinetra_dev` só tem membership `owner`, e criar uma de `profissional` é escrita no
banco de dev — que eu não faço sem seu aval.

---

## 5. O que ficou para decisão — e o que se decidiu

> **Todos os itens desta seção foram fechados em 2026-07-25**, na sessão seguinte à auditoria. Cada
> um traz, abaixo do registro original, o que foi feito e a medida depois. Dois deles foram
> fechados **decidindo não fazer** — e o porquê está escrito, que é o ponto de registrar.

### (a) A massa é uma transação longa com N escritas ✅ **PARCIALMENTE FEITO (2026-07-25)**

> **Feito: o passo (1), o hoist do invariante.** `Api.Scheduling.Warm` carrega uma vez por lote o
> que não muda entre as sessões — clínica, profissional + expediente da janela (pelo
> `load_availability_window/4` que a agenda já usava desde o doc 26), tipo, paciente e o dono do
> pacote — e viaja no **contexto** do changeset. Os leitores (`CheckAvailability`,
> `ReferencesActive`, `GroupCapacity`, `PatientsInClinic`, `PatientsActive`,
> `PackageBelongsToPatient`, `find_turma`) perguntam ao warm primeiro; em `:miss` seguem pelo
> caminho de sempre. **O warm é atalho, nunca autoridade**: uma ação chamada sem ele se comporta
> exatamente como antes, e o que a própria massa altera (bloco, presenças, ocupação da turma,
> conflito) não entra — continua sendo lido a cada escrita.
>
> Medido, com o teto agora fixado em teste (`bulk_queries_test.exs`, que falha quando o invariante
> voltar para dentro do laço):
>
> ```
> 6 sessões individuais:  82 → 52 queries   (13,7 → 8,7 por sessão)
>   clinics 6→1 · professionals 6→1 · clinic_hours 6→1 · professional_hours 6→1
>   schedule_exceptions 12→2 · appointment_types/patients/packages: 1 cada
> 4 sessões em turma:     98 queries (24,5/sessão) — o caminho caro (destaque + reinserção)
> ```
>
> O warm de catálogo (tipo/paciente/pacote) só é montado quando **há** sessão em turma no lote:
> numa massa toda individual ele custaria leitura para economizar zero.
>
> **Não feitos, e por quê.** O passo (2) — tirar o paper trail do caminho quente — trocaria custo
> por **buraco na trilha**: as versões da massa são as linhas que respondem "quem remarcou as 40
> sessões da Maria, e quando". `changes_only` e `store_action_inputs? false` já estão ligados; o
> que sobra é deixar de registrar, e isso é o oposto do que a trilha existe para fazer. O passo (3)
> — fatiar a transação ou empurrar para o Oban — trocaria os ~2,3 s de conexão presa pela perda do
> **tudo-ou-nada**, que é uma garantia escrita e defendida no moduledoc do `Bulk`: *"massa aplicada
> pela metade é pior que massa recusada — ninguém sabe onde parou, e o desfazer é manual, sessão
> por sessão"*. As duas trocas são decisão de produto, não de auditoria; se a lentidão em pacote
> grande incomodar em produção, a conversa começa por (3) — e aí o custo é desenhar o desfazer.
>
> Um efeito colateral do hoist: o `SyncSessionStartsAt` (§4) escreve o espelho com **um** `UPDATE`
> por remarcação, em vez de `SELECT` + N ações + N linhas de versão. É o mesmo argumento do passo
> (2) aplicado onde ele **não** custa trilha — o valor original já está registrado no bloco.

O registro original do achado:

Medido, `bulk_adjust` com `escopo: :todas`:

```
n=10  colega=false | queries=126  (12.6/sessao) | wall=82ms
n=40  colega=true  | queries=1576 (39.4/sessao) | wall=775ms
n=60  colega=true  | queries=2356 (39.3/sessao) | wall=1139ms
```

Repartição para 10 sessões em turma (406 queries): `134x set_config`, `40x appointment_types`,
`20x patients`, `20x professionals`, `20x schedule_exceptions`, `10x clinics`, `10x clinic_hours`,
`10x memberships`, `10x professional_hours` — **a mesma linha relida a cada iteração**. Só 4 das 39
queries por sessão são escrita.

Em produção, com o banco na rede, um pacote de 60 sessões projeta ~2,3 s de **transação única**
segurando 1 das 10 conexões do pool e os locks da exclusion constraint — qualquer agendamento
concorrente naquele profissional espera a massa terminar.

Correção sugerida, do mais barato ao mais caro: (1) hoistar o invariante (clínica, expediente, tipo,
paciente, pacote) para fora do laço via contexto do changeset, como o `Materializer` faz — corta
~60% das queries sem mudar semântica; (2) tirar o paper trail do caminho quente (120 INSERTs de
versão por clique); (3) fatiar a transação ou empurrar para o Oban, trocando 2,3 s de conexão presa
por N transações curtas.

### (b) A massa inunda a caixa do profissional ✅ **FEITO (2026-07-25)**

> **Decidido: notificação agregada, família nova.** `:package_bulk_adjusted` entra no
> `NotificationKind` (e no `NotificationKind` do web, e na tabela do [doc 31 §3a](31-notificacoes.md)):
> *"3 sessões do pacote Pilates 10 foram remarcadas"* — uma linha por profissional afetado, origem
> **e** destino, com o autor suprimido como em todo o fan-out.
>
> As por-sessão são suprimidas **na origem**: a massa marca as escritas com `bulk_pacote: true` no
> contexto do changeset e a primeira cláusula do `Api.Notifications.Notifier` as ignora. Só a
> **caixa** é suprimida — o `AgendaNotifier` é outro notifier e continua recebendo tudo, sessão por
> sessão, porque a agenda aberta na tela precisa de cada bloco que se moveu.
>
> Medido depois (o mesmo cenário de 3 sessões que media 3 avisos):
>
> ```
> package_bulk_adjusted: 1 · appointment_scheduled: 0 (era 3) · appointment_rescheduled: 0
> corpo: "3 sessões do pacote Pilates 3 foram remarcadas."
> ```

O registro original do achado:

```
afetadas: 3 | antes: %{appointment_scheduled: 3, …} → depois: %{appointment_scheduled: 6, …}
```

Uma notificação **"Novo agendamento na sua agenda"** por sessão reinserida, quando o evento real é
um só ("o pacote da Maria mudou de horário") — e a sessão foi **movida**, não criada. Um pacote de
40 sessões numa turma manda 40 avisos. A correção pede uma decisão: notificação agregada por massa
(um "N sessões do pacote X foram remarcadas") é família nova no `NotificationKind`, e o doc 31 §3a
não a previu.

### (c) Pausar um pacote esconde a turma dos colegas ✅ **FEITO (2026-07-25)**

> **Feito: existe presença segurada.** `Attendance.pkg_hold`, com a preparation global
> `HideHeldAttendances` (irmã da `HideHeld` do bloco, mesma porta `include_held` para o ciclo de
> vida do pacote reler o que segurou). Pausar passa a seguir a **mesma decisão por presença** do
> resto do pacote — a `Bulk.sozinho?/2`, agora pública porque é a pergunta que massa, cancelar e
> pausar compartilham: **sozinho no bloco**, segura o bloco (é a sessão dele); **acompanhado**,
> segura só a presença, e os colegas nem percebem.
>
> Cai junto um bug irmão que ninguém tinha visto: a **retomada** cancelava o bloco, então retomar
> um pacote de turma teria cancelado a sessão dos colegas. Agora ela usa `Bulk.cancelar_sessao/2`,
> a mesma decisão de sempre. E `RemoveParticipants` passou a abrir `include_held` — sem isso a
> retomada não achava a própria presença segurada e abortava a transação com "participante não
> encontrado neste agendamento".
>
> Medido, na turma de dois (o cenário do achado), e re-medido sob RLS como `cinetra_app`:
>
> ```
> pausar:  bloco.pkg_hold = false · participantes visíveis = [colega] · presença do pacote: pkg_hold = true
> retomar: bloco.status = :agendado · participantes visíveis = [colega]   (a turma sobreviveu)
> ```
>
> **O que ficou de fora, de propósito:** a massa (`bulk_adjust`) **pula** sessão segurada — não há
> horário a remarcar no que está parado, e a retomada reprojeta tudo a partir de hoje de qualquer
> forma. O cancelar continua alcançando as seguradas (RN-25), senão ficam órfãs.

O registro original do achado:

O `pkg_hold` é do **bloco**; não existe "presença segurada". Pausar o pacote de um paciente numa
turma compartilhada tira o bloco da agenda de todos (RN-05):

```
%{pkg_hold: true, bloco_visivel_antes: 1, bloco_visivel_depois: 0, participantes_do_bloco: 2}
```

Cancelar já foi corrigido (opera por presença); **pausar não tem como**, sem um mecanismo de
"presença segurada" — coluna/status novo na `Attendance` + leitura que a esconda. É a mesma classe
de decisão do rollup: schema + semântica, não conserto de auditoria.

### (d) O eixo de bloco continua vivo — decisão de escopo ✅ **RESOLVIDO (2026-07-25)**

> **Decidido: aposentar.** As três ações de desfecho do bloco (`mark_completed`, `mark_missed`,
> `set_falta_justificada`) foram removidas — ação Ash, rota, controller, BFF, action do SvelteKit
> e o campo `falta_justificada` de bloco no JSON. O desfecho passa a ter **um** caminho: a
> presença, com o rollup como único autor de `Appointment.status`. Duas consequências que caem
> junto: o tradutor `slot_action/3` do notifier morreu (a pergunta virou `vaga_abriu?`), e o
> `Enum.all?` sobre a invariante revogada saiu do serializer. `cancel`/`reopen`/`exclude` ficam
> (não são desfecho), e os rótulos antigos seguem na tela de auditoria — a trilha guarda o que
> aconteceu. Os testes que exercitavam o eixo foram **migrados** para a presença, não apagados.
>
> A alternativa (reimplementar as ações de bloco como cascata que escreve presenças, mantendo um
> "concluir a turma toda") foi descartada por ora: o botão não existe na tela e ninguém pediu.
> Quando pedirem, nasce certo — sobre o eixo de presença.

O registro original do achado:

`mark_completed`/`mark_missed`/`set_falta_justificada` seguem alcançáveis por action SvelteKit, BFF,
controller e policy, embora o drawer não os renderize mais. Consequências medidas: os guards novos
(`block_not_open`, `StatusIn` por presença) existem só no eixo de presença; `Notifier.slot_action/3`
é um tradutor que só existe porque os dois eixos emitem nomes diferentes para o mesmo fato; e
`Appointment.falta_justificada` no JSON é um `Enum.all?` sobre uma invariante ("a cascata deixa
todas uniformes") que a A2 revogou — com o comentário afirmando-a no presente.

Decidir: ou reimplementar as ações de bloco como cascata que escreve **presenças** (deixando o
rollup como único autor de `Appointment.status`), ou retirar rotas/actions/BFF do eixo antigo. O
estado atual — os dois vivos — é o que custa.

### (e) Dívidas de DRY que já divergiram ✅ **FEITAS (2026-07-25)**

> Todas as seis, com o critério de "uma definição, e as cópias apontando para ela":
>
> * **`truthy`** → `Api.Params.truthy?/1` (e `truthy?/2` para ler a flag do mapa de params). Mora
>   em `Api` e não em `ApiWeb.TenantScope` porque nem todo consumidor é controller — o `Bulk` lê as
>   próprias flags. A regra de divisão ficou escrita: forma **HTTP** (escada de erro, janela de
>   datas) na fronteira; **valor** que atravessa a camada, em `Api.Params`. O conjunto aceito é o da
>   cópia mais permissiva (`true`/`"true"`/`"1"`/`1`): a consolidação **amplia** quem era estrito,
>   então nenhum cliente que funcionava para de funcionar — e `forcar: 1` deixa de virar `false`
>   calado;
> * **"presença viva"** → `Attendance.viva?/1` (lista em memória) + `calculate :viva?` (filtro que
>   desce para o SQL). As cinco cópias apontam para lá;
> * **rótulo/tom da presença** → `attendanceSelo(status, falta_justificada)` em `$lib/agenda`. As
>   duas telas o chamam, e a divergência foi resolvida para o **cinza**: falta justificada não conta
>   no agregado `Patient.faltas` nem debita o pacote, então pintá-la de vermelho dizia o contrário
>   do que o sistema faz com ela;
> * **`ParticipantKind`** → a **lista** (`PARTICIPANT_KINDS`) é a fonte e o tipo é derivado dela; o
>   BFF re-exporta. `AttendanceStatus` sai de `$lib/agenda` também no `server/patients.ts`;
> * **`Attendance.set_package`** → removida (ação, code interface e o último chamador, que era um
>   teste). O carimbo nasce com a presença desde a etapa 2 da A2;
> * **`Ash.Generator`** → `Api.Generators`, importado pelo `DataCase`. As **doze** `setup_clinic`
>   privadas viraram `clinica/1` + `profissional!/2` + `paciente!/2` + `tipo!/2` +
>   `escopo_de_membro!/3` + `escopo_em/2`. Sozinho, isso apagou ~250 linhas de fábrica copiada.

O registro original do achado:

- **`truthy` em quatro versões**: `"1"`/`1` valem para `justificada` e não valem para
  `forcar`/`encaixe`/`aplicar_horario`. Um cliente que mande `forcar: 1` recebe `false` calado.
  Consolidar em `ApiWeb.TenantScope.truthy/1` — o mesmo argumento que já consolidou `parse_int/1`
  ali, cujo docstring diz "estava copiada em três controllers, e a cópia mais nova já divergia".
- **"presença viva" em cinco lugares** (`bulk.ex` ×2, `remove_participants.ex`, `rollup.ex`,
  `preview.ex`): a sexta cópia é a que vai divergir. Candidato a `calculate :viva?` na `Attendance`.
- **Rótulo/tom da presença em três fontes**, duas já divergentes: falta justificada é cinza no
  histórico (`PatientHistory.svelte:30`) e vermelha no drawer (`AppointmentDrawer.svelte:288`).
- **`ParticipantKind` declarado duas vezes** + `PARTICIPANT_KINDS` como terceira lista de runtime;
  `AttendanceStatus` duplicado entre `agenda.ts` e `server/patients.ts`.
- **`Attendance.set_package` ficou órfã**: o único chamador de produção (`Sessions.stamp/3`) saiu na
  etapa 2, e o comentário da ação ainda aponta para ele. Superfície de escrita viva sem chamador.
- **12 fábricas `setup_clinic` privadas em `test/`, zero `Ash.Generator`** — contra o que
  `.claude/rules/ash.md` manda. Os dois arquivos novos somam ~90 linhas de setup copiado.

### (f) Índice redundante e trilha sem poda ✅ **FEITAS (2026-07-25)**

> * **Índice:** `attendances_clinic_id_appointment_id_index` derrubado (migration com
>   `DROP INDEX CONCURRENTLY`, pelas duas anotações que a regra do projeto exige). Era prefixo
>   estrito do único `(clinic_id, appointment_id, patient_id)`, que na mesma janela tinha 684
>   varreduras contra `idx_scan=0` dele. O comentário no recurso agora **diz que ele não existe e
>   por quê** — senão o próximo a otimizar o recria;
> * **Trilha:** `Api.Housekeeping.PruneTrail`, um job Oban com cron diário (03:00 UTC), varrendo
>   **por clínica** dentro de `with_clinic` (as tabelas de versão têm a mesma RLS das tabelas base;
>   sem GUC o `DELETE` apagaria zero linha para sempre — e passaria no `mix test`). Deleta em lotes
>   de 5.000 até esgotar. A retenção é **decisão humana e mora na config**:
>   `config :api, Api.Housekeeping.PruneTrail, reter_dias: 365` — um ano cobre o horizonte que a
>   tela de auditoria serve. O cron voltou porque agora há trabalho real: o anterior (limpeza de
>   `SlotHold`) fora removido por varrer uma tabela que deixara de existir.

O registro original do achado:

```
attendances_clinic_id_appointment_id_index | idx_scan=0 | 520 kB   ← prefixo estrito do índice único
appointments_versions                      | 15 MB      (tabela base: 5.256 kB)
```

O primeiro é custo de escrita puro, e a Onda 3 escreve mais nessa tabela (a massa faz destroy +
insert por sessão). A trilha já é 3× a tabela base e o único cron de poda foi removido
(`config/config.exs:87`).

### (g) `bulkCancelPackage` não tem chamador ✅ **FEITO (2026-07-25)**

> **Decidido: sai do BFF**, com o motivo no lugar da função. Da ficha, cancelar em massa com escopo
> `todas` é o que **`cancelPackage` já faz** (e ainda marca o pacote como cancelado); o que a massa
> acrescenta são os escopos `esta`/`proximas`, que exigem uma sessão de **referência** — algo que só
> a agenda sabe apontar. Quando esse botão for pedido, ele nasce no drawer da agenda, com a
> referência em mãos. O endpoint do backend continua existindo e testado.

O registro original do achado:

O BFF (`web/src/lib/server/packages.ts:174`) expõe o cancelar em massa, mas nenhuma tela o chama e
não há teste dele no web. O endpoint do backend tem teste; a ponta web parou no meio.

---

## 6. Sobre o método, para a próxima

- **A caça adversarial pagou.** Cinco dos doze achados de correção só aparecem seguindo o fluxo até
  o fim — nenhum estava em checklist. Os dois piores (CR-2 e o 500 do Retomar) vieram de perguntar
  "e se a sessão for compartilhada?" e "e se alguém fizer isto **depois** daquilo?".
- **Delegar a rodada 1 em três eixos paralelos funcionou**, com uma ressalva: dois achados vieram
  deduzidos do código, não executados (`cancel_package` levando a turma junto, e o teto contando
  cancelada). Os dois se confirmaram quando eu **rodei**, mas a regra vale: achado sem sonda é
  hipótese. Exigir o output colado no prompt do subagente é o que separa um do outro.
- **A rodada 5 justificou-se sozinha**: ela achou que o conserto do histórico trocou uma curva de
  crescimento por outra. Sem ela, isso entraria como "resolvido".

---

## 7. O fechamento da fila (2026-07-25)

Sessão seguinte à auditoria, para zerar §4 e §5. O que mudou de fato:

| Item | Saída |
| --- | --- |
| §4 histórico | coluna `attendances.session_starts_at` + índice; aggregate removido; **291 → 48 buffers**, plano em Index Scan Backward, provado por `idx_scan` pela app |
| §4 papel `profissional` | re-medido com membership criada no dev: mesmo índice, 8 sessões, ~15 ms — o nested loop sumiu |
| §5a transação longa | `Api.Scheduling.Warm` (hoist do invariante): **82 → 52** queries em 6 sessões; teto fixado em teste. Trilha e fatiar: **decidido não fazer**, com o porquê escrito |
| §5b notificações | família `:package_bulk_adjusted`; **3 avisos → 1**, com supressão só da caixa (tempo real intacto) |
| §5c pausar em turma | `Attendance.pkg_hold` + `HideHeldAttendances`; pausar/retomar por presença. Cai junto o bug irmão da retomada cancelando a turma |
| §5e DRY | `Api.Params.truthy?`, `Attendance.viva?` + calculate, `attendanceSelo`, `PARTICIPANT_KINDS` como fonte, `set_package` removida, `Api.Generators` no lugar de 12 fábricas |
| §5f índice/trilha | índice redundante derrubado (`CONCURRENTLY`); `PruneTrail` com cron diário e retenção em config |
| §5g BFF órfão | `bulkCancelPackage` removido, com o motivo no lugar da função |

**Verde ao fim:** api **953/0** (91,3%), gate `:rls` **15/0** como `cinetra_app` (três casos
novos: warm + espelho do horário, presença segurada, poda da trilha), web **1266/1266** (91,4%
stmts), `svelte-check` 0 erros.

### O que ficou aberto, e com que gatilho

Três itens saíram desta rodada sem código. A diferença entre "adiado" e "esquecido" é o gatilho
estar escrito, então aqui estão:

| Item | Estado | Gatilho para reabrir |
| --- | --- | --- |
| Tirar o paper trail do caminho quente | **Decidido não fazer** | Não reabre por tempo. Só se o requisito de auditoria mudar — hoje a trilha é a única resposta para "quem remarcou as 40 sessões da Maria, e quando", e ela custa 24% dos statements de uma operação rara |
| Fatiar a massa (Oban) | **Adiado** | A instrumentação mostrar massa acima de ~100 sessões acontecendo de verdade, **ou** p95 da massa passar de 3 s em produção. O custo real não é o job: é desenhar o **desfazer**, porque sem transação única uma massa que falha na sessão 37 deixa 36 movidas e ninguém sabe onde parou |
| Retenção da trilha (365 dias) | **Adiado por data** | **Julho/2027.** Hoje a versão mais antiga tem 6 dias e o cron não apaga nada; o número só tem efeito quando a trilha completar um ano. Antes disso, confirmar com quem responde por compliance — a poda é irreversível |

O que **não** ficou aberto, porque foi fechado junto com a auditoria: o teto de `Package.total`
(120 sessões). Era ele que fazia o Risco A ser ilimitado — `total` só tinha `min: 1`, então um
`500` digitado no lugar de `50` projetava ~8.000 queries e ~15 s de transação única, tempo de
estourar o request e de segurar os locks da exclusion constraint junto. Com o teto, o pior caso é
~2.000 queries. E o espelho `session_starts_at` ganhou um **teste-guarda** estrutural: ação nova
que aceite `starts_at` sem a change que sincroniza a presença falha na hora de ser escrita, em vez
de aparecer meses depois como histórico fora de ordem na ficha.

**Três lições desta rodada de conserto:**

- **O gate `:rls` pegou o que a suíte não pegaria.** O `UPDATE` cru do espelho e a leitura da
  presença segurada rodam sob a GUC; sob `postgres` (BYPASSRLS) passariam de qualquer jeito. Todo
  caminho novo por-tenant entrou lá no mesmo commit — não depois.
- **Denormalizar cobra a cascata no mesmo dia.** A coluna só é barata porque `ManageParticipants` e
  `SyncSessionStartsAt` são os **dois únicos** lugares em que o par (presença, horário) nasce ou
  muda, e `allow_nil? false` transforma "esqueci de manter" em erro alto em vez de dado errado
  silencioso.
- **Fechar item de backlog às vezes é decidir não fazer.** Dois dos oito saíram assim (paper trail
  no caminho quente, fatiar a transação). O que fecha o item não é o código: é o motivo registrado —
  senão o próximo a ler a lista refaz a mesma análise do zero.
