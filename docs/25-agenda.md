# 25 — Agenda (a fatia de risco)

Primeira fatia do **produto** propriamente dito, depois de toda a gestão da clínica
([Membros](../CLAUDE.md), [Tipos](20-tipos-de-atendimento.md),
[Horário e Exceções](22-horarios-e-excecoes.md), Profissionais, Pacientes). A agenda é o
coração do sistema e concentra quase todo o risco técnico que ainda não foi tocado:
exclusion constraint no Postgres, relógio injetável com consequência de negócio, motor de
disponibilidade no servidor, PubSub em tempo real e o primeiro port não-mecânico de um
algoritmo do protótipo (`layoutAppts`). O roadmap já a nomeia como a fatia certa para atacar
primeiro por esse motivo — *"a agenda **é** o risco"* ([`08:135`](08-roadmap.md)). Ela chega
por último aqui porque as fatias de cadastro foram construídas fora de ordem; a consequência
disso está registrada em §0.

Referência no protótipo `interface/Movimento.dc.html`:

| Tela | Render | Ações | Seed |
| --- | --- | --- | --- |
| **Agenda — barra + visões** | `renderAgenda` [`:1537`], `renderDayGrid` [`:1588`], `renderWeek` [`:1732`], `renderMonth` [`:1749`], `renderList` [`:1779`], `renderAgendaMobile` [`:1703`] | `navShift` [`:1184`], `goToday` [`:1185`], `emptyClick` [`:1656`] | `appts` [`:133`]-[`:198`] |
| **Bloco e raias** | `renderBlock` [`:1666`], `layoutAppts` [`:1577`], `ppm` [`:1228`] | `startDrag` [`:1231`], `commitMove` [`:1268`], `startPan` [`:1269`] | `statusMeta` [`:810`] |
| **Drawer do agendamento** | `renderDrawer` [`:1800`] | `setStatus` [`:1032`], `openRemarcar` [`:1132`], `justificarFalta` [`:1121`] | — |
| **Modais** | `modalNovoAgendamento` [`:1965`], `modalRemarcar` [`:2266`], `modalOverride` [`:2293`], `modalHorarioConflitos` [`:2305`] | `createAppt` [`:1048`], `saveRemarcar` [`:1133`] | — |
| **Fila de espera** | `renderFila` [`:2835`], `modalAddFila` [`:2197`], `modalOferecer` [`:2621`], `modalQuemCabe` [`:2250`] | `filaVagas` [`:2532`], `offerVaga` [`:2597`], `addFila` [`:1187`] | `fila` [`:161`] |
| **Motores puros** | `dayPeriods` [`:854`], `checkAvail` [`:894`], `checkConflict` [`:834`], `futureConflicts` [`:864`] | — | `hours` [`:172`], `holidays` [`:168`] |

O link `/agenda` já existe em
[`web/src/lib/components/shell/nav.ts:35`](../web/src/lib/components/shell/nav.ts) apontando
para o catch-all 404 (`(app)/[...notfound]/+page.ts`).

## 0. A armadilha — "agenda" é seis fatias, não uma

O protótipo apresenta como uma tela única o que o roadmap já quebrou em seis entregas
independentes. Transcrever o `renderAgenda` inteiro seria construir metade do produto de uma
vez. O que é de quem:

| | O quê | Onde no protótipo | Fatia ([`08`](08-roadmap.md)) |
| --- | --- | --- | --- |
| **(a)** | Ler a agenda de **um dia** + **criar** agendamento | `renderDayGrid` [`:1588`], `createAppt` [`:1048`] | **Fatia 1 — esta** |
| **(b)** | Remarcar (arraste e modal), concluir, faltar, cancelar | `startDrag` [`:1231`], `setStatus` [`:1032`] | Fatia 2 |
| **(c)** | Pacote: `pkgId`/`pkgOf`/`pkgHold`, série, débito, massa | `computeSerie` [`:1081`], `applyMassaPacote` [`:1149`] | Fatia 3 |
| **(d)** | Fila de espera, oferta de vaga, `SlotHold` | `filaVagas` [`:2532`], `offerVaga` [`:2597`] | Fatia 4 |
| **(e)** | Turma com presença por participante | `patientIds` [`:150`], `removeParticipant` [`:1069`] | Fatia 5 |
| **(f)** | `futureConflicts` ligado à edição de horário | `futureConflicts` [`:864`] | Fatia 7 |
| **(g)** | Ocupação, carga, taxa de falta, relatórios | `occupancy` [`:908`], `reports2` [`:3335`] | Fatia 9 |

**Esta fatia entrega (a)**, com o desenho de (c) e (e) **presente no schema** — porque
`Attendance`, `package_id`, `encaixe` e `version` mudam tabela depois e não podem esperar. O
resto vai para §9.

**Divergência do roadmap a registrar**: [`08:164`](08-roadmap.md) previa que nesta fatia
*"as camadas de origem (horário da clínica, feriado, horário do profissional) vêm do seed"*,
com a edição só na Fatia 7. Como as fatias 20 e 22 foram entregues antes, o motor de
disponibilidade já nasce consumindo **dado real** (`ClinicHours`, `ProfessionalHours`,
`ScheduleException`). **Isto corrige [`08:164`](08-roadmap.md).**

Nota de nomenclatura: [`10:35`](10-decisoes-de-produto-v1.md) chama a exclusion constraint de
"GAP-02" e [`02:496`](02-regras-e-lacunas.md) usa GAP-02 para `settings.slot`. Aqui vale a
numeração do 02; a constraint é citada pelo nome (`appointments_no_overlap`).

## 1. O que o protótipo faz

### Barra de navegação e visões

Barra própria [`:1546`]: setas ← / →, botão **"Hoje"** (destacado quando a data já é hoje),
rótulo contextual (*"quinta-feira, 25 de junho"* · *"25 jun. – 30 jun."* · *"junho de 2026"*,
com o sufixo **" · hoje"**) e um segmented control **"Dia" | "Semana" | "Mês" | "Lista"**.
`navShift` [`:1184`] muda o passo conforme a visão: ±1 dia, ±7 dias, ±1 mês. **Não há barra de
filtros**: nem busca, nem filtro por tipo, nem por status, nem date-picker. O único filtro é o
toggle por profissional na sidebar (`hiddenProfs`, [`:1416`] — que, note-se, **não existe no
state inicial**; nasce sob demanda). O controle de densidade está implementado (`densBtn`
[`:1544`], `ppm` 0.82/1.05/1.4) mas **nunca é renderizado** — código morto.

### O grid do dia

Único grid temporal de verdade [`:1588`]. Colunas por profissional ativo e não oculto, na ordem
do array; não há coluna por sala ou tipo (`kind: 'prof'` é o único valor). Eixo vertical **fixo
08:00–18:00** (480–1080 min), independente do horário configurado — linhas cheias por hora,
tracejadas por meia hora, faixa de **almoço hachurada 12:00–13:00 hardcoded** com o rótulo
**"ALMOÇO"** (decorativo: `pointerEvents:'none'`, não bloqueia o clique), e a linha do "agora" em
702 min com o chip **"11:42"** — ambos cravados. Auto-scroll na montagem deixa o "agora" visível.
Gutter de horas 54px sticky; cabeçalho de coluna 66px sticky com avatar, nome, CREFITO, contador
e barra de carga. Clicar em vazio abre o modal pré-preenchido com profissional, data e hora
arredondada a 15 min [`:1656`]. O fundo é "pannable" [`:1269`].

Sobreposição vira **raias** (`layoutAppts` [`:1577`]): clusters de intervalos que se tocam,
distribuídos na primeira faixa livre; todos do cluster recebem o mesmo `lanes`, e a coluna
alarga (`maxLanes × 152px` em vez de 210px). Sempre sobra uma faixa de 24px à direita para
clicar em vazio mesmo com a coluna lotada.

### O bloco

Posição e altura por minuto × `ppm`. Ordem de precedência visual: **"AÇÃO"** (`needsAction`
[`:828`] — já terminou e ainda está `agendado`/`confirmado`) > conflito (borda vermelha 1.5px +
`TriangleAlert`, `zIndex 3`) > tint da cor do status. `concluido` a 72% de opacidade;
`cancelado` riscado; `em_atendimento` com ponto pulsante; encaixe com badge laranja
**"ENCAIXE"**; pacote com tarja vertical de 3px + chip `Package`. Rótulo por altura: >30px nome
em 12px negrito, >58px a terceira linha (avatares da turma até 3 + "+N", ou nome do tipo). Turma
mostra **"Pilates · 3/4"**.

Seis status (`statusMeta` [`:810`]): **"Agendado"**, **"Confirmado"**, **"Em atendimento"**,
**"Concluído"**, **"Faltou"**, **"Cancelado"** — mas **nenhuma ação da UI produz `confirmado`
nem `em_atendimento`**: eles só nascem no seed, e o botão **"Enviar confirmação"** apenas emite
o toast *"Confirmação enviada por WhatsApp"* [`:1846`].

### Semana, mês e lista

