# 41 — Turma: presença e débito por participante (Frente 6 / A2)

> ## ✅ A2 COMPLETA (2026-07-25) — as cinco etapas
>
> | Etapa | O que entrou | Commit |
> | --- | --- | --- |
> | 1 | presença por participante (backend) + rollup | `513bca1` (+ `9e00620`) |
> | 2 | `package_id` na entrada de `:schedule`/`:add_participant` | `0b6ba8a` |
> | 3 | massa por pacote sobre presenças + `remove_participant` | `6b7461c` |
> | 4 | drawer por participante + massa no cartão | `065d70b`, `298fd00`, `a2a0d27` |
> | 5 | notificações #46 e #47 | `60808a6` |
>
> **A entrega foi aditiva primeiro, e a aposentadoria veio depois.** A etapa 4 tirou as ações de
> bloco da TELA; o bate-volta ([doc 43](43-bate-volta-onda-3.md)) mediu o custo de mantê-las vivas
> — duas máquinas de estado escrevendo `Appointment.status`, com guards só de um lado — e elas
> **foram removidas** (ação, rota, BFF, action do SvelteKit e o campo `falta_justificada` de bloco
> no JSON). Sobrou o que não é desfecho: `cancel`, `reopen`, `exclude` e a `CascadeToAttendances`
> que os dois primeiros usam. Os rótulos `mark_completed`/`mark_missed`/`set_falta_justificada`
> ficam na tela de auditoria: a trilha guarda o que aconteceu.
>
> Dois pontos que a spec não previa e o código tem:
>
> - **rollup ao reabrir** — desfecho volta para `:agendado` quando as presenças voltam a
>   `:prevista` (`rollup.ex:37-42`); a regra abaixo omitia esse ramo;
> - **bloco cancelado não recebe presença** (`block_not_open`) — guard nascido do achado M-3 do
>   [bate-volta 42](42-bate-volta-pacotes-e-turma.md).

Fecha o **gate #1** do [doc 35](35-plano-execucao-backlog.md) e constrói a Frente 6. Depende da
Frente 5 (Pacotes, [doc 09 §3.1.1](09-contrato-api.md), commit `cb86851`), que já entregou o
**débito por participante** — `Package.usadas` conta cada `Attendance.package_id` do dono. Falta o
**caminho de escrita**: hoje toda transição do bloco cascateia para todos os participantes.

## Decisões (2026-07-24)

- **Escopo: A2 completa.** Presença por participante + `add_participant` com `package_id` + ajuste
  e cancelamento **em massa** por pacote (RN-26/27) com a semântica correta do `pkgOf`.
- **Presença é exclusivamente por participante.** Remove-se a transição do **bloco inteiro**
  (`mark_completed`/`mark_missed`/`set_falta_justificada` no `Appointment`). Marca-se cada
  presença; mesmo numa sessão individual (1 participante) marca-se aquela única presença. Confirma
  a D10 (`00-decisoes.md`), que o schema já antecipava (`AttendanceStatus` próprio,
  `falta_justificada` por linha).

## O modelo: o status do bloco vira ROLLUP das presenças

O ponto que evita uma migração de risco: os blocos existentes marcados `:concluido`/`:faltou` já
têm as presenças no status certo (a cascata antiga escreveu). Então **o enum
`AppointmentStatus` não muda** e **não há backfill** — o que muda é *quem escreve* o status.

- O `Appointment` mantém as fases de **agendamento**: `:agendado`, `:confirmado`,
  `:em_atendimento`, `:cancelado` (+ `encaixe`, `pkg_hold`, `excluded_at`). Essas seguem sendo
  escritas pelas ações de bloco (`schedule`, `reschedule`, `cancel`, `exclude`, `set_pkg_hold`).
- O **desfecho** (`:concluido`/`:faltou`) deixa de ser transição direta e passa a ser **derivado**
  das presenças, recomputado no `after_action` da transição de presença (`RollupBlockStatus`):
  - todas as presenças vivas (não `:cancelada`) `:prevista` → mantém a fase de agendamento;
  - todas resolvidas e **alguma** `:concluida` → bloco `:concluido` (a sessão aconteceu p/ alguém);
  - todas resolvidas e **todas** `:faltou` → bloco `:faltou`;
  - resolução **parcial** (algumas ainda `:prevista`) → mantém a fase atual (a sessão está em
    curso). A cor da agenda reflete o rollup; o drawer mostra o N/M por linha;
  - **reabrir** (todas voltam a `:prevista`) devolve o bloco à fase de agendamento — o ramo que
    esta spec omitia e o `rollup.ex` tem.

