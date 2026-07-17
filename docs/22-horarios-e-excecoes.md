# 22 — Horário e Exceções (configuração da clínica)

Terceira fatia de **gestão da clínica**, depois de [Membros](../CLAUDE.md) e
[Tipos de atendimento](20-tipos-de-atendimento.md). Torna editáveis o **horário semanal da
clínica** e as **exceções de data da clínica** (feriados, dias fechados, expediente reduzido)
que até aqui vinham do seed do protótipo. Vertical completa — domínio Ash + RLS + HTTP + BFF +
duas telas, com TDD.

Referência no protótipo `interface/Movimento.dc.html`:

| Tela | Render | Ações | Seed |
| --- | --- | --- | --- |
| **Horário** (`/configuracoes/horario`) | `cfgHorario()` [`:3239`] | `saveHours` [`:885`], `discardHours`, `espelhar` [`:3249`] | `hours` [`:172`] |
| **Exceções** (`/configuracoes/excecoes`) | `cfgFeriados()` [`:3266`] (título *"Exceções da agenda"*) | `addHoliday` [`:1212`], `rmHoliday` [`:1225`] | `holidays` [`:168`]-[`:170`] |

Editor compartilhado `periodEditor()` [`:3198`] e `switchToggle()` [`:2360`]. Os links
`/configuracoes/horario` e `/configuracoes/excecoes` já existem em
[`web/src/lib/components/shell/nav.ts:51`](../web/src/lib/components/shell/nav.ts) apontando
para 404.

O domínio `Scheduling` está **desenhado mas não codado** ([`01:663`](01-dominio-ash.md)-[`01:770`](01-dominio-ash.md)),
e com o namespace de projeto antigo (`Movimento.*`). **Esta fatia cria `Api.Scheduling` do zero**,
começando por `ClinicHours` e `ScheduleException`. `ProfessionalHours` e a exceção por
profissional ficam para a seção **Profissionais** (§5).

## 0. Três "horário" — a ambiguidade que o protótipo carrega

O protótipo tem **três** noções de horário empilhadas, e a disponibilidade real é a composição
das três (`dayPeriods` [`:854`]):

| | O quê | Onde | Recurso |
| --- | --- | --- | --- |
| **(a)** | **Horário semanal da clínica** — o expediente | `hours` [`:172`], `cfgHorario` | `ClinicHours` |
| **(b)** | **Exceção de data da clínica** — feriado / dia fechado / expediente reduzido | `holidays` [`:168`], `cfgFeriados` | `ScheduleException` (`professional_id` nulo) |
| **(c)** | **Horário e exceção do profissional** — grade própria e folgas, sempre dentro de (a) | `prof.avail`/`prof.exc` [`:61`]-[`:68`], modal do profissional | `ProfessionalHours` + `ScheduleException` (`professional_id` preenchido) |

**Esta fatia entrega (a) e (b)** — o que a UI chama de "configuração da clínica". **(c)** vem com
a seção Profissionais e **reusa o mesmo recurso `ScheduleException`** (por isso ele já nasce
polimórfico, §2). A precedência que amarra as três é o motor de disponibilidade da agenda (§5),
que não existe ainda.

## 1. Decisões

