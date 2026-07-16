# 20 — Tipos de atendimento (catálogo da clínica)

Fatia de **gestão da clínica**, a segunda depois de Membros: torna editável o catálogo de tipos de
atendimento que até aqui vinha do seed do protótipo. Vertical completa — recurso Ash + RLS + HTTP +
BFF + tela, com TDD.

Referência: `interface/Movimento.dc.html` — lista `cfgTipos()` [`:3226`]-[`:3238`], modal
`modalTipo()` [`:2388`]-[`:2405`], ações `saveType`/`rmType` [`:1210`]-[`:1211`], seed [`:69`]-[`:74`].
O link `/configuracoes/tipos` já existia em `web/src/lib/components/shell/nav.ts:50` apontando para 404.

## 0. Dois "Tipo de atendimento" — a colisão que nenhum doc registrou

O protótipo usa **o mesmo rótulo** para duas coisas diferentes:

| | O quê | Onde no protótipo | Recurso nos docs |
| --- | --- | --- | --- |
| **(a)** | **Catálogo da clínica** — Avaliação, Sessão, RPG, Pilates, Reavaliação, cada um com duração, cor, ícone e grupo/capacidade | `cfgTipos` [`:3229`], toast *"Tipo de atendimento salvo"* [`:1210`] | `Directory.AppointmentType` ([`01:450`](01-dominio-ash.md)) |
| **(b)** | **Categoria comercial do paciente** — `particular` / `reembolso` / `convenio` | ficha [`:2146`], detalhe [`:2790`] | `Records.AttendanceType` ([`01:168`](01-dominio-ash.md)) |

Os docs modelam as duas separadamente, mas **nenhum deles registra que dividem um nome na UI** — nem o
[`12-divergencias`](12-divergencias-interface-vs-regras.md), que auditou 86 candidatos. Quem lesse só os
docs cairia na armadilha.

**Esta fatia entrega (a).** (b) vem junto da ficha do paciente. Quando as duas coexistirem na tela,
revisar os rótulos — hoje não colidem porque a ficha não existe.

## 1. Decisões

| # | Decisão | Escolha | Por quê |
| --- | --- | --- | --- |
| T1 | Escopo | Só o catálogo (a) | A ficha do paciente não existe; o link da sidebar já aponta para cá |
| T2 | Excluir tipo | **Arquivar** (`ativo: false`), sem hard delete | `Appointment`/`Package`/`PriceVersion` declaram `belongs_to … allow_nil?: false` ([`01:552`](01-dominio-ash.md), [`01:845`](01-dominio-ash.md)) — apagar dangling FK. Espelha o `deactivate` já planejado para `Professional` ([`01:445`](01-dominio-ash.md)) |
| T3 | Clínica nova | **Seed dos 5 tipos** no `Clinic.onboard` | Sem tipo não se agenda; o protótipo nasce com os 5 ([`:69`]-[`:74`]) |
| T4 | `sigla` | **Derivada** do nome, calculation — não é coluna | O form do protótipo nunca coleta sigla ([`:2388`]-[`:2402`]); `pkgSigla` [`:378`] já deriva. A derivação reproduz as 5 siglas do seed exatamente |
| T5 | UI do arquivado | Some da lista + seção **"Arquivados"** recolhível, com Restaurar | Arquivar tem que ser reversível pela usuária, não só pelo banco |
| T6 | Confirmação ao arquivar | **Não** — arquiva e toasta | Fiel a `rmType` [`:1211`] (remove e toasta, sem confirmar); e é reversível, então confirmar é atrito sem ganho |
| T7 | Nome duplicado | **Proibido** por clínica (422) | Dois "Sessão" são indistinguíveis na agenda e colidiriam na sigla derivada (T4) |
| T8 | Acesso | Todos os membros **leem**; só owner/admin **escrevem** | Já fixado em [`09:457`](09-contrato-api.md); espelha Membros |
| T9 | Ícone do botão | `Archive` neutro, **não** `Trash2` vermelho | A ação deixou de ser destrutiva (T2) — lixeira vermelha prometeria exclusão. Desvio consciente, no molde de [`19:167`](19-fidelidade-shell-interface.md) |
| T10 | Rota de arquivar | `POST /:id/archive` e `/:id/restore` | É transição de estado, não `destroy` — e [`09:32`](09-contrato-api.md) manda `POST /:id/<verbo>` fora do CRUD. **Corrige** [`09:457`](09-contrato-api.md), que previa `DELETE` |

