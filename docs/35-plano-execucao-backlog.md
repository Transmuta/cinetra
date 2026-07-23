# 35 — Plano de execução do backlog (Ondas)

Consolidação **acionável** do que foi adiado/deferido e priorizado para execução. As fontes de
verdade dos itens continuam sendo [`08-roadmap.md`](08-roadmap.md),
[`30-decisoes-pendentes-agenda.md`](30-decisoes-pendentes-agenda.md),
[`33-relatorios.md`](33-relatorios.md) e os bate-voltas; este doc só **agrupa e sequencia** a
seleção aprovada, em frentes coesas por trilha de código + dependência.

Natureza do bloqueio: **[P]** decisão de produto · **[T]** técnico/arquitetura · **[P+T]** ambos.

## Fora desta rodada (deferidos de novo, conscientes)

Registro para não parecerem esquecidos — **não** entram nas ondas abaixo:

- **F1** (quem-cabe UI), **F7** (confirmar/iniciar), **F8** (eliminação LGPD), **F4**? — ver seleção.
- **D-B** (mês pede o mês, não a grade) → dias da grade fora do mês seguem sem contagem.
- **D-I** (cascata N+1 da turma) → transição de turma segue 3N escritas (bounded pela capacidade).
- **S4** (hold aceita profissional arquivado) → inofensivo, barrado na conversão.
- **Relatórios follow-ups** (intervalo custom, snapshot Oban) e **membros hardening** (B/C) —
  não selecionados.
- **v2 inteiro**: prontuário, faturamento/repasse, salas/recurso, multi-unidade, cifra do CPF.

## Itens que ficam PARCIAIS pela própria seleção

- **C13 (ficha):** só saem do oculto **Pacotes** (pós-A1) e **Histórico** (attendances já
  existem). **Anexos** dependem do prontuário v2 → seguem ocultos. `faltas` depende de F1.
- **F#51 (lembretes cron):** "resumo diário" e "sessão em 15 min" entram; **"paciente não
  confirmou" depende de F7** (fora) → não entra.

## Gates de decisão de produto (resolver ANTES da frente)

1. **A2 (Turma):** presença individual é requisito? + bug do `pkgOf` (ajuste em massa
   multi-pacote). *Muda schema.* — bloqueia Frente 6.
2. **A3 (futureConflicts):** estender D12 (horário do profissional) para clínica/exceção + o
   terceiro consumidor esquecido (`addHoliday`). — bloqueia Frente 8.
3. **F#48:** limiar de "paciente urgente entrou na fila". — bloqueia esse gatilho na Frente 10.
4. **D-Aud1:** semântica do rótulo "X–Y de Z" (reltuples / `countable:false`+limit+1 / contar
   só com filtro). — bloqueia Frente 12.

---

## As frentes

### Frente 0 — Enablers de medição
- **D-M** — subconjunto `@tag :rls` rodando como `movimento_app` (NOBYPASSRLS) para o gate do CI
  pegar bug de GUC/RLS. **[T]**
- **D-S** — seed **idempotente e repetível** (~1.800 linhas) numa clínica de teste dedicada, para
  tornar mensuráveis D-A/D-D/D-R. **[T]**

### Frente 1 — Quick wins / higiene
- **I69** — comentário stale em [`nav.ts`](../web/src/lib/components/shell/nav.ts) + nota de
  proveniência dos docs 01/02/03.
- **H60** / **D-T** — bumps `@sveltejs/kit` (cookie ≥ 0.7) e `mint` (CVEs).
- **H61** — `Promise.all([loadMe, loadPings])` no BFF.
- **D-E** / **D-F** — índices FK (`created_by_id`; btree próprio de `professional_id`).
- **D-P** — política DST: **empurra no gap / primeira ocorrência no ambíguo** + teste com tz DST.

### Frente 2 — Performance de leitura da agenda (medir com D-S)
- **D-C** — paginar o `:in_range`. **Antes da Fatia 3** (Pacotes reusa o read com janelas maiores).
- **D-A** — índice GiST não-parcial sobre o range (caminho do P5).
- **D-D** — `/api/availability`: remover sonda duplicada [trivial], carregar fontes 1×/janela,
  aceitar `professional_id` múltiplo, devolver `timezone` no `/auth/me`.

