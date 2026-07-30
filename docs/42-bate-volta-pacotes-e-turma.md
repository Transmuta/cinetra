# 42 — Bate-volta: Frente 5 (Pacotes) e Frente 6/A2 etapa 1 (Turma)

Revisão adversarial do que a sessão de **2026-07-24** entregou:

- `cb86851` — Frente 5: modal de criação com prévia ao vivo + 3 correções RLS na materialização.
- `94852aa` — `docs/41`: spec da A2 (presença por participante).
- `513bca1` — A2 etapa 1: presença por participante (backend, aditivo).

**Método.** Duas passadas. (1) Três auditores em paralelo, cada um numa dimensão (correção do
backend da A2; resíduo de RLS/loop na Frente 5; consistência código↔spec/contrato). (2) Rodada
formal do skill `bate-volta`: cada achado **provado contra a stack rodando** — `psql`, `mix test`
(DataCase/ConnCase = o Router/domínio de verdade), e **`iex` no dev com log de SQL** disparando as
transições na app. Consertos com regressão vermelho-primeiro. Correções em `9e00620` + `b7599a6`.

**Re-sonda ao vivo (rodada 5).** Disparei as ações na app rodando (dev), não só no `mix test`:

- **A presença por participante fecha o rollup e o `FOR UPDATE` do conserto H-2 SAI de verdade** —
  `iex` no dev, com o SQL logado: `... FROM "appointments" ... FOR UPDATE OF a0` antes do
  `UPDATE`. `agendado(v8) → complete → concluido(v9) → reopen → agendado(v10)`, ~5 queries por
  transição, **sem N+1** (as presenças carregam numa query só). O lock não é no-op.
- **Cancelar um pacote pausado (H-1) cancela as seguradas na app** — criar → esperar o Oban
  materializar → pausar → cancelar: as 3 seguradas viram `cancelado`, nenhuma órfã. (Foi essa
  sonda que revelou o M-4 abaixo, ao cancelar ANTES da materialização.)

## Consertado

### H-1 (HIGH) — cancelar/re-pausar um pacote PAUSADO estourava 500 e deixava seguradas órfãs

`Api.Packages.future_sessions/3` mapeava `.appointment` das presenças, mas uma sessão **segurada**
(`pkg_hold`, de uma pausa anterior) carrega o bloco como `nil` sob a preparation global `HideHeld`
→ `nil.status`. O fluxo é o RN-25 documentado ("cancelar inclusive as seguradas por uma pausa
anterior"), alcançável por `POST /api/packages/:id/cancel`, **sem** cobertura de teste (o único
teste de cancelar nunca pausava antes). Falhava em `mix test` puro — não era RLS-invisível.

Dois níveis: guardar o `nil` sozinho **não** bastaria — as seguradas seriam **puladas** em
silêncio, o pacote viraria `:cancelado` e os blocos seguros ficariam no banco ocupando slot para
sempre. Fix: `Api.Scheduling.list_sessions_including_held/2` (abre `include_held`, traz **todas** as
sessões por id, não só as seguradas) e `future_sessions` lê por ele — espelha o que
`resume_package` já fazia. Regressão: pausar → cancelar.

### H-2 (HIGH) — presença por participante: transições simultâneas corrompiam o rollup

O guard de versão lê o bloco numa transação de leitura que **já fechou**; a escrita da presença é
noutra transação, e o `RollupBlockStatus` lia as presenças **sem lock**. Dois `complete` de
participantes **diferentes** no mesmo instante liam, cada um, um snapshot velho (READ COMMITTED) e
o desfecho ficava preso na fase antiga (`:agendado` quando os dois concluíram). O dado por
participante (que dita o débito) fica sempre certo; só o status derivado do bloco ficava velho até
a próxima transição. Fix: `FOR UPDATE` no bloco **antes** de ler as presenças no rollup — serializa
os rollups do mesmo bloco (o 2º espera o 1º commitar e relê fresco).

> Limite conhecido: o guard de 409 é não-atômico (lê numa transação, escreve noutra) — é o desenho
> pré-existente do bloco também (`BumpVersion` diz "a constraint fecha a corrida que sobra"). Para a
> presença **do mesmo paciente**, dois pedidos concorrentes ainda podem resolver por "último a
> escrever ganha" em vez de 409; o `FOR UPDATE` fecha a corrupção do rollup (cross-participante), que
> era o dano real. Um teste determinístico de concorrência exige duas conexões — o sandbox tem uma;
> a correção é por construção, não por teste.

### M-3 (MED) — furo do F4: bloco cancelado recebia presença e ressuscitava

`transition_participant` não checava o status do bloco. `cancel → add_participant → complete`
virava `:cancelado → :concluido` (as canceladas são filtradas no rollup), furando o F4 que as ações
de bloco garantem. Fix: guard `block_open_for_participant` (recusa `:cancelado` → 422
`block_not_open`). Excluído não chega (o `HideExcluded` o esconde do fetch → 404).