**Não são grids**: são contadores. Semana [`:1732`] mostra 6 cartões (seg–sáb, domingo nunca
aparece) com **"N agend."** e uma barra cujo denominador é a constante **45**. Mês [`:1749`]
monta 42 células a partir de domingo, cortadas em `usedWeeks`, com barra normalizada pelo pico do
próprio mês — a mesma quantidade pinta diferente nas duas visões. Nenhuma das duas mostra
horário, paciente, profissional ou conflito, e nenhuma marca dia fechado por feriado. Lista
[`:1779`] é linear: hora mono, avatar, nome (ou **"Pilates · 3 pacientes"**), *"tipo ·
profissional"*, selo **"Encaixe"** e pílula de status — e, ao contrário de semana e mês,
**inclui cancelados** e **ignora `hiddenProfs`**.

### O drawer

Painel de 404px [`:1800`] aberto ao clicar num bloco. Contém: pílula de status + badge
**"ENCAIXE"**; linhas **"Horário"** (`08:00–08:50 (50min)`, mono) e **"Tipo"**; cartão
**"Sessão de pacote · pos/total"** quando aplicável; bloco **"Falta justificada"** (só com
status `faltou`); lista **"Pacientes na turma"** com contador `N/cap`, busca para adicionar
(some quando lota, virando **"Turma cheia"**) e remover; ou cartão do paciente com telefone,
**"Faltas"** e **"Abrir ficha →"**; botão **"Remarcar sessão"**; grid **"Mudar status"** com
**"Concluir"** / **"Faltou"** / **"Cancelar"** — os dois primeiros desabilitados até a sessão
começar, com title *"Disponível após o horário da sessão"*; e um rodapé com **"Enviar
confirmação"** e uma **lixeira que exclui sem confirmação e sem desfazer** [`:1847`].

### Os modais