| # | Decisão | Escolha | Por quê |
| --- | --- | --- | --- |
| H1 | Escopo | Só o nível da **clínica**: (a) + (b) | Bate com o nav e com "configuração da clínica"; fecha a fatia. `ScheduleException` já nasce polimórfico, então o profissional reusa sem retrabalho (§5) |
| H2 | Impacto retroativo na agenda (`futureConflicts`) | **Motor adiado, contrato mantido** | `Appointment` não existe ([`01:537`](01-dominio-ash.md)+) — não há agendamento futuro com que conflitar. Os endpoints de escrita já aceitam `confirm`, mas hoje aplicam direto. Registrado em §6, igual ao "editar duração" adiado ([`20:150`](20-tipos-de-atendimento.md)) |
| H3 | Duas exceções na mesma data | **Proibido** (422), única por `(data, professional_id)` | O protótipo aceita duplicatas e `dayPeriods` [`:854`] silenciosamente usa só a 1ª (`.find`) — bug latente. Mesmo espírito do T7 (nome único) em tipos |
| H4 | Excluir exceção | **DELETE de verdade** (`Trash2`) | Divergência consciente de T2/T9 (tipos arquiva): uma exceção é uma linha de data **sem FK dependente** — apagar não deixa nada pendurado. Fiel a `rmHoliday` [`:1225`] |
| H5 | Salvar horário | Rascunho + **Salvar/Descartar** explícitos (não auto-save) | Fiel a `hoursDraft`/`saveHours`/`discardHours` [`:885`]: banner "Alterações não salvas", edição da semana inteira, um único PATCH |
| H6 | `tipo` da exceção | `:fechado` \| `:horario` | Verbatim do protótipo (`tipo:'fechado'`/`'horario'` [`:168`]). **Corrige** [`09:463`](09-contrato-api.md), que grafou `feriado` |
| H7 | Acesso | Todos os membros **leem**; só owner/admin **escrevem** | Espelha Membros e Tipos ([`09:460`](09-contrato-api.md)); a agenda inteira depende de ler o expediente |

### Decisões tomadas por padrão (sem pergunta)

- **Validação de servidor** (hardening, no molde do `one_of` de tipos): cada período é `"HH:MM"`
  válido, `início < fim`, **sem sobreposição** e ordenado por início. O protótipo não valida
  (`cfgHorario` só marca `bad` visualmente no editor do profissional); aceitar lixo do cliente
  abriria superfície. `[]` = fechado é legítimo, não erro.
- **Exceção `:horario` exige `periods`**; `:fechado` ignora `periods` (fica `[]`). Verbatim de
  [`01:758`](01-dominio-ash.md).
- **Sem checar exceção contra o expediente**: uma exceção `:horario` da clínica **redefine** o
  expediente daquele dia — não há envelope a respeitar (ela *é* a clínica). O "deve ficar dentro
  do horário da clínica" só vale para o profissional (§5).
- **Nomes na wire**: `dow`, `periods`, `data`, `nome`, `tipo` — português, como o resto
  (`papel`, `nome`, `professional_id`). `clinic_id` **nunca** no corpo; vem do `Ash.Scope`
  ([`09:8`](09-contrato-api.md)).
- **Rotas**: `/api/clinic-hours` (semana) e `/api/clinic-exceptions`. O `09:462` previa
  `/holidays`; "exceção" descreve melhor (feriado é um caso). **Corrige o 09.**
- **Ordem dos dias na UI**: `[1,2,3,4,5,6,0]` (Seg→Dom), fiel a `cfgHorario` [`:3239`].
- **Padrão da grade** (`step`) do `<input type=time>`: `900` (15 min), fiel ao protótipo. Sem
  vínculo com `slot_minutos` da clínica — são coisas diferentes.

## 2. Modelo — domínio `Api.Scheduling`

Novo domínio. Ambos os recursos por tenant (`strategy :attribute`, `clinic_id`), espelhando
`AppointmentType`: RLS em migration própria, índice em `clinic_id`,
`reference :clinic, on_delete: :delete`.

### `Api.Scheduling.ClinicHours` — horário semanal

Uma linha por dia-da-semana (`dow 0..6`). `periods = []` ⇒ fechado nesse dia.

| Atributo | Tipo | Regras |
| --- | --- | --- |
| `dow` | `:integer` | 0–6, **único por clínica** (identity `one_per_dow`) |
| `periods` | `{:array, {:array, :string}}` | pares `"HH:MM"`; validados (ver §1); `[]` = fechado |