### Decisões tomadas por padrão (sem pergunta)

- **Nomes na wire**: `duracao_minutos`, `capacidade` — os de [`01:465`](01-dominio-ash.md), não as
  abreviações `dur`/`cap` de [`09:457`](09-contrato-api.md). O wire já é português (`papel`, `nome`,
  `professional_id`). **Corrige o 09.**
- **Paleta fechada**: as 8 cores [`:2391`] e os 10 ícones [`:2390`] do protótipo, validados com
  `one_of` **no servidor** — mesmo padrão do whitelist `@papeis` do `MembersController`. O protótipo
  não valida; aceitar hex/ícone arbitrário do cliente seria abrir superfície à toa.
- **Duração**: `min=10 step=5` na UI (fiel a [`:2396`]); `min: 5, max: 480` no servidor. **Não** precisa
  ser múltiplo do passo da grade — D3 ([`10:37`](10-decisoes-de-produto-v1.md)) separa passo (clínica)
  de duração (tipo), e o próprio protótipo tem slot 15 com duração 50.
- **Capacidade**: default do modal vem de `clinic.cap_turma_padrao` em vez do `4` hardcoded [`:3229`];
  o protótipo já lê `settings.capPilates` noutros pontos ([`:341`]). Mínimo 2.
- **Ordem**: `inserted_at: :asc` (igual Membros). Sem reordenar — o protótipo não tem.
- **Preço**: fora. `PriceVersion`/`preco_vigente` é faturamento = v2 ([`02:439`](02-regras-e-lacunas.md),
  [`00:351`](00-decisoes.md)).

## 2. Modelo — `Api.Directory.AppointmentType`

Por tenant (`strategy :attribute`, `clinic_id`), espelhando `Professional`: RLS em migration própria,
índice em `clinic_id`, `reference :clinic, on_delete: :delete`.

| Atributo | Tipo | Regras |
| --- | --- | --- |
| `nome` | `:string` | obrigatório, 1–60, **único por clínica** (T7) |
| `duracao_minutos` | `:integer` | obrigatório, 5–480 |
| `cor` | `:string` | obrigatório, `one_of` das 8 |
| `icon` | `:string` | obrigatório, `one_of` dos 10 |
| `grupo` | `:boolean` | obrigatório, default `false` |
| `capacidade` | `:integer` | 2–50; `present` sse `grupo` ([`01:474`](01-dominio-ash.md)) |
| `ativo` | `:boolean` | obrigatório, default `true` (T2) |
| `sigla` | calculation | 3 primeiras letras do nome, maiúsculas (T4) |

**Ações**: `defaults [:read]`, `create`, `update`, `update :archive` (`ativo: false`),
`update :restore` (`ativo: true`). **Sem `destroy`.**

**Policies**: `read` → `HasClinicRole roles: :any, clinic_from: :tenant`;
`create`/`update` → `HasClinicRole roles: [:owner, :admin], clinic_from: :tenant`.

**Derivação da sigla** — `nome`, sem não-letras, 3 primeiros, maiúsculo; vazio ⇒ `"TIP"`. Reproduz o seed:
Avaliação→`AVA`, Sessão→`SES`, RPG→`RPG`, Pilates→`PIL`, Reavaliação→`REA`.

### Seed no `onboard` ([`:69`]-[`:74`] verbatim)

| nome | dur | cor | icon | grupo |
| --- | --- | --- | --- | --- |
| Avaliação | 50 | `#0072B2` | `ClipboardList` | — |
| Sessão | 50 | `#0FB5A6` | `Activity` | — |
| RPG | 50 | `#009E73` | `StretchHorizontal` | — |
| Pilates | 50 | `#CC79A7` | `Users` | sim, cap 4 |
| Reavaliação | 30 | `#7A52CC` | `RefreshCw` | — |

Change module no `Clinic.onboard`, espelhando `CreateOwnerMembership`.

### Paletas (do protótipo, verbatim)

- **Cores** [`:2391`]: `#0FB5A6` `#0072B2` `#009E73` `#CC79A7` `#7A52CC` `#D55E00` `#E69F00` `#2B7FFF`
- **Ícones** [`:2390`]: `Activity` `ClipboardList` `StretchHorizontal` `Users` `RefreshCw` `HeartPulse`
  `Dumbbell` `Footprints` `Hand` `Bone`