**"Novo agendamento"** / **"Novo agendamento em grupo"** / **"Adicionar à turma"** [`:1965`]:
busca de paciente (≥2 caracteres, por nome sem acento ou dígitos de CPF/telefone, máx. 10 com
*"Mostrando 10 de N — refine a busca"*), profissional, tipo, data, hora (`step=900`), checkbox
**"Encaixe"** e três avisos distintos — conflito (*"Conflito: Sobrenome já tem agendamento às
HH:MM. Marque 'Encaixe' para forçar."*), capacidade (*"A turma ficaria com N/cap…"*) e
disponibilidade (texto cru de `checkAvail`, **sem instrução de contorno, porque não há**).
**"Remarcar sessão"** [`:2266`] move só aquela sessão. **"Conflito detectado"** [`:2293`], vindo
do arraste, oferece três saídas: **"Cancelar"**, **"Como encaixe"** e **"Mover assim mesmo"** —
esta última deixa o conflito real e visível. **"Ajuste a agenda antes de salvar"** [`:2305`] é o
bloqueio de mudança de expediente: lista os afetados, oferece **"Ver na agenda"** e um único
botão **"Entendi"** — nada é salvo.

### Arraste e conflitos

`startDrag` [`:1231`] com ghost tracejado teal, snap de 15 min, clamp em `[480, 1080 − dur]`,
troca de coluna livre pelo eixo X e **a data nunca muda**. No drop valida **somente
sobreposição** — não valida expediente (dá para arrastar para dentro do almoço, de um feriado ou
de um profissional que não atende no dia), não valida capacidade e não faz merge. É o **GAP-03**:
o formulário é rígido e o arraste é permissivo, para a mesma regra. Conflito é sempre **por
profissional**, sobreposição estrita (encostar fim-com-início não conta), ignorando encaixes e
cancelados nos dois sentidos.

### Encaixe

Flag booleano que **isenta o agendamento de toda checagem de conflito** — não acusa e não é
acusado [`:830`], [`:835`] — e permite exceder a capacidade da turma. **Não** libera
indisponibilidade: `canSave` exige `!avail` [`:2001`], então nem admin agenda em feriado. É
permanente: cancelado o conflitante, o selo fica.

### Fila de espera

Entidade separada [`:161`]: paciente, prioridade (**"Urgente"**/**"Alta"**/**"Normal"**/
**"Baixa"**), profissionais preferidos (vazio = qualquer), janela (**"Manhã"**/**"Tarde"**/
**"Qualquer"**), regras polimórficas (por dias da semana ou por data, cada uma com 1..N faixas)
e observação. O motor `filaVagas` [`:2532`] varre 14 dias com passo de 30 min e duração fixa de
50, devolve a **primeira** brecha de cada período mais as vagas que **abriram** (`freed`, de
cancelamento/falta), com teto de 50. **"Oferecer"** só pré-preenche um modal — não reserva nada,
não registra oferta nem recusa; o item sai da fila quando o agendamento é criado, com o toast
*"Agendado — Fulano saiu da fila"*. Marcar falta numa sessão já iniciada abre sozinho, 200ms
depois, o modal **"Quem cabe aqui?"**.

### Mobile

Abaixo de 860px e só na visão Dia, um render dedicado [`:1703`]: faixa sticky de chips por
profissional, **um por vez**, gutter de 34px só com a hora. Perde criar-em-vazio, ghost, pan,
linha do agora e o rótulo do almoço. Semana, mês e lista usam o mesmo render do desktop.

## 2. O que já existe no código

**Pronto e reutilizável sem mudança** (`api/lib/api/scheduling/`): `ClinicHours` (7 linhas por
clínica, upsert por `one_per_dow`), `ProfessionalHours` (`modo :herda | :custom | :fechado`),
`ScheduleException` (polimórfico por `professional_id` nulo/preenchido), o módulo puro `Periods`
(`validate/1`, `within/2`, `to_minutes/1`) e os wrappers transacionais `update_clinic_hours/2` /
`update_professional_hours/3`. Em `api/lib/api/directory/`: `Professional` (com
`segue_horario_clinica` e `cor_indice`) e `AppointmentType` (`duracao_minutos`, `grupo`,
`capacidade`, `cor`, `icon`, **sem `destroy`** — só `archive`/`restore`, exatamente porque
`Appointment.appointment_type_id` seria `allow_nil? false`). Em `api/lib/api/records/`:
`Patient` com `prefs` (profissionais preferidos, `{:array, :uuid}` **sem FK** — precedente que
justifica o `package_id` sem FK aqui).

Padrões estabelecidos que esta fatia herda: tenancy por atributo + `Api.Tenancy.in_clinic/2` +
`SetTenantGuc` + RLS em migration à mão; `ApiWeb.TenantScope` com `with_admin_scope` /
`with_member_scope` e a escada 401/403/404/422; controllers com `whitelist/2` e `write/4`
(fetch-then-update para poder devolver 404); JSON montado à mão omitindo `clinic_id`.

**Parcial**: `Clinic.slot_minutos` (default 15) e `AppointmentType.duracao_minutos` existem e
**ninguém os consome** — é o GAP-02 replicado no código real. `GET /api/realtime/token` existe
(`auth_controller.ex:123`) mas não há Channel, socket nem notifier. Os endpoints
`PATCH /api/clinic-hours` e `POST /api/clinic-exceptions` **aceitam e ignoram** um `confirm`
(H2, [`22:47`](22-horarios-e-excecoes.md)).

**Não existe absolutamente nada** de: `Appointment`, `Attendance`, `SlotHold`, fila, motor de
disponibilidade (`Api.Scheduling` só tem leitores crus — a composição das 4 camadas é feita **no
cliente**, por `resolveWeekday` em `web/src/lib/professionals.ts:154`), motor de conflitos,
`ImpactAnalysis`, e nenhuma rota de agenda. `AshJsonApi` está montado mas vazio (`Api.Meta` com
`routes do end`); toda a API real é controller Phoenix à mão.

No web: a rota `/agenda` cai no catch-all 404, embora `nav.ts` já tenha a seção, o `sectionOf` e
o item de rail. `Sidebar.svelte` tem ramos para `config`, `profissionais` e `pacientes` e
**nenhum** para `agenda`. Já existem `Modal`, `ConfirmDialog`, `Toast`, `Button`, `Field`,
`SwitchToggle`, `PeriodEditor`, `WeeklyHoursEditor`, `avatarColor` (cujo comentário diz
literalmente *"paleta categórica dos avatares da agenda"*), `tint`/`iconComponent` e o helper
`navigate(patch)` de `pacientes/+page.svelte:53`.

## 3. Decisões

| # | Decisão | Escolha | Por quê |
| --- | --- | --- | --- |
| A1 | Escopo | Só **(a)**: visão Dia + criar | [`08:135`](08-roadmap.md) — *"sem remarcar, sem concluir, sem faltar"*. Semana/Mês/Lista em §9 |
| A2 | Tempo | `starts_at`/`ends_at` **`:utc_datetime`** | Divergência deliberada do protótipo (minuto-do-dia), já registrada em [`12:158`](12-divergencias-interface-vs-regras.md). `tstzrange` da constraint exige absoluto |
| A3 | Duração | Snapshot de `AppointmentType.duracao_minutos` no `ends_at` | Fiel a [`:150`] (o protótipo copia `dur` do tipo). Mudar o tipo depois **não** mexe em agendamento existente |
| A4 | Presença | `Attendance` por participante desde já | D10/D11 ([`10:89`](10-decisoes-de-produto-v1.md)); dissolve o mapa `pkgOf`. GAP-07 é *"a lacuna mais séria"* ([`02:570`](02-regras-e-lacunas.md)). Sem isso a Fatia 3 refaz a agenda |
| A5 | Não-sobreposição | **Exclusion constraint** no Postgres, não validação | [`04:7.1`](04-arquitetura.md). Pré-checagem em Elixir é aviso, não garantia |
| A6 | Disponibilidade | Validação Ash → **422**; independente do conflito | RN-14 ([`02:160`](02-regras-e-lacunas.md)): as duas checagens são obrigatórias e separadas |
| A7 | Leitura | Profissional vê **só a própria** agenda | D1 ([`10:26`](10-decisoes-de-produto-v1.md)). Exige `FilterCheck` novo — `HasClinicRole` é `SimpleCheck` e não filtra linhas |
| A8 | Escrita | `owner`·`admin`·`recepcao`·`profissional` (este só a própria) | Recepção é quem agenda; o par `with_admin_scope`/`with_member_scope` de hoje não serve |
| A9 | Encaixe | Só `owner`·`admin`·`recepcao` criam | D2 ([`10:32`](10-decisoes-de-produto-v1.md)). **Implementado como policy condicional** sobre `:schedule`, não como ação separada — ver nota |
| A10 | Erro de conflito | **422 sem campo**, com `code` estável | [`09:605`](09-contrato-api.md): pintar `starts_at` de vermelho mente. `409` fica reservado a concorrência |
| A11 | `layoutAppts` | Fica **no cliente**, como função pura | ADR-006 e [`08:183`](08-roadmap.md) — *"o único dos quatro motores que fica no cliente"* |
| A12 | Faixa vertical do grid | Derivada do expediente, não 08–18 fixo | RN-03 ([`02:48`](02-regras-e-lacunas.md)): 08–18 é limite de renderização, não regra. Fecha GAP-05 (almoço decorativo) |

> **Nota sobre A9 (ratificada em 2026-07-19, D6).** O texto original previa uma ação separada
> `:schedule_encaixe`. Foi implementada como **policy condicional** sobre `:schedule`
> (`Checks.CreatingEncaixe`, lendo o **argumento** — o atributo só existe depois do
> `change set_attribute/2`, e a ordem entre policy e change não é garantida). O resultado
> observável é o mesmo que o §7 exige (403 para `profissional`) sem duplicar a ação inteira.
>
> Registro de como isto foi descoberto: a A9 **nunca chegou a ser implementada** na primeira
> passada — o recurso tinha um comentário afirmando que "uma policy decide" e a policy não
> existia. Um `profissional` criava com `encaixe: true`, que é exatamente o predicado que
> **isenta a linha da exclusion constraint**: o papel menos privilegiado desligava a proteção
> contra dupla-marcação mandando um booleano no corpo. Achado pelo bate-volta
> ([26](26-auditoria-bate-volta-agenda.md) §3).

### Decisões tomadas por padrão (sem pergunta)

- **Validação de servidor sempre**: cabe no expediente, tipo/profissional/paciente ativos,
  duração positiva. O cliente antecipa por ergonomia; o veredito é do servidor
  ([`09:8`](09-contrato-api.md)).
- **Ações nomeadas, nunca `PATCH` de `status`**: `:schedule` aqui; `:mark_completed` etc. na
  Fatia 2. Mesma convenção de `archive`/`restore` (tipos) e `deactivate` (profissionais).
- **`clinic_id` nunca no corpo** — vem do `Ash.Scope`.
- **Nomes na wire em português** onde já são domínio (`encaixe`, `tipo`), em inglês onde são
  estrutura (`starts_at`, `professional_id`), como o resto do projeto.
- **Estado navegável na URL**: `?date=`, `?view=`, `?profs=` — o mesmo padrão de `?status=`
  (profissionais) e `?q=&filter=&page=` (pacientes). Densidade e profissional-do-mobile são
  preferência, ficam em store.
- **Sem hard delete**: cancelar preserva o registro. Coerente com `AppointmentType` e
  `Professional`, que já não têm `destroy`.

## 4. Modelo — `Api.Scheduling` (extensão)

O domínio já existe com `ClinicHours`, `ProfessionalHours`, `ScheduleException` e o módulo puro
`Periods`. Esta fatia acrescenta dois recursos, dois enums e três motores.

### `Api.Scheduling.Appointment` — o slot

| Atributo | Tipo | Regras |
| --- | --- | --- |
| `starts_at` / `ends_at` | `:utc_datetime` | `ends_at = starts_at + tipo.duracao_minutos` (A3) |
| `status` | `AppointmentStatus` | default `:agendado` |
| `encaixe` | `:boolean` | default `false` — predicado da constraint |
| `version` | `:integer` | default `1` — locking otimista (consumido na Fatia 2) |
| `cancel_reason` | `:string` | nullable — D4, motivo **opcional** |
| `obs` | `:string` | nullable, 0–500 (A-D7). **Pode conter dado clínico**; não é prontuário |
| `duration_minutos` | `:integer` | nullable (A-D8) — sobrepõe o snapshot do tipo quando presente |
| `created_by_id` | `belongs_to :user` | nullable, `relate_actor` (A-D6). Denormalizado para exibição; a autoridade é a trilha |
| `package_id` | `:uuid` | nullable, **sem FK** (gancho da Fatia 3, §9) |
| `pkg_hold` | `:boolean` | default `false` — sessão "segurada"; filtrada de toda leitura (RN-05) |
| `professional_id` | `belongs_to` | `allow_nil? false`, `on_delete: :restrict` |
| `appointment_type_id` | `belongs_to` | `allow_nil? false` — é por isso que T2 fez o tipo **arquivar** e não excluir |

```elixir
# enums novos, no molde de Api.Scheduling.WeekdayMode
AppointmentStatus  [:agendado, :confirmado, :em_atendimento, :concluido, :faltou, :cancelado]
AttendanceStatus   [:prevista, :concluida, :faltou, :cancelada]
```

**Ações**: `read :day` (arg `date`, `professional_ids`; `prepare` filtrando `pkg_hold == false`),
`read :range` (contadores), e `create :schedule` com argumento `patient_ids` — 1 elemento é
individual, N é turma — materializando uma `Attendance` por paciente via `manage_relationship`.
Toda escrita leva `change Api.Tenancy.SetTenantGuc` e, por consequência,
`require_atomic? false` (o moduledoc de `set_tenant_guc.ex` explica o porquê).

**Policies**:

```elixir
policy action_type(:read) do
  authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
  # + FilterCheck OwnProfessionalAgenda: recorta quando papel == :profissional (A7)
end
policy action_type(:create) do
  authorize_if {Api.Accounts.Checks.HasClinicRole,
                roles: [:owner, :admin, :recepcao, :profissional], clinic_from: :tenant}
end
```

> **Fail-open a evitar**: `Membership.professional_id` é `allow_nil? true` — o moduledoc o
> chama de *"UUID mole"*. Existe membro com `papel: :profissional` e `professional_id: nil`.
> O `FilterCheck` precisa **fechar** (lista vazia) nesse caso, nunca degradar para "sem
> filtro". Teste dedicado obrigatório.

### `Api.Scheduling.Attendance` — presença por participante

| Atributo | Tipo | Regras |
| --- | --- | --- |
| `status` | `AttendanceStatus` | default `:prevista` |
| `falta_justificada` | `:boolean` | default `false` (consumido na Fatia 2) |
| `package_id` | `:uuid` | nullable, sem FK — D11: o pacote é **por participante**, não da turma |
| `appointment_id` / `patient_id` | `belongs_to` | identity `one_per_patient_per_appt`, `pre_check? true` |

O `pre_check? true` não é enfeite: sob RLS o Postgres omite o `DETAIL` do `unique_violation` e
o AshPostgres estoura `KeyError` → 500 em vez de 422. Já mordeu em `appointment_type.ex:172` e
`schedule_exception.ex:120`.

`Api.Records.Patient` ganha `count :faltas` derivado daqui — o moduledoc do paciente
(`patient.ex:32`) já diz que o campo ficou de fora *"porque os recursos que os alimentam ainda
não existem"*. Agregado, **nunca** contador denormalizado (o protótipo mantém `p.faltas` na mão
em [`:1038`] e dessincroniza).

### Banco

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- NÃO está em Api.Repo.installed_extensions hoje

ALTER TABLE appointments ADD CONSTRAINT appointments_no_overlap
  EXCLUDE USING gist (professional_id WITH =, tsrange(starts_at, ends_at, '[)') WITH &&)
  WHERE (encaixe = false AND status <> 'cancelado');