**Ações**: `defaults [:read]`; `update` (a UI edita a semana inteira e manda tudo, mas a
persistência é linha-a-linha por `dow`; a code interface `update_clinic_hours/2` recebe o mapa
`%{dow => periods}` e faz o upsert das 7 linhas numa transação, arg `confirm` para H2).

**Policies**: `read` → `HasClinicRole roles: :any, clinic_from: :tenant`; `update` →
`HasClinicRole roles: [:owner, :admin], clinic_from: :tenant`.

**Seed no `onboard`** — 7 linhas, verbatim de `hours` [`:172`]:

| dow | dia | periods |
| --- | --- | --- |
| 1–5 | Seg–Sex | `[["08:00","12:00"],["13:00","18:00"]]` |
| 6 | Sábado | `[["08:00","12:00"]]` |
| 0 | Domingo | `[]` (fechado) |

Change `Api.Accounts.Clinic.Changes.SeedClinicHours` espelhando `SeedAppointmentTypes` — inclui
**setar a GUC de tenant na mão** (`onboard` é ação global, transação sem tenant → a RLS barraria
o INSERT). Helper `Api.Scheduling.seed_clinic_hours/2`.

### `Api.Scheduling.ScheduleException` — feriado/exceção (polimórfico)

Mesma forma de `holidays` da clínica e de `prof.exc` — **um recurso, polimórfico pelo dono**.

| Atributo | Tipo | Regras |
| --- | --- | --- |
| `data` | `:date` | obrigatório |
| `nome` | `:string` | opcional, 0–120 |
| `tipo` | `:fechado \| :horario` | obrigatório |
| `periods` | `{:array, {:array, :string}}` | `present` sse `:horario` ([`01:758`](01-dominio-ash.md)); validados (§1) |
| `professional_id` | `belongs_to` nullable | **nil = clínica** (esta fatia); preenchido = profissional (§5) |

Identity **`one_per_data_prof [:data, :professional_id]`** (H3). Nesta fatia a UI só cria/lê/apaga
com `professional_id` nulo.

**Ações**: `defaults [:read]`; `create` (arg `confirm`, H2); `destroy` (H4).

**Policies**: iguais a `ClinicHours` (read = any; create/destroy = owner/admin).

## 3. Contrato HTTP

JSON simples (não JSON:API), como `MembersController`/`AppointmentTypesController`. Escada de
erros idêntica: `401` sem sessão · `403` papel · `404` inexistente/fora do tenant ·
`422 {"error":"invalid","details":[…]}`. Sem paginação.

```jsonc
// clinic-hours: a semana inteira
{ "clinic_hours": { "0": [], "1": [["08:00","12:00"],["13:00","18:00"]], … "6": [["08:00","12:00"]] } }

// clinic-exception
{ "id": "…", "data": "2026-07-24", "nome": "Expediente reduzido",
  "tipo": "horario", "periods": [["08:00","12:00"]] }
```

| Método | Rota | Papéis | Retorno |
| --- | --- | --- | --- |
| GET | `/api/clinic-hours` | todos | `200 { "clinic_hours": {dow: periods} }` |
| PATCH | `/api/clinic-hours` | owner/admin | `200 { "clinic_hours": {…} }` — semana inteira; `confirm` aceito (H2) |
| GET | `/api/clinic-exceptions` | todos | `200 { "clinic_exceptions": [...] }` — só `professional_id` nulo, ordenado por `data` |
| POST | `/api/clinic-exceptions` | owner/admin | `201 { "clinic_exception": {…} }` — `confirm` aceito (H2) |
| DELETE | `/api/clinic-exceptions/:id` | owner/admin | `204` |

`clinic_id` **nunca** no corpo. `professional_id` **não** entra no corpo nesta fatia (é sempre
nulo; a rota é "da clínica").

## 4. Fidelidade ao protótipo

### Horário (`cfgHorario` [`:3239`])