Regra de leitura para o `bloco pode estar :concluido com um participante :faltou`
(`attendance.ex:8`): o rollup é "concluído se aconteceu para pelo menos um", não "para todos".

## Ações novas — por presença (`Attendance`)

Substituem as de bloco. Cada uma: policy própria (recepção·profissional·admin·owner),
`SessionStarted` (o gate de horário do bloco, via `appointment.starts_at`), guard de versão
otimista **do bloco** (`expected_version` → 409, o mesmo do resto da agenda; a versão vive no
`Appointment`, então bumpa lá), e emite notificação/tempo real. A `:transition` cascata-only atual
(hoje `authorize?: false`) é aposentada.

| Ação (`Attendance`)      | Efeito                                         | Rota                                                        |
| ------------------------ | ---------------------------------------------- | ---------------------------------------------------------- |
| `mark_present`           | `:prevista` → `:concluida`                     | `POST /appointments/:id/participants/:patient_id/complete` |
| `mark_absent`            | `:prevista` → `:faltou`                        | `POST /appointments/:id/participants/:patient_id/no_show`  |
| `reopen_attendance`      | `:concluida`/`:faltou` → `:prevista` (zera justificada) | `.../reopen`                                      |
| `justify_absence`        | `falta_justificada := bool` (só se `:faltou`)  | `.../justify`                                               |

O débito é automático: `Package.usadas` já conta pela `Attendance.package_id` do dono e a
`falta_punitiva` **daquele** pacote — nada a fazer nas ações além de escrever o status.

## `add_participant` ganha `package_id` (docs/09 §3.1.1 ponto 2)

Aceita `package_id?`. Se presente, valida que o pacote é **do próprio `patient_id`** (senão 422);
nulo = encaixe avulso/particular. Isso wira o "entrar em turma a partir de um pacote": a
materialização de série que cai numa turma existente passa o `package_id` na entrada em vez de um
`set_package` separado.

## Massa por pacote opera sobre PRESENÇAS, não sobre o bloco (docs/09 §3.1.1 ponto 3)

`bulk_adjust`/`bulk_cancel` do pacote resolvem o alvo como o **conjunto de `attendance`s** daquele
`package_id` (escopo `esta`|`proximas`|`todas`). Por presença:

- **cancelar/remover** → tira o participante do bloco (destrói a `Attendance`); os demais ficam. Se
  era a última presença viva do bloco, cancela o bloco; senão emite `participant_removed`.
- **remarcar** → destaca a presença do bloco antigo e a reinsere no novo (fundindo em turma com
  vaga, ou bloco novo) — o `join`/`push` da materialização, agora por presença; emite
  `participant_removed` no antigo e `participant_added` no novo.

Não há rota nova: são os mesmos `POST /packages/:id/bulk_adjust` e `/bulk_cancel`; muda a semântica
de execução. Um pacote 100% individual continua cancelando/remarcando `appointment`s.

## Sequência (TDD, cada etapa fechável e testada)

1. ✅ **Presença por participante (backend):** ações `mark_present`/`mark_absent`/
   `reopen_attendance`/`justify_absence` + `RollupBlockStatus` + policies + version guard.
   Sub-rotas no controller. Gate `:rls`. *(As ações de bloco ficaram — ver o aviso no topo.)*
2. ✅ **`add_participant` com `package_id`** + validação de dono. Entrou também no `:schedule`, e
   o `set_package` de fora (`Sessions.stamp/3`) **saiu**: o vínculo nasce com a presença.
3. ✅ **Massa por pacote** (`bulk_adjust`/`bulk_cancel`) sobre presenças, com
   `Appointment.remove_participant` (evento `participant_removed`) e o guard do último
   participante — esvaziar o bloco deixaria horário ocupado que não é sessão de ninguém.
4. ✅ **Frontend:** presença por linha no drawer (turma e individual), massa no cartão do pacote.
   A verificação ao vivo achou um bug real: o form da presença submetia **antes do flush** do
   Svelte e ia vazio (400). Conserto + regressão que afirma no momento do submit.
5. ✅ **Notificações** #46 (`:faltou` por presença — o notifier passou a escutar a `Attendance`)
   e #47 (`participant_added`).

## Raio de alcance (o que a etapa 1 toca)

`Appointment` (remover 3 ações + a cascata), `Attendance` (4 ações novas), `AppointmentsController`
(sub-rotas, aposentar as de bloco), a UI do drawer (etapa 4), notificação #46 (etapa 5), a trilha
(as transições agora versionam a `Attendance`, que já tem paper_trail). `Patient.faltas` já conta
`Attendance` — não muda. Sem migração de dados (o enum fica; presenças já consistentes).