### Frente 3 — Tempo real & escrita
- **D-G + D-H** — contrato do canal (`block` vs `signal` no join): Semana/Mês só recarregam contagem.
- **S1** — revogação desconectar sockets já abertos da ex-clínica.
- **D-K** — cachear fuso da clínica em `persistent_term`, invalidar no `update_clinic_info`.
- **D-J** — devolver attendances do `after_action` (mata o round-trip pós-commit).
- **D-Q** — memoizar `memberships`/papel por request (corta as 5 queries do `HasClinicRole`).
- **D-N** — unificar a autoridade do recorte (escrita vs leitura) numa fonte só.

### Frente 4 — Fila de espera & holds
- **F3** — `cancel_reason` na UI. **F4** — indicador ao vivo "alguém oferecendo esta vaga".
- **F6** — paginação da fila. **D-L** — Oban cron O(clínicas)/min → statement único.

### Frente 5 — Pacotes (Fatia 3) *(depende de D-C)*
- **A1** — `computeSerie` (domínio puro + Oban), débito com falta punitiva, pausar/retomar
  reprojetando p/ futuro (GAP-06). **Precede A2, C13, notificação #47.** **[T]**

### Frente 6 — Turma (Fatia 5) *(depende de A1 + gate #1)*
- **A2** — presença + débito por participante; resolver o bug do `pkgOf`. **[P+T]**

### Frente 7 — Ficha do paciente (C13, parcial) *(depende de A1)*
- **C13** — destravar abas **Pacotes** e **Histórico** (Anexos ficam ocultos).

### Frente 8 — futureConflicts (Fatia 7, A3) *(gate #2)*
- **A3** — ligar o motor `ImpactAnalysis`/`futureConflicts` ao editar horários. **[P]**

### Frente 9 — Realtime "quem está vendo este dia" (F5)
- **F5** — `Phoenix.Presence` por dia (feature nova, isolada).

### Frente 10 — Notificações
- **Perf/estrutura:** #52 `who_fits` síncrono → Oban; #53 `mark_all_read` via `Ash.bulk_update`;
  #54 LIMIT/paginação + poda/expurgo; #55 índice `[clinic_id, recipient_id, inserted_at desc]`.
- **Gatilhos:** #46 `:faltou`; #47 `participant_added` *(pós-A2)*; #48 urgente na fila *(gate #3)*;
  #50 papel alterado/membro removido; #51 resumo diário + "sessão em 15 min"; #56 deep-link fino.

### Frente 11 — Endurecimento de produção
- **H59** — cookie `secure`, CSP/HSTS/X-Frame, sign-out via POST (CSRF).
- **S3** — hosts da CSP por ambiente (tira `localhost:4010` de prod). **S2** — token no WS via
  header/subprotocol. **H64** — semântica de `ON DELETE` por relação.

### Frente 12 — Auditoria (perf) *(gate #4)*
- **D-Aud1** — corrigir o `COUNT(*)`. **D-Aud2** — índice quando a tela expuser o filtro por autor.

### Frente 13 — Refactors / limpeza
- **I67** — extrair `ApiWeb.ScopeGuards`, `sign_in`/`authed` → `ConnCase`, `in_clinic/2`, contrato
  de paleta. **D-U** — DRY fila↔agenda. **D-R** — pool_size vs fan-out (medir com D-S). **I66** —
  e2e do `switch-clinic` + fila/WS não-vazio. **I68** — `goPage` `replaceState` (UX Pacientes).

---

## Ordem sugerida (ondas)