```

> **Correção aplicada na implementação (2026-07-19): `tsrange`, não `tstzrange`.** O
> `:utc_datetime` do Ash vira `timestamp(0) **without** time zone`, então `tstzrange` exigiria
> um cast implícito dependente do `TimeZone` da sessão — `STABLE`, não `IMMUTABLE` — e o
> Postgres recusa a criação do índice com `ERROR 42P17`. Como o Ash garante UTC em toda
> escrita, `tsrange` compara exatamente os mesmos instantes. Trocar o tipo da coluna para
> `timestamptz` seria a alternativa, e não vale: reconquistaria um cast que não usamos.

`'[)'` implementa "encostar fim-com-início não é conflito" ([`:832`]); o predicado parcial
implementa RN-12 (encaixe imune) e RN-13 (cancelado não conflita) **no próprio banco**. Por
ADR-017 a constraint **não leva `clinic_id`** — `professional_id` já é único globalmente.

Índices (`clinic_id` lidera, ADR-017): `(clinic_id, professional_id, starts_at)`,
`(clinic_id, starts_at)`, `(package_id)`, e o índice de apoio ao cascade da FK escrito à mão —
mesma razão de `20260716175037_scheduling_index_tuning.exs`.

RLS em migration própria, no molde de `20260716171500_scheduling_rls.exs`. **A suíte conecta
como `postgres` (BYPASSRLS): furo de GUC não aparece em `mix test`** — a fatia de Tipos teve 3
bugs assim. Verificação por `psql` no container faz parte do pronto.

### Motores

- **`Api.Scheduling.Availability.day_periods/3`** — módulo puro, no molde de `Periods`.
  Precedência de 4 camadas, **a primeira decide** (RN-07..10): (A) exceção da clínica
  `tipo != :horario` → fechado para todos (D14, bloqueio absoluto) › (B) exceção do
  profissional › (C) exceção da clínica `:horario` › (D) grade semanal (`:herda` cai em
  `ClinicHours`; `:custom`; `:fechado`; linha ausente cai em `Professional.segue_horario_clinica`).
  Duas assimetrias load-bearing: feriado vence o pontual do profissional (B depois de A); folga
  do profissional vence o horário especial da clínica (B antes de C). E `:fechado` **≠** linha
  ausente (RN-10).
  Hoje isso é resolvido **no cliente**: `professionals_controller.ex:29` devolve `professionals`
  + `clinic_hours` juntos para o `resolveWeekday` do web resolver os `:herda`. Com o motor no
  servidor, `web/src/lib/professionals.ts:154` deixa de ser autoridade e vira formatação.
- **`Api.Scheduling.Conflicts.overlapping/2`** — a pré-checagem que **explica** (aviso vermelho
  no modal). Não substitui a constraint; há janela TOCTOU entre check e insert, e é a constraint
  que fecha.
- **`Api.Scheduling.LocalTime`** — a ponte `"HH:MM"` ↔ UTC. `Periods` fala minuto; `Appointment`
  fala absoluto. Política fixa para o retorno de `DateTime.new/4`: `{:gap, _, depois}` → empurra
  para depois do salto; `{:ambiguous, primeiro, _}` → primeira ocorrência. Testar com um tz que
  tenha DST (`America/Santiago`), porque com `America/Sao_Paulo` o teste passa vazio.

### Dependências de infraestrutura que faltam

| O quê | Estado | Onde |
| --- | --- | --- |
| `btree_gist` | **ausente** | `Api.Repo.installed_extensions/0` devolve `["ash-functions", "citext"]` |
| Banco de timezone (`tz`) | **ausente** | `api/mix.exs`. Sem ele, `DateTime.new/4` com `America/Sao_Paulo` devolve `{:error, :utc_only_time_zone_database}` — e `Clinic.timezone` é decorativo |
| Relógio no `Api.Scope` | **ausente** | `Api.Scope` tem só `[:user, :clinic_id, :papel, :professional_id, :membership]`; e `defimpl Ash.Scope.ToOpts` tem `get_context(_), do: :error` — a mudança **não é aditiva** |
| `phoenix` (npm) | **ausente** | `web/package.json` — necessário para os Channels (ADR-004), só na Entrega 3 |
| `ash_paper_trail` | **ausente** | `api/mix.exs` — exigido pela A-D6(c). Ver §11 |

**Sobre o relógio (ADR-009 / GAP-01)**: o protótipo congela tempo em 22 ocorrências de
`hoje()`, 7 de `NOW` (duas definições, [`:130`] e [`:2533`]) e 8 do literal `702`
([`08:570`](08-roadmap.md)). Portar por transcrição produz bug silencioso. E RN-58
([`02:789`](02-regras-e-lacunas.md)) avisa da sutileza: **"já começou"** (`starts_at <= agora`)
é comparação **diferente** de **"precisa de ação"** (`ends_at <= agora`).

## 5. Contrato HTTP

JSON simples (não JSON:API), como todos os controllers do projeto. Escada de erros:
`401` sem sessão · `403` papel · `404` inexistente/fora do tenant ·
`422 {"error":"invalid","details":[…]}` · **`409` novo** (concorrência).

```jsonc
// POST /api/appointments
{ "starts_at": "2026-07-20T11:00:00Z", "professional_id": "…",
  "appointment_type_id": "…", "patient_ids": ["…"], "encaixe": false }

// 422 sem campo — o canal novo
{ "error": "invalid", "code": "schedule_conflict",
  "details": [{ "field": null, "message": "Esse horário sobrepõe outro agendamento." }],
  "meta": { "conflicting_appointment_id": "…" } }