| Aspecto | Protótipo | Aqui |
| --- | --- | --- |
| Título | *"Horário de atendimento da clínica"* | ✅ |
| Espelhar | botão *"Espelhar Seg → Seg–Sex"* (`Copy`), copia Seg para 2–5 [`:3249`] | ✅ |
| Linha do dia | rótulo (90px) · `periodEditor` ou *"Fechado"* · `switchToggle` + Aberto/Fechado | ✅ |
| Multi-período | manhã/tarde com almoço; botão *"+ período"* tracejado | ✅ (`PeriodEditor` compartilhado) |
| Rascunho | banner *"Alterações não salvas"* (`Circle` warning) + Descartar + Salvar | ✅ (H5) |
| Toast | *"Horário da clínica salvo"* / *"Alterações descartadas"* | ✅ verbatim |
| Aviso | *"Ao salvar, verificamos conflitos com agendamentos futuros."* | mantido como texto; motor adiado (H2/§6) |

### Exceções (`cfgFeriados` [`:3266`])

| Aspecto | Protótipo | Aqui |
| --- | --- | --- |
| Título / texto | *"Exceções da agenda"* + *"Datas específicas que fogem ao horário normal…"* | ✅ |
| Form | data + descrição + segmented *"Fechar o dia inteiro"* / *"Horário específico"* + períodos condicionais + *"Adicionar exceção"* | ✅ |
| Lista | ordenada por data, ícone `Clock`(horário)/`CalendarOff`(fechado), data mono, `Trash2` remove | ✅ |
| Toast | *"Exceção adicionada"* | ✅ verbatim |
| **Data duplicada** | aceita (usa a 1ª) | **422** (H3) |
| **Ações p/ não-admin** | sempre visíveis | **ocultas** (H7) |

**Componentes compartilhados extraídos** (o `periodEditor` do protótipo é explicitamente reusável):
`PeriodEditor.svelte`, `SwitchToggle.svelte` — os Profissionais reusam ambos em (c).

## 5. Reflexo futuro — agenda e profissionais (desenhado, não construído)

O que esta fatia deixa pronto para as próximas:

- **`ScheduleException` polimórfico**: a exceção por profissional (folga/férias/horário pontual)
  é a **mesma tabela** com `professional_id` preenchido. A seção Profissionais só acrescenta UI
  e um endpoint escopado por profissional.
- **`ClinicHours` como envelope**: `ProfessionalHours` (a grade própria do profissional) valida
  *"deve ficar dentro do horário da clínica"* contra estas linhas — o `min/max` do editor do
  profissional sai daqui (`dayRow` do protótipo [`:301174`]).
- **Motor de disponibilidade da agenda** (`dayPeriods` [`:854`], precedência de 4 camadas:
  exceção-que-fecha da clínica › exceção do profissional › horário especial da clínica › horário
  semanal). Quando a agenda existir, é ela quem consome os dois recursos desta fatia. O
  `futureConflicts` [`:864`] (H2) roda a checagem prévia de `confirm` sobre os agendamentos.

## 6. Adiado (registrado, não implementado)

A agenda não existe — estes só mordem a partir da Fatia de agenda:

- **`futureConflicts` real** (H2): PATCH `/clinic-hours` e POST `/clinic-exceptions` que fechariam
  o dia ou reduziriam o expediente devem, quando houver agendamento futuro, retornar a lista de
  afetados e exigir `confirm: true` ([`09:472`](09-contrato-api.md), D12). Hoje aplicam direto; o
  argumento `confirm` já viaja para o contrato não mudar.
- **Exceção por profissional (c)**: `ProfessionalHours` + UI na seção Profissionais (§5).
- **Data passada**: hoje aceita exceção em data já vencida (fiel ao protótipo). Reavaliar quando a
  agenda materializar sessões.
- **Timezone**: `data` é `:date` no fuso da clínica (`Clinic.timezone`); a conversão para a régua
  da agenda é problema da Fatia de agenda.