| Onda | Frentes | Por quê |
|---|---|---|
| **1 — Fundação** | 0, 1 | Enablers de medição + higiene barata destravam e iluminam o resto |
| **2 — Perf & tempo real** | 2, 3, 4 | Mensuráveis com a Onda 1; mesma trilha de código |
| **3 — Valor central** | 5 → 6 → 7 | Pacotes → Turma → Ficha, sequencial por dependência |
| **4 — Notificações** | 10 | Perf antes dos gatilhos; #47 só depois da Onda 3 |
| **5 — Produção** | 11 | Antes do primeiro deploy real |
| **6 — Soltas + limpeza** | 8, 9, 12, 13 | Features isoladas, auditoria e refactors por último |

**Caminho crítico:** D-C → A1 (Pacotes) → A2 (Turma) → C13/#47.

---

## Decisões da Onda 1 (registradas)

- **D-S:** seed **idempotente repetível**, versionado no repo, numa clínica de teste dedicada;
  não toca dados existentes.
- **D-M:** subconjunto marcado **`@tag :rls`** rodando como `movimento_app`; resto da suíte segue
  como `postgres`.
- **D-P:** **empurra no gap / primeira ocorrência no ambíguo** (determinístico, silencioso).
- **Entrega:** commits pequenos **direto na `develop`** (sem branch/PR nesta onda).

## Status de execução (2026-07-23)

> **Aviso importante: o [`30`](30-decisoes-pendentes-agenda.md) está parcialmente desatualizado.**
> Vários itens que ele lista como abertos **já haviam sido resolvidos** em fatias posteriores —
> em boa parte pelo commit `0a07f4c` ("liquida as pendências do doc 26"). Confirme no código
> antes de reabrir qualquer item daquele doc. Já verificados como **feitos**: D-E, D-P, H60,
> D-D, D-Q.

### Onda 1 — COMPLETA

| Item | Estado |
| --- | --- |
| **D-M** | Gate de RLS do CI **estava quebrado** (apontava para `api_test`); consertado e provado verde (7 testes `:rls` como `movimento_app`) |
| **D-T** | `mint` 1.9.1→1.9.3 — fecha CVE-2026-58229 (DoS) e CVE-2026-59249 (smuggling) |
| **H61** / **I69** | BFF paralelo (`Promise.all`) / comentário do rail |
| **D-E**, **D-P**, **H60** | **já estavam feitos** — confirmados, sem ação |
| **D-F** | Índice btree `appointments.professional_id` |

### Frente 2 (performance de leitura) — COMPLETA

| Item | Resultado medido |
| --- | --- |
| **D-S** | Seed de volume ~10k ([`volume_seed.exs`](../api/priv/repo/volume_seed.exs)), idempotente; `movimento_dev` semeado |
| **D-A** | GiST não-parcial de range + filtro reescrito como `&&`. Janela de 1 dia sobre 10,2k linhas: **10.098 descartadas → 0**, **1,119 ms → 0,117 ms**; e o custo deixa de crescer com o histórico |
| **D-C** | Paginação offset+keyset no `:in_range`, `required?: false` (nenhum chamador muda); keyset habilita `Ash.stream!` para a Fatia 3 |
| **D-D** | **já estava feito** (`load_availability_window`, `professional_id` múltiplo, `timezone` no `/auth/me`, sonda removida) — e **coberto por teste** que trava a ordem de grandeza |

Verde ao fim: api **743/0**, gate RLS **7/0**, web **1155/1155**.

### Achado ao iniciar a Onda 1 (D-M já existia, mas o gate estava quebrado)

A infra do D-M **já estava semeada**: existe [`test/api/rls_smoke_test.exs`](../api/test/api/rls_smoke_test.exs)
com `@moduletag :rls` e o job `api-rls` em [`ci.yml`](../.github/workflows/ci.yml). Porém o passo
que cria o role restrito conecta em `psql -d api_test`, enquanto o banco de teste é
`movimento_test` ([`config/test.exs`](../api/config/test.exs)). Com `ON_ERROR_STOP=1` o passo
falha antes de `mix test --only rls`; como o CI só dispara em push→`main`/PR e o trabalho corre na
`develop`, **o gate nunca rodou verde**. Correção do D-M nesta onda = tornar o gate real (nome do
banco correto) + provar verde, e não remontá-lo do zero.