```

| Método | Rota | Papéis | Retorno |
| --- | --- | --- | --- |
| GET | `/api/appointments?from=&to=&professional_id=` | todos (recortado por A7) | `200 { appointments: [...], professionals: [...], appointment_types: [...] }` |
| POST | `/api/appointments` | owner·admin·recepcao·profissional | `201 { appointment: {…} }` |
| GET | `/api/availability?professional_id=&date_from=&date_to=` | todos | `200 { professionals: [{ professional_id, days: [{ date, periods, closed_reason? }] }] }` — é **cálculo**, não coleção ([`09:253`](09-contrato-api.md)); ação genérica |

`professional_id` em `/availability` aceita **vários**: `a,b,c` ou `professional_id[]` repetido.
Nasceu com um só, e o BFF compensava com uma requisição por coluna do dia — até ~480 leituras
no banco para 10 profissionais ([26 §7 (f)](26-auditoria-bate-volta-agenda.md)). A resposta é
sempre `professionals: [...]`, inclusive para um profissional só: o mesmo endpoint respondendo
em duas formas conforme a quantidade é o defeito que [`09:659`](09-contrato-api.md) já custou a
consertar no 422.

`clinic_id` nunca no corpo. `duration` **não** entra no corpo (A3). Janela máxima de **31 dias**
em `/appointments` → 422 acima disso: sem teto, `?from=2000-01-01&to=2100-01-01` varre a tabela.

**Códigos estáveis**: `schedule_conflict`, `group_full`, `outside_business_hours`,
`closed_by_exception` (422, sem campo); `version_conflict`, `slot_held` (409, Fatias 2 e 4). A
regra semântica é a de [`09:659`](09-contrato-api.md): **422 = "seu pedido está errado";
409 = "seu pedido estava certo, o mundo mudou"**.

Duas mudanças em código compartilhado, ambas aditivas:

- `ApiWeb.TenantScope.error_response/2` hoje cobre 403/404/422/400 — ganha `conflict/3` (409) e
  o `code` no 422. Ganha também `with_scheduling_scope/2` (A8), já que nem
  `with_admin_scope` nem `with_member_scope` servem.
- `web/src/lib/server/mutate.ts:37` hoje **descarta** o `details` e achata tudo em
  *"Dados inválidos. Verifique os campos."* — passa a propagar `{code, details, meta}`. Sem
  isso o fluxo de encaixe é inalcançável pela UI.

## 6. Frontend

Rota nova `routes/(app)/agenda/` (hoje 404). `+page.server.ts` lê `?date=&view=&profs=`, carrega
em `Promise.all` agendamentos + profissionais + tipos + expediente, e devolve também **`agora`
calculado no servidor** — a linha do "agora" e o `needsAction` não podem depender do relógio do
browser.

| Componente | Nota |
| --- | --- |
| `agenda/AgendaNav.svelte` | ← · **"Hoje"** · → · rótulo contextual · segmented **"Dia"** \| **"Semana"** \| **"Mês"** \| **"Lista"**. Navega por `goto()` com `replaceState`, como `pacientes/+page.svelte:53` |
| `agenda/DayGrid.svelte` | Colunas por profissional; faixa vertical **derivada** (A12), estendida para conter agendamento fora dela; hachura o **buraco real** entre períodos por coluna — colunas ficam visualmente diferentes, e isso é correto |
| `agenda/AppointmentBlock.svelte` | Precedência visual: `needsAction` > conflito > tint do status. `<button>`, não `<div>` clicável |
| `agenda/NewAppointmentModal.svelte` | `Modal` com `maxWidth='max-w-[520px]'`. Checkbox **"Encaixe"** só para quem pode (A9) |
| `agenda/PatientPicker.svelte` | ≥2 caracteres, debounce 300ms com limpeza no `onDestroy` (o timer órfão já mordeu) |
| `$lib/agenda.ts` | `STATUS_META`, `m2t`/`t2m`, `started`/`needsAction` (duas fronteiras), `canCreateEncaixe` |
| `$lib/agenda-layout.ts` | **`layoutAppts` isolado**, com teste de propriedade (clusters, `lanes` igual dentro do cluster, `maxLanes`). É o item que [`08:183`](08-roadmap.md) chama de *"primeiro teste de fogo do port não-mecânico"* — merece arquivo e teste próprios |
| `Sidebar.svelte` | Ramo novo: **"Profissionais"** com checkbox de ocultar, **"mostrar todos"**/**"gerenciar"**, e o rodapé **"Ocupação de hoje"** |

Reaproveitado sem mudança: `Modal`, `Button`, `Field`, `Toast`, `avatarColor`/`initials`,
`tint`/`iconComponent` de `$lib/appointment-types.ts`, `WEEKDAYS`/`formatDate` de
`$lib/scheduling.ts`.

**Dois gotchas registrados**: (1) `(app)/+layout.svelte` renderiza `<Sidebar>` **duas vezes**
(desktop e gaveta mobile) — prop nova vai nas duas, foi assim que o bug do CNPJ passou pelos
testes; (2) no protótipo `sbAgenda()` é o ramo `default:` de `sidebarBody` [`:1407`], não um
`case 'agenda'` — o ramo Svelte precisa ser explícito por decisão, não por transcrição.

**Estados vazios** (o protótipo tem um e ele é fácil de esquecer, porque só aparece por ação do
usuário): todos os profissionais ocultos → `EyeOff` + **"Nenhum profissional em exibição"** +
**"Ative ao menos um profissional na barra lateral para ver a agenda."** + **"Mostrar todos"**
[`:1602`]. Dia sem agendamento renderiza o grid vazio, sem mensagem — fiel.

## 7. Regras de negócio e conflitos

| Regra | Onde mora | Como se testa |
| --- | --- | --- |
| Não-sobreposição por profissional | **Exclusion constraint** `appointments_no_overlap` | Duas conexões concorrentes (checkout manual, fora do sandbox): a segunda leva 422, **não 500** |
| Encostar fim-com-início não é conflito | `'[)'` no `tstzrange` | Agendar 08:00–08:50 e 08:50–09:40 no mesmo profissional |
| Encaixe imune nos dois sentidos | Predicado `WHERE encaixe = false` | Encaixe sobre bloco existente passa; bloco novo sobre encaixe passa |
| Cancelado não conflita | Predicado `AND status <> 'cancelado'` | Cancelar e reagendar no mesmo slot |
| Cabe **inteiro em um** período | `Validation` chamando `Availability` → 422 | 11:30–12:20 atravessando o almoço é recusado |
| Precedência de 4 camadas | `Availability.day_periods/3` (puro) | **Tabela-verdade de 15 linhas** de [`02:113`](02-regras-e-lacunas.md)/[`07:2.1`](07-estrategia-de-testes.md) como test table |
| `:fechado` ≠ linha ausente (RN-10) | `ProfessionalHours.modo` | Duas linhas de teste distintas na tabela acima |
| Disponibilidade e conflito são independentes | Duas validações separadas (A6) | Slot livre em feriado → 422; slot ocupado em dia útil → 422 com outro `code` |
| Encaixe **não** libera expediente | Validação sem cláusula `where :encaixe` | Encaixe em feriado é recusado (ver A-D2 em §8) |
| Só admin/recepção criam encaixe | Ação `:schedule_encaixe` + policy (A9) | `profissional` recebe 403 |
| Profissional vê só a própria agenda | `FilterCheck` `OwnProfessionalAgenda` (A7) | Papel a papel; **+ o caso `professional_id: nil`** |
| Tenant | RLS + `SetTenantGuc` em toda escrita | `psql` como role NOBYPASSRLS, um INSERT e um UPDATE |
| Tipo arquivado / profissional ou paciente inativo | `Validation` em `:schedule` → 422 | Um teste por caso; existente continua válido |
| Turma ≤ capacidade | Aggregate `participantes` vs `capacidade \|\| cap_turma_padrao` | Limite e limite+1 (ver A-D3 em §8) |
| `pkg_hold` some de tudo | `prepare` na `read` (RN-05) | Já testável com o campo, mesmo sem pacote |

## 8. Decisões resolvidas (2026-07-19)

As doze perguntas que bloqueavam o início do código, **todas respondidas**. Onde a decisão
divergiu da recomendação original, a divergência está marcada e justificada.

**A-D1 — `slot_minutos` vale no servidor ou só na UI?**
`Clinic.slot_minutos` existe (default 15) e **nada o consome** — mesmo destino do
`settings.slot` do protótipo, que é declarado e nunca lido (GAP-02); lá o snap de 15 min é
hardcoded em [`:1248`]. Opções: (a) só `step` do input e snap do arraste; (b) o servidor rejeita
`starts_at` fora do múltiplo; (c) remover o campo e cravar 15.
**DECIDIDO: (a) — nenhuma regra de servidor.** A UI *sugere* de 15 em 15 (`step` do input, snap
do arraste), mas o usuário pode digitar qualquer horário e salvar normalmente. O servidor valida
expediente e conflito, **não** alinhamento de grade: um encaixe às 10:07 combinado por telefone
não pode morrer de aritmética. `Clinic.slot_minutos` fica sendo ergonomia, não invariante —
registrar isso no moduledoc do `Clinic` para não virar "bug" depois.

**A-D2 — encaixe é isenção total, ou conflito registrado com aviso?**
No protótipo `encaixe: true` desliga a checagem nos dois sentidos ([`:830`], [`:835`]) e o flag é
**permanente**: cancelado o conflitante, o selo fica. Opções: (a) isenção total, fiel; (b)
suprime o **bloqueio**, mas o conflito continua sendo calculado e exibido (borda vermelha +
`TriangleAlert`); (c) reavaliar o flag automaticamente.
**DECIDIDO: (b).** Não muda a constraint (ela é sobre bloqueio, não sobre exibição), e o que
a recepção precisa ver é *"este horário está dobrado"* — (a) esconde justamente a informação que
motivou o encaixe. Descartar (c): apagar automaticamente uma intenção humana registrada.
Consequência confirmada e mantida: **encaixe não libera indisponibilidade** — `canSave` exige
`!avail` em [`:2001`] e [`:2289`], nem admin agenda em feriado (D14).

**A-D3 — capacidade de turma: teto rígido ou soft? E qual código?**
Aberta em [`20:153`](20-tipos-de-atendimento.md). No protótipo é soft (`overCap && !encaixe`
desabilita, [`:1998`]) mas o merge de participantes é **incondicional** — nunca lê `cap`
([`12:80`](12-divergencias-interface-vs-regras.md)); e [`09:268`](09-contrato-api.md) mapeia
"turma cheia" para 409, contradizendo o resto do doc.
**DECIDIDO: teto soft, encaixe fura, com `422 group_full`.** Capacidade de turma é
operacional ("cabe mais um no Pilates?"), não física — enquanto não houver sala/aparelho
modelado. Validar **no servidor** e nos três caminhos (criar, merge, adicionar no drawer),
fechando o furo do protótipo. 409 fica exclusivamente para concorrência.

**A-D4 — o merge idempotente de turma é oficial?**
Omissão registrada em [`12:102`](12-divergencias-interface-vs-regras.md): criar num slot com
bloco coincidente (mesmo profissional/data/hora/tipo) **funde** o paciente ([`:1053`]) e o
protótipo **nunca chama `checkConflict`** para grupo. Com a constraint, isso deixa de ser
escolha estética: um segundo `Appointment` no mesmo profissional/horário **será rejeitado pelo
banco**.
**DECIDIDO: oficializar, implementado como lookup-then-add** — `:schedule` de tipo grupo
localiza a turma e delega para `:add_participant`. Assim capacidade e `Attendance` têm um
caminho só; sem isso a capacidade fica validada num caminho e furada no outro, que é
exatamente o bug do protótipo.

**A-D5 — conflito por paciente entra?**
O conflito é só por profissional ([`:834`]): o mesmo paciente pode estar em dois lugares ao
mesmo tempo e nada avisa. (Sala/equipamento é GAP-15, **v2**, com instrução explícita de
*"não decidir por palpite"* — muda a constraint de "por profissional" para "por recurso", a
alteração de schema mais cara do sistema.)
**DECIDIDO: avisar, não bloquear.** Paciente em dois lugares é quase sempre erro de
digitação, mas bloquear atrapalha o caso legítimo (avaliação e Pilates com 5 min de
sobreposição por remarcação) — e é o mesmo tratamento que o projeto já deu a duplicados de
paciente e de profissional. Custa uma consulta e um índice `attendances (patient_id)`.

**A-D6 — auditoria: quem criou e quem cancelou?**
O `appt` do protótipo não tem **nenhum** campo de autoria. Numa tela operada por 3 ou 4 pessoas
ao mesmo tempo (é literalmente o caso de uso da ADR-004), *"quem cancelou o paciente das 14h?"*
é a primeira pergunta que a clínica faz. Opções: (a) nada; (b) `created_by_id`/`updated_by_id`;
(c) trilha completa (AshPaperTrail).
*Recomendação original era (b).*
**DECIDIDO: (c) — trilha completa com AshPaperTrail, já nesta fatia.** Divergência deliberada:
(b) responde "quem criou" e "quem mexeu por último", mas o penúltimo autor é **sobrescrito** —
se a recepção remarca às 9h e o admin cancela às 11h, a remarcação some. Numa tela operada por
3–4 pessoas ao mesmo tempo (o caso de uso da ADR-004) isso acontece todo dia, e a decisão do
produto é que a clínica precisa da história inteira, não do último autor.

`created_by_id` **continua entrando** junto: é uma coluna denormalizada que evita consultar a
tabela de versões para a exibição mais comum ("criado por Fulana"), que aparece em cada bloco
do drawer. `updated_by_id` **sai** — com a trilha ele é derivável e seria a única cópia que
mente. Ver §11 para o custo completo e a tela de auditoria que a decisão habilita.

**A-D7 — agendamento tem observação?**
A fila tem `obs` ([`:2245`]), o paciente tem, o agendamento **não**. "Vem de muleta", "trazer
exame", "sessão dupla combinada por telefone" não têm onde morar.
**DECIDIDO: adicionar `obs :string` (0–500) agora.** Uma coluna hoje, migration e retrabalho
de UI depois. Atenção: observação de agendamento **pode** conter dado clínico — não é campo de
prontuário (ADR-013/D16) e a UI deve deixar isso claro no placeholder. Combinado com A-D6(c),
o `obs` passa a ser **retido para sempre** na trilha: ver a nota de retenção em §11.

**A-D8 — duração customizada por agendamento?**
A duração é snapshot do tipo (A3) e não é editável no formulário; [`09:246`](09-contrato-api.md)
admite um `duration?` opcional.
**DECIDIDO: sim, campo opcional.** Custo zero de schema (`ends_at` já é independente), e sem
isso a saída para "esta sessão vai demorar mais" é criar um tipo novo, poluindo o catálogo para
resolver um caso pontual. Passa pelas mesmas validações; o bloco cresce e o `layoutAppts` já
lida com isso.

**A-D9 — qual é a home do app depois desta fatia?**
O protótipo abre em `screen:'pacientes'` [`:267`] mas `renderScreen` tem
`default: renderAgenda` [`:1316`]. Hoje `/` mostra a sessão.
**DECIDIDO: `/` redireciona para `/agenda`.** É a tela que a recepção abre de manhã e não
fecha. Toca `(app)/+layout.server.ts` e a ordem do rail.

**A-D10 — profissional sem `Membership` aparece na agenda?**
No protótipo p4 e p5 são profissionais **sem acesso ao sistema** ([`:200`]) e mesmo assim têm
coluna e recebem agendamento.
**DECIDIDO: sim — vínculo de acesso é ortogonal à agenda.** Quem atende não precisa logar.
Confirmar explicitamente para não virar "bug" na primeira clínica que cadastrar um profissional
sem e-mail.

**A-D11 — semana: 6 ou 7 dias, e qual o denominador da barra?**
O protótipo mostra seg–sáb, nunca domingo [`:1736`], e a barra usa a constante mágica **45**
[`:1744`] enquanto o mês normaliza pelo pico do próprio mês [`:1759`] — a mesma quantidade pinta
diferente nas duas visões.
**DECIDIDO: 7 dias, com dia fechado marcado como tal, e denominador = capacidade real do
dia** (soma dos minutos de expediente dos profissionais visíveis), já calculável com
`ClinicHours` + `ProfessionalHours`. Clínica que abre domingo existe; e barra com denominador
inventado é gráfico que mente.

**A-D12 — fórmula única de ocupação e carga (bloqueia a Fatia 9).**
O protótipo dá **duas respostas para a mesma pergunta na mesma tela**: `colLoad` [`:1576`] divide
por 540 min fixos; `profLoad` [`:916`] divide pelo expediente real. `occupancy` [`:908`] soma no
numerador agendamentos de qualquer profissional mas divide só pelos ativos, e faz clamp em 100 —
**escondendo sobrecarga**. O relatório tem uma terceira fórmula, com "9 atendimentos por
profissional por dia" hardcoded [`:3351`] e "dia útil = não-domingo" [`:3349`].
**DECIDIDO: minutos ocupados ÷ minutos de expediente real, em todos os lugares, sem clamp**
(deixar passar de 100 e pintar de vermelho — sobrecarga é informação), com agendamento de grupo
contando **1× a duração** (a turma não consome mais tempo do profissional). Nesta fatia só a
barra de carga da coluna morde; o resto é Fatia 9.

## 9. Fatiamento sugerido

Cinco entregas fecháveis. A primeira é a fatia deste doc; as demais estão desenhadas aqui para
que o schema já as comporte.

**Entrega 1 — Agenda do dia (esta).** `Appointment` + `Attendance` + os dois enums + a exclusion
constraint + `btree_gist` + `tz` + relógio no `Api.Scope` + `Availability` + a **trilha de
auditoria** gravando (A-D6c, §11 — só gravar; a tela é fatia própria) +
`GET/POST /api/appointments` + `GET /api/availability` + a rota `/agenda` com visão **Dia** e o
modal de criar.

**Pronto quando** (corrigido em 2026-07-19 — ver nota abaixo): criar fora do expediente é
recusado com mensagem; sobrepor é recusado **pela constraint sob corrida**, com 422 e não 500
([`08:200`](08-roadmap.md)); a turma respeita capacidade e funde participantes; e tipo
arquivado / profissional ou paciente inativo são recusados.

> **Correção do critério (D1).** A redação anterior exigia *"dois navegadores no mesmo dia, um
> cria e aparece nos dois **sem refresh**"* — isso é PubSub/Channel, que este mesmo §9 atribui à
> **Entrega 3**. O critério contradizia o fatiamento. Removido daqui: tempo real fecha na
> Entrega 3, e o valor dele só aparece quando houver operação simultânea real. Puxá-lo para cá
> reabriria um eixo de risco inteiro (validar `clinic_id` do tópico no `join`, dois broadcasts
> por escrita, remarcação entre dias emitindo em dois tópicos) numa entrega já grande.

> **Status (2026-07-19): Entrega 1 CONSTRUÍDA.** Backend: `Appointment`, `Attendance`, os dois
> enums, `Availability`, `LocalTime`, a exclusion constraint, `btree_gist`, `tz`, o relógio no
> `Api.Scope`, a trilha (A-D6c) em ambos os recursos, `GET/POST /api/appointments` (com sidecar
> `patients`), `GET /api/availability`, e RLS — **inclusive nas tabelas de versão**. 463 testes,
> 89,4% de cobertura. RLS verificada por `psql` como `movimento_app` (NOBYPASSRLS) em 4
> cenários: sem GUC → 0 linhas; com GUC → só a própria clínica; `INSERT`/`UPDATE` com
> `clinic_id` alheio → barrados pelo `WITH CHECK`; e a trilha isolada do mesmo jeito.
> Frontend: rota `/agenda` com visão Dia, o modal de criar, `layoutAppts` portado com teste de
> propriedade, e `/` redirecionando para `/agenda`.
>
> Frontend: 747 testes, 92,9% de statements. Verificado **ao vivo no navegador**: criar,
> recusa por expediente com a mensagem certa, conflito pela constraint com o botão
> *"Marcar como encaixe"*, o encaixe entrando e os dois blocos aparecendo **em raias com borda
> vermelha** (A-D2b: encaixe suprime o bloqueio, não a exibição do conflito), e a trilha
> gravada com autor e campos alterados.
>
> Correções de rumo aplicadas durante a construção, todas registradas acima: `tsrange` no lugar
> de `tstzrange` (§4), o sidecar `patients` que faltava no contrato do §5, e o `Exception.message/1`
> que vazava `"Bread Crumbs:"` para a tela em **todo** 422 do projeto (bug pré-existente no
> `ApiWeb.TenantScope`, não introduzido por esta fatia).
>
> ### Três bugs apareceram ao vivo: leitura sem a GUC de tenant
>
> Sidebar vazia, `/availability` 404 e criar dava 400 — **os três eram a mesma causa**: leitura
> por-tenant sem a GUC `movimento.clinic_id`, barrada pela RLS. Consertados envolvendo as
> leituras em `in_clinic`/`with_clinic` (`load_agenda/4`, `load_availability_sources/3`,
> `ComputeEndsAt`).
>
> Experimento decisivo — a mesma chamada, sob os dois roles:
>
> | Condição | Resultado |
> | --- | --- |
> | `movimento_app` (role do servidor), **sem** `in_clinic` | **0 profissionais** |
> | `movimento_app`, **com** `in_clinic` | 2 profissionais |
> | `postgres` (o role do `mix test`) | 2 profissionais |
>
> Nota importante: `Api.Repo.on_transaction_begin/1` promete injetar a GUC em leitura com
> tenant, e o experimento mostra que **não cobre este caso** — a leitura crua voltou vazia.
> Não confie nele; envolva a leitura por-tenant explicitamente.
>
> ### Por que o bate-volta "refutou" isto por engano — e a lição de método
>
> A auditoria (doc [26](26-auditoria-bate-volta-agenda.md)) chegou a registrar que este
> diagnóstico era falso, alegando que o app em dev conecta como `postgres` e bypassa RLS.
> **Estava errado**, e a causa do erro vale mais que o erro:
>
> - `docker-compose.yml` de fato define `DATABASE_USER: postgres` — mas isso é o usuário
>   **privilegiado, para migrations/DDL**. O `entrypoint.dev.sh` termina com
>   `exec env DATABASE_USER="${APP_USER}" ... mix phx.server`: **o servidor sobe como
>   `movimento_app`**, sujeito à RLS.
> - `docker compose exec` **não passa pelo entrypoint**. Toda sonda feita por ele — minhas e as
>   de dois subagentes — conectou como `postgres` e mediu um ambiente que não é o que serve as
>   requisições. `pg_stat_activity` desfaz a dúvida: 10 conexões `movimento_app`, e a única
>   `postgres` era o próprio psql da sonda.
>
> **Lição:** ao sondar um comportamento dependente de role/ambiente, verifique **quem a sonda
> é** antes de acreditar no que ela diz (`SELECT current_user`), e prefira observar o processo
> real (`pg_stat_activity`) a inferir do arquivo de configuração. Para rodar uma sonda como o
> servidor: `docker compose exec -e DATABASE_USER=movimento_app -e DATABASE_PASSWORD=movimento_app api ...`.
>
> **O que continua valendo:** `mix test` roda como `postgres` (BYPASSRLS), então a suíte
> **não** exercita RLS — bug de GUC passa verde e só aparece ao usar a tela em dev (que é um
> detector real) ou em produção. A dívida de uma parte da suíte rodar como `movimento_app`
> continua de pé.

**Entrega 2 — Visões e navegação.** Semana, Mês, Lista, `GET /api/appointments/counts` (uma
query agregada `GROUP BY dia`, não 42 leituras como `renderMonth` [`:1749`] faz em memória),
mobile, densidade, estados vazios. Separada porque é UI e agregação, sem risco novo de domínio.

**Entrega 3 — Tempo real.** `phoenix` no npm, Channel, notifier Ash. **Dois broadcasts por
escrita** (RN-56): `agenda:<YYYY-MM-DD>` com payload cheio e `agenda:month:<YYYY-MM>` com sinal
leve `{day, change: :count}`. Riscos próprios: validar `clinic_id` do tópico contra o tenant no
`join` (senão é vazamento por fora da RLS); remarcar entre dias emite em **dois** tópicos de dia
— esquecer o de origem deixa bloco fantasma; emitir fora da transação com
`return_notifications?`, como `update_clinic_hours/2` já faz.

**Entrega 4 — Ciclo de vida (Fatia 2 do roadmap).** Drag & drop, remarcar, as seis transições,
máquina de status, `expected_version` + 409, drawer completo. Aqui mora a decisão de qual
transição é legal (dá para reabrir `faltou`?) e a de GAP-03: no protótipo o formulário bloqueia
fora do expediente mas o **arraste não valida disponibilidade** — mesma regra, duas respostas.

**Entrega 5 — Fila de espera (Fatia 4 do roadmap).** `Api.Waitlist`, `find_slots`, `SlotHold`
com TTL de **10 min** (D8 — os 5 min de [`01:788`](01-dominio-ash.md), [`02:714`](02-regras-e-lacunas.md)
e [`09:739`](09-contrato-api.md) são resíduo já corrigido por
[`12:181`](12-divergencias-interface-vs-regras.md)).

### Explicitamente FORA

- **Pacotes** (Fatia 3): série, débito, falta punitiva, massa, pausar/retomar. Ganchos que ficam
  prontos: `package_id` nullable em `Appointment` **e** em `Attendance` (D11: não existe "pacote
  de turma"), `pkg_hold`, e o ponto único de leitura filtrável.
- **Prontuário** (ADR-013/D16): v1 não tem. Paciente aqui é *"mínimo, só o suficiente para
  selecionar um nome"* ([`08:197`](08-roadmap.md)).
- **Financeiro**: preço não é campo de `AppointmentType`; a tabela do protótipo é hardcoded no
  relatório [`:3340`] e `fat`/`ticket` são calculados e **nunca renderizados** (o formatador
  `brl` fica órfão). Faturamento histórico exige preço vigente na data, não preço atual — não
  inventar o modelo aqui.
- **Salas/equipamentos** (GAP-15): v2, e [`02:694`](02-regras-e-lacunas.md) manda **não decidir
  por palpite**.
- **Relatórios** (Fatia 9): bloqueados por A-D12.
- **`futureConflicts` ligado** (Fatia 7): o `confirm` continua viajando e sendo ignorado em
  `/clinic-hours` e `/clinic-exceptions` (H2). Registrar que D12 ([`10:106`](10-decisoes-de-produto-v1.md))
  fala do **horário do profissional**; estender para clínica e exceção é decisão nova, e
  [`12:101`](12-divergencias-interface-vs-regras.md) lembra que RN-16 esqueceu o terceiro
  consumidor (`addHoliday`), que ainda tem precedência própria na simulação.

## 10. Riscos e pontos de atenção

- **Concorrência** — o cenário real são dois recepcionistas no mesmo slot. Só o banco resolve;
  pré-checagem é conselho. E o `exclusion_violation` precisa ser **traduzido** para 422 na ação:
  sem isso vira 500, e sob RLS o Postgres omite o `DETAIL`, o que já derrubou o AshPostgres em
  `KeyError` duas vezes neste projeto.
- **Locking otimista vs `require_atomic? false`** — [`01:535`](01-dominio-ash.md) prescreve
  `atomic_update(:version, …)`, mas `SetTenantGuc` é `before_action` e força
  `require_atomic? false` em toda escrita por-tenant. As duas coisas não coexistem como escritas.
  Saída recomendada: guard de versão como validation sobre o valor lido no fetch-then-update (o
  helper `write/4` dos controllers já faz o fetch), com a constraint fechando a corrida
  remanescente. Morde na Entrega 4, mas o campo nasce agora.
- **Volume** — dia é naturalmente limitado (profissionais × slots), mas o intervalo vem do
  cliente: teto de 31 dias no servidor. Mês **não** carrega blocos, carrega contagens. A lista de
  pacientes já ensinou que carrega-tudo vira dívida.
- **N+1** — cada bloco precisa de profissional, tipo e paciente(s). Carregar por bloco é N+1 com
  N ≈ 45/dia. Resolver com `load` estrito nas `attendances` e **lookup no cliente** para
  profissional e tipo, que a tela já baixa inteiros para a sidebar e a legenda — precedente em
  `professionals_controller.ex:29`.
- **Timezone** — o Brasil não tem DST desde 2019, mas o tz database guarda as transições e
  `Clinic.timezone` é coluna livre. Fixar a política de `{:gap, …}`/`{:ambiguous, …}` uma vez e
  testar com tz que tenha DST, senão a regra fica sem cobertura real.
- **RLS invisível ao `mix test`** — a suíte é `postgres` (BYPASSRLS). Esquecer o `SetTenantGuc`
  numa ação passa verde e quebra em produção. Verificação por `psql` entra no critério de pronto.
- **Port do `layoutAppts`** — [`08:183`](08-roadmap.md) o nomeia como o teste de fogo do port
  não-mecânico. Arquivo próprio, teste de propriedade, não uma função entre dez outras.
- **Faixa vertical e os dois clamps** — `emptyClick` clampa em 1065 [`:1661`] e o arraste em
  `1080 - dur` [`:1248`]. Com a faixa derivada (A12) esses números deixam de ser constantes e
  precisam sair do **mesmo lugar**, senão criar-em-vazio e arrastar discordam sobre onde acaba o
  dia.
- **Badge de conflito da coluna** — o protótipo exibe `maxLanes` com sufixo "×" [`:1639`], que é
  o número máximo de sobreposições, **não** a contagem de conflitos: acende com encaixes, que por
  definição não são conflito. Decidir o número antes de transcrever.

## 11. Trilha de auditoria (A-D6c) e a tela do admin

Consequência da A-D6 ter fechado em (c). Duas partes independentes: **gravar** a trilha (entra
nesta fatia, porque schema não espera) e **exibir** a trilha (tela própria, fatiável depois).

### 11.1 Gravar — o que a extensão exige

`ash_paper_trail` **não está nas deps** (`mix.lock` tem `ash`, `ash_postgres`, `ash_json_api`,
`ash_phoenix`, `ash_authentication`, `ash_sql` — não este). Setup:

1. `{:ash_paper_trail, "~> 0.6.0"}` em [`api/mix.exs`](../api/mix.exs)
2. `:ash_paper_trail` no `import_deps` do `.formatter.exs`
3. `extensions: [AshPaperTrail.Resource]` no `Appointment` (e ver 11.2 sobre `Attendance`)

A extensão gera sozinha um recurso `Api.Scheduling.Appointment.Version` com uma tabela própria,
uma linha por escrita. Configuração proposta:

```elixir
paper_trail do
  change_tracking_mode :changes_only          # default é :snapshot (guarda o registro inteiro)
  store_action_name? true                     # "cancelou" vs "remarcou" — é a coluna que a tela lê
  store_action_inputs? false                  # ver nota de retenção em 11.3
  ignore_attributes [:inserted_at, :updated_at]
  attributes_as_attributes [:clinic_id, :professional_id, :starts_at, :status]
  belongs_to_actor :user, Api.Accounts.User, domain: Api.Accounts
  include_versions? true                      # senão o recurso não entra no domínio