## 3. Contrato HTTP

JSON simples, **não** JSON:API — seguindo o que o `MembersController` de fato faz (o
[`09`](09-contrato-api.md) descreve JSON:API como alvo; a implementação real ainda não é).

```jsonc
// objeto
{ "id": "…", "nome": "Sessão", "sigla": "SES", "duracao_minutos": 50,
  "cor": "#0FB5A6", "icon": "Activity", "grupo": false, "capacidade": null, "ativo": true }
```

| Método | Rota | Papéis | Retorno |
| --- | --- | --- | --- |
| GET | `/api/appointment-types` | todos | `200 { "appointment_types": [...], "cap_turma_padrao": 4 }` — **ativos e arquivados** (a tela separa) |
| POST | `/api/appointment-types` | owner/admin | `201 { "appointment_type": {…} }` |
| PATCH | `/api/appointment-types/:id` | owner/admin | `200 { "appointment_type": {…} }` — parcial |
| POST | `/api/appointment-types/:id/archive` | owner/admin | `200 { "appointment_type": {…} }` |
| POST | `/api/appointment-types/:id/restore` | owner/admin | `200 { "appointment_type": {…} }` |

`clinic_id` **nunca** no corpo — vem do `Ash.Scope`. Erros seguem a escada do `MembersController`:
`401` sem sessão · `403` papel errado · `404` inexistente ou fora do tenant · `422 { "error": "invalid",
"details": [...] }`. Sem paginação ([`09:947`](09-contrato-api.md)).

O `cap_turma_padrao` da clínica viaja **junto do GET** (irmão de `appointment_types`, no molde do
`{ members, professionals }` do `MembersController`) porque é o default do campo Capacidade no modal
e nenhum outro endpoint o expõe. Alternativa descartada: um GET extra só para ler um inteiro.

## 4. Fidelidade ao protótipo

| Aspecto | Protótipo | Aqui |
| --- | --- | --- |
| Card / título / botão "Novo tipo" | `Plus` 14px, borda sutil, 12.5px/600 [`:3229`] | ✅ |
| Linha | quadrado 30px `tint(cor,.14)` + ícone na cor · nome 13.5/600 · badge `grupo · cap N` (info, 10.5px) · `50min` mono muted · ações | ✅ |
| Modal | 480px, "Novo tipo de atendimento" / "Editar tipo" [`:2404`] | ✅ |
| Campos | Nome (placeholder "Ex.: Sessão") · grid 1fr 1fr: Duração (mono) + Cor (8 swatches 28px, borda 3px `c.text` no ativo) · Ícone (10 botões 34px, `teal.subtle` no ativo) · checkbox "Atendimento em grupo" · Capacidade condicional (120px, mono) | ✅ |
| Rodapé | Cancelar (`btnS`) + Salvar (`btnP`, desabilitado sem nome) | ✅ |
| Toast ao salvar | *"Tipo de atendimento salvo"* [`:1210`] | ✅ verbatim |
| **Excluir** | `Trash2` vermelho → remove na hora [`:1211`] | **`Archive` neutro → arquiva** (T2/T9) |
| **Arquivados** | não existe | **seção recolhível + Restaurar** (T5) |
| **Nome duplicado** | aceita | **422** (T7) |
| **Ações para não-admin** | sempre visíveis | **ocultas** (T8) |

## 5. Adiado (registrado, não implementado)

A agenda não existe — estas só mordem a partir da Fatia 1/3:

- **Editar duração** de tipo com agendamentos futuros: `ends_at` é coluna persistida
  ([`01:472`](01-dominio-ash.md)), então o passado não se move. Falta decidir se os **futuros** migram e
  se roda análise de impacto no molde do `futureConflicts` de `PATCH /clinic-hours`
  ([`09:463`](09-contrato-api.md), D12).
- **Virar `grupo`** true→false num tipo com turmas vivas: hoje passa; deveria travar.
- **Capacidade rígida (422) vs. teto soft** contornável por encaixe — divergência aberta em
  [`12:72`](12-divergencias-interface-vs-regras.md).
- **Arquivar tipo em uso**: hoje passa sem aviso. Quando houver agenda, considerar o mesmo pré-check
  com `confirm: true`.
- **Nome único é case-sensitive**: "sessão" e "Sessão" coexistem.