### M-4 (MED) — o job de materialização ignorava o status do pacote (achado da sonda ao vivo)

Revelado só na app rodando (o `iex` acima): criar um pacote e **cancelá-lo antes** de o job async
materializar deixava o job criar as N sessões mesmo assim — órfãs `:agendado` na agenda de um
pacote `:cancelado`. `build_plan` (`materializer.ex`) só guardava `schedule: nil`, nunca o status.
Fix (`b7599a6`): pula quando o pacote está `:cancelado` (o job lê o status atual; a retomada roda
com `:ativo`, então não é afetada). Regressão vermelho-primeiro: criar → cancelar → drenar → 0
sessões.

### Doc — parêntese obsoleto em `docs/09`

`docs/09:204` ainda descrevia o fallback de clínica da falta punitiva ("se o pacote não define,
conforme o padrão da clínica") — removido do código e do resto das docs na revisão de 2026-07-24, e
contradizendo o próprio parágrafo oito linhas acima. Corrigido.

## Fica para decisão humana / próximas etapas

- **A-6 — corrida "pausar antes de materializar" (estrutural).** Provado ao vivo junto do M-4: se o
  usuário **pausa** um pacote recém-criado dentro da janela (segundos) do job async, o `pause`
  segura 0 sessões (ainda não existem) e o job depois cria sessões `:agendado` **não** seguradas
  num pacote `:pausado`. O guard do M-4 não cobre isto: pular na materialização quando `:pausado`
  quebraria a retomada (que reprojeta pelo `count` de seguradas = 0 → 0 sessões). A correção certa é
  arquitetural — materializar-e-segurar quando `:pausado`, ou o `pause` reprocessar após o job — e é
  decisão de produto/arquitetura, não patch de impulso. Janela estreita; sem dado corrompido além do
  par status↔sessões inconsistente. Fica para a etapa que reabrir o ciclo de vida do pacote.
- **A-4 — `SessionStarted` da presença mora no wrapper, não na ação.** Uma chamada direta à code
  interface `mark_attendance_present/absent` marcaria presença antes de a sessão começar (RN-58).
  **Não** alcançável pela HTTP (o controller só entra pelo `transition_participant`). É a **mesma**
  colocação do guard de versão (também só no wrapper) — decisão deliberada, não bug. Se quisermos a
  garantia no recurso, é uma validação atômica lendo o bloco pai (com o cuidado do `SetTenantGuc`).
- **A-5 — falta por participante ainda não avisa a fila (#48/slot).** `slot_maybe_opened` (o
  fan-out) dispara em `:cancel`/`:mark_missed`, não em `:apply_participant_rollup`. Enquanto a etapa
  1 mantém as ações de bloco, sem impacto; vira regressão quando a UI migrar (**etapa 4/5**). Item
  da etapa de notificações (#46/#47) no `docs/41`.
- **Doc drift do `docs/41`** (não editado nesta rodada): o doc descreve a etapa 1 como se
  **removesse** as ações de bloco e a `CascadeToAttendances`; a entrega foi **aditiva** (as duas
  coexistem, o drawer atual ainda usa as de bloco; a aposentadoria é a etapa 4). E a regra do rollup
  em `docs/41:32` omite o ramo "desfecho→`:agendado` ao reabrir" que o código (corretamente) tem
  (`rollup.ex:37-42`). Recomenda-se alinhar o `docs/41` a "aditivo-primeiro" quando a etapa 2 abrir.
- **Papercut de nome de rota:** a sub-rota de participante usa `/no_show` (casa o contrato
  `docs/09`), enquanto a de bloco usa `/miss` (drift antigo da Entrega 4). E o contrato ainda não
  lista as sub-rotas `/reopen` e `/justify` da presença nem a forma da resposta — preencher quando
  fechar a A2.

## Limpo (auditado, sem achado)

- **RLS da materialização/`schedule_appointment`**: toda leitura no caminho do job seta a própria
  GUC (`find_turma` via `in_clinic_or_tenant`, `CheckAvailability`/`GroupCapacity` abrem o próprio
  `with_clinic`, `Sessions.stamp` relê sob `in_clinic`). Sem furo.
- **Modal (loop-guard + 422)**: todo input que a prévia usa está no `buildInput`, então o guard por
  payload cobre; o efeito só re-dispara quando a série muda (sem loop). O `series_blocked` (duro vs
  mole) e o `invalid_series` são distinguidos corretamente.
- **Endpoints BFF**: `patient_id` sai do path (corpo forjado não atinge outro paciente); corpo
  malformado tratado; sem vazamento de erro.
- **Tempo real / sino**: `apply_participant_rollup` dispara **um** `appointment_status_changed`; o
  fan-out do sino no-op para essa ação — sem evento/sino duplicado.
- **`justify` + `arg`, rollup puro, `add_participant` sem `package_id`**: corretos (o `package_id`
  é etapa 2, e nada finge que já veio).