end
```

`change_tracking_mode :changes_only` em vez do default `:snapshot` (**A-D13, decidido**):
snapshot grava o registro inteiro a cada escrita, e com o `obs` (A-D7) isso multiplicaria dado
potencialmente clínico pelo número de edições. `:full_diff` daria o diff mais rico na tela, mas
é o mais caro — ver em 11.4 o preço que `:changes_only` cobra da tela em troca.

### 11.2 As quatro armadilhas

**(1) Tenancy — a que pode vazar.** A extensão aplica ao recurso de versão a mesma
`strategy`/`attribute` de multitenancy do original, mas os atributos de tenancy só viram
**coluna real** se estiverem em `attributes_as_attributes` — por isso `:clinic_id` está na lista
acima. Sem coluna real, `clinic_id` fica enterrado no mapa `changes` e **a policy de RLS não tem
o que filtrar**: a tabela de versões viraria um buraco por fora do isolamento por clínica,
justamente com o histórico inteiro dentro. Exige migration de RLS própria, no molde de
[`20260716171500_scheduling_rls.exs`](../api/priv/repo/migrations/20260716171500_scheduling_rls.exs).

**(2) A suíte não pega esse erro.** `mix test` conecta como `postgres` (BYPASSRLS) — furo de RLS
na tabela de versões passa verde, exatamente como os 3 bugs da fatia de Tipos. Verificação por
`psql` como role NOBYPASSRLS entra no critério de pronto **também para `appointment_versions`**.

**(3) Policies próprias.** O recurso de versão é um recurso Ash normal: sem
`Ash.Policy.Authorizer` e uma policy explícita, qualquer papel lê a trilha inteira. A trilha é
**owner·admin** (é o pedido: "tela de auditoria pro admin"). Um `profissional` não deve ler o
histórico de cancelamentos da clínica toda — e note que o `FilterCheck` `OwnProfessionalAgenda`
da A7 **não se aplica automaticamente** ao recurso de versão.

**(4) `Attendance` também muda** (confirmado por A-D14)**.** "Quem tirou o paciente da turma?" só é respondível se
`Attendance` **também** tiver a trilha — adicionar/remover participante é escrita nela, não no
`Appointment`. Recomendo ligar nos dois; é a mesma extensão e o mesmo custo de migration, e sem
isso a tela tem um buraco exatamente no caso que mais gera discussão na recepção.

### 11.3 Retenção — a parte que não é técnica

Com (c) + A-D7, o `obs` do agendamento passa a ser **retido para sempre**, em cópia, mesmo depois
de editado ou do agendamento cancelado. Como o próprio A-D7 registra que esse campo *pode conter
dado clínico*, isso interage com [`06-seguranca-e-lgpd.md`](06-seguranca-e-lgpd.md): "apagar" um
dado passa a exigir apagar também as versões. É o motivo de `store_action_inputs? false` acima —
ele duplicaria os inputs da ação (incluindo `obs`) numa segunda coluna.

> **Decidido em 2026-07-20 (A-D13): o `obs` fica retido na trilha, sem redação nem expurgo.**
>
> Razão: `obs` é campo **operacional do agendamento** — "trazer exame", "chega 10min antes",
> "estacionamento" — e na maior parte das vezes não diz respeito ao paciente. Tratá-lo como
> dado clínico por precaução custaria o histórico do campo (`ignore_attributes`) para proteger
> um conteúdo que, no uso real, raramente é sensível.
>
> O que **não** muda com isso: `store_action_inputs? false` continua valendo (não há razão para
> a segunda cópia), e o campo segue coberto pelas policies da trilha — ler versão é
> owner·admin, escrever não é ninguém ([`TrailPolicies`](../api/lib/api/scheduling/trail_policies.ex)).
>
> O que fica **em aberto**, e é outra pergunta: prazo de retenção da trilha como um todo. Não é
> específico do `obs` e não bloqueia nada hoje.
>
> Consequência de projeto, resolvida junto: a trilha não impede mais a exclusão do registro —
> ver o achado (c) em [26 §7](26-auditoria-bate-volta-agenda.md). A FK `version_source_id` foi
> removida (`reference_source? false`), então apagar um agendamento **deixa a versão órfã em vez
> de bloquear**. Isso é deliberado: se um dia houver expurgo, ele será uma operação explícita
> sobre a trilha, não um efeito colateral silencioso de um `DELETE`.

### 11.4 A tela `/configuracoes/auditoria`

Fatiável **depois** da Entrega 1 — gravar é que é urgente (histórico não se reconstrói); exibir
não muda schema. Inventário do que ela custa:

**Backend**
- Ação `read :audit_log` no recurso de versão, com **paginação obrigatória** (`offset`, como
  pacientes) — a trilha é a tabela que mais cresce do sistema e a lista de pacientes já ensinou
  que carrega-tudo vira dívida
- Filtros: por registro (`record_id`), por autor (`user_id`), por período (`from`/`to`), por ação
  (`version_action_name`), por tipo de recurso
- Policy `owner·admin` (ver armadilha 3) + `with_admin_scope` — este já existe e serve
- `GET /api/audit?resource=&record_id=&user_id=&from=&to=&action=&page=` → `200 { versions, meta }`
- Índices: `(clinic_id, inserted_at desc)` para o feed cronológico e `(clinic_id, version_source_id)`
  para o histórico de um agendamento. `clinic_id` lidera, ADR-017
- Teto de janela como em `/appointments` (31 dias), pelo mesmo motivo

**Frontend**
- Rota `routes/(app)/configuracoes/auditoria/` + ramo em `Sidebar.svelte` e entrada em
  [`nav.ts`](../web/src/lib/components/shell/nav.ts) — lembrando o gotcha do `<Sidebar>`
  renderizado **duas vezes** no `(app)/+layout.svelte` (foi assim que o bug do CNPJ passou)
- Lista cronológica reversa: quem · quando · qual ação · qual registro · o diff dos campos
- Componente de diff campo-a-campo (**não existe nada parecido no projeto hoje** — é o único
  componente realmente novo desta tela)
- Tradução dos nomes técnicos para português de clínica: `status: agendado → cancelado` precisa
  virar *"Cancelou o agendamento"*. Sem essa camada a tela mostra nome de coluna para a recepção
- Link "ver na agenda" a partir da entrada, quando o registro ainda existe
- Reaproveitados sem mudança: `Field`, `Button`, paginação de `pacientes`, `avatarColor`/`initials`

**Duas decisões que a tela abriu — ambas resolvidas em 2026-07-19**

**A-D13 — `:changes_only` ou `:full_diff`?**
`:changes_only` grava só o que mudou (mais barato; o diff se monta encadeando versões);
`:full_diff` grava antes-e-depois (tela trivial, tabela bem maior).
**DECIDIDO: `:changes_only`.** Consequência a assumir de olhos abertos: **é decisão de schema** —
mudar para `:full_diff` depois não reescreve o histórico já gravado, então as versões antigas
permanecem sem o "antes". E a tela paga o preço: para mostrar *"de 14:00 para 15:30"* precisa
encadear a versão anterior do mesmo registro, não basta ler uma linha. Isso é trabalho do
backend (montar o par na `read :audit_log`), **não** do componente de diff — se vazar para o
cliente, vira N+1 na tela que mais cresce.

**A-D14 — a trilha vale só para a agenda ou para o sistema todo?**
A mesma extensão serve `Patient`, `Professional`, `Membership`, `AppointmentType`.
**DECIDIDO: só a agenda por ora** — `Appointment` e `Attendance`, o escopo desta fatia. As outras
ficam como fatia própria, para não inflar a Entrega 1. Registrar que a lacuna é **assimétrica no
tempo**: quando `Membership` entrar (a mais sensível das quatro — "quem promoveu Fulano a
admin?"), o histórico anterior à data de ligação simplesmente não existe. Ligar cedo custa uma
migration; ligar tarde custa o passado.
