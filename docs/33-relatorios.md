# 33 — Relatórios (Fatia 9)

A tela de **Relatórios**: os agregados de período que a recepção e a gestão leem — volume,
status, taxa de falta e ocupação, quebrados por dia, por tipo e por profissional. A tela existe
no protótipo (`renderRelatorios`); o link `/relatorios` já está em
[`web/src/lib/components/shell/nav.ts:39`](../web/src/lib/components/shell/nav.ts) apontando para
404. Vertical completa — agregação no domínio `Api.Scheduling` + HTTP + BFF + tela, com TDD.

É a [Fatia 9 do roadmap](08-roadmap.md#fatia-9--relatórios). Depende de que as fatias
operacionais (agenda, ciclo de vida) já produzam dados reais — a razão de vir tarde
([02 GAP-14](02-regras-e-lacunas.md)).

Referência no protótipo `interface/Movimento.dc.html`:

| O quê | Render | Agregação | Filtros (state) |
| --- | --- | --- | --- |
| **Relatórios** (`/relatorios`) | `renderRelatorios` [`:3368`] | `reports2` [`:3335`] | `sbRelatorios` [`:1461`] — `repPeriodo`, `repProf` [`:271`] |

## 1. Decisões desta fatia

Fechadas com o usuário antes de codar (as quatro "perguntas de produto ANTES" do roadmap +
os GAPs 10/11):

- **R1 — Agregação ao vivo, não snapshot.** A [arquitetura §11](04-arquitetura.md) prescreve um
  snapshot noturno via Oban para o relatório "não varrer a tabela ao vivo". Na v1 os volumes são
  pequenos e a agregação é uma leitura única por requisição, empurrada ao SQL pelas mesmas code
  interfaces da agenda. O snapshot Oban vira **follow-up documentado** (§7), a acionar quando a
  varredura ao vivo doer de fato — não antes.
- **R2 — Três presets de período, sem intervalo livre.** Fiel ao protótipo: **Hoje / Esta
  semana / Este mês**, ancorados em *hoje* (relógio do servidor, ADR-009). O servidor recebe
  `date_from`/`date_to` crus, então intervalo custom é só UI adiada — zero retrabalho de backend.
- **R3 — Escopo por papel.** owner · admin · **recepção** veem a clínica inteira (recepção é
  operacional e precisa do volume); **profissional** vê **só os próprios** números. O recorte do
  profissional já é o da agenda (A7): reusa `OwnAgendaOnly` sem reescrever nada (§3).
- **R4 — Sem faturamento na v1.** Nenhum número financeiro. Preço/convênio/repasse são v2
  ([02 GAP-10/RN-47](02-regras-e-lacunas.md)). No protótipo `fat`/`ticket`/`brl` são **código
  morto** — computados em `reports2` e nunca renderizados ([:3346](../interface/Movimento.dc.html#L3346),
  [:3364](../interface/Movimento.dc.html#L3364)). O relatório real fica volume/status/ocupação,
  exatamente o que o protótipo de fato desenha.

## 2. Métricas (RN-46, menos o dinheiro)

Sobre o conjunto de agendamentos da janela — já recortado por papel (§3) e pelo filtro de
profissional. `ativos` = status ≠ `cancelado` (a mesma regra de `ocupaGrade`: cancelado não
disputa espaço, não conta).

| Métrica | Fórmula | Origem no protótipo |
| --- | --- | --- |
| **Atendimentos** (total) | `count(ativos)` | `reports2` [`:3341`] |
| **Concluídos** | `count(status == :concluido)` | [`:3342`] |
| **Faltas** | `count(status == :faltou)` | [`:3343`] |
| **Cancelados** | `count(status == :cancelado)` | [`:3344`] |
| **Futuros** (ainda agendados) | `count(status ∈ agendado·confirmado·em_atendimento)` | [`:3345`] |
| **Taxa de falta** | `faltas / (concluídos + faltas)`, `0` se denominador `0` | [`:3346`] |
| **Ocupação** | `minutos_agendados / minutos_de_expediente`, teto 100% | §2.1 (canônica, **não** os 9 slots) |
| **Por dia** | por data: `total`, `concluídos` | [`:3355`] |
| **Por tipo** | por `appointment_type_id`: `total` (dos ativos) | [`:3353`] |
| **Por profissional** | por profissional: `total`, `concluídos`, `faltas`, `taxa` | [`:3357`]-[`:3361`] |
| **Pico** | a data com mais `ativos` | `busiest` [`:3364`] |

O gráfico "Volume por dia" vira "Volume por profissional" quando a janela é **um único dia**
(`showDaily = dias.length > 1`, [`:3386`]) — decisão **de tela**: o backend sempre devolve `por_dia`
e `por_profissional`, e o frontend escolhe qual mostrar.

### 2.1 Ocupação canônica — a divergência que a v1 fecha (GAP-11/RN-48)

O protótipo calcula ocupação de **quatro** formas incompatíveis. A definição canônica —
já adotada por `occupancy` no protótipo ([`:908`](../interface/Movimento.dc.html#L908)) e **já
codada** no backend em `Scheduling.load_counts` (A-D12) — é:

> **ocupação = minutos agendados ÷ minutos reais de expediente**

Onde o denominador é o expediente **real** do dia, resolvido pelas 4 camadas de disponibilidade
(`Api.Scheduling.Availability.day_periods/3`) — o mesmo `capacity_minutes/3` que a visão Semana/Mês
já usa. `reports2` usava "9 slots fixos × profissionais × dias úteis" contando *agendamentos*, não
minutos ([`:3350`](../interface/Movimento.dc.html#L3350)) — **descartado**. A Fatia 9 reusa o
cálculo do `load_counts`, então relatório e barra da agenda concordam por construção.

- **Numerador:** soma de `ends_at − starts_at` (minutos) dos `ativos` da janela.
- **Denominador:** `Σ` sobre (data × profissional-no-escopo) de `capacity_minutes`. Dia fechado = 0.
- **Dias úteis:** as datas da janela com denominador > 0 (exibido como "N dias úteis").

## 3. Escopo por papel — uma regra, um caminho

O recorte do profissional **não é reimplementado aqui**. `Scheduling.load_summary/5` lê os
agendamentos pela mesma code interface da agenda (`list_appointments!`), e a preparation
[`OwnAgendaOnly`](../api/lib/api/scheduling/preparations/own_agenda_only.ex) já filtra a leitura
para a própria agenda quando o papel é `profissional` (fail-closed se `professional_id` for nulo).

O que sobra é **de tela, não de segurança**: o denominador de ocupação e a quebra por
profissional precisam saber *quais* profissionais entram na conta. Como Relatórios é **HTTP puro**
(sem Channel longevo), o `Api.Scope` da requisição é construído fresco a cada request por
`with_member_scope` — logo `scope.papel`/`scope.professional_id` são autoritativos aqui (a
ressalva do moduledoc do `Scope` é sobre processos de Channel, Entrega 3). O escopo efetivo:

| Papel | `professional_id` efetivo |
| --- | --- |
| `profissional` com vínculo | forçado ao próprio (ignora o filtro pedido) |
| `profissional` sem vínculo | conjunto vazio → relatório zerado (fail-closed) |
| owner · admin · recepção | o `professional_id` do filtro, ou **todos** os ativos |

Esse `professional_id` efetivo alimenta os três lugares de uma vez: o `filter` da leitura, o
conjunto de profissionais do denominador e as linhas da quebra por profissional.

## 4. Contrato HTTP

```
GET /api/reports/summary?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD&professional_id?=<uuid>
```

Pipeline `[:api, :authenticated]`, leitura para todo membro (`with_member_scope`) — o recorte é o
de dados (§3), não um 403 de papel. Reusa `parse_window/3` (janela ≤ 31 dias, mesma dos counts).
Divergência do [09 §3.8](09-contrato-api.md), que rascunhava `date_from=&date_to=` sem prefixo
`/api` e ação `:summary`: mantemos o padrão dos irmãos (`/api/appointments/counts` é função de
domínio, não ação Ash) — `load_summary` é função de `Api.Scheduling`, como `load_counts`/`load_agenda`.

Resposta (a fronteira nomeia o wire — o domínio devolve mapas, o controller renderiza; padrão de
`render_day_count`/`render_professional`):

```json
{
  "range": { "from": "2026-06-01", "to": "2026-06-30" },
  "totals": {
    "atendimentos": 210, "concluidos": 160, "faltas": 18, "cancelados": 12, "futuros": 20,
    "taxa_falta": 10, "ocupacao": 74, "ocupado_minutos": 12600, "capacidade_minutos": 17000,
    "dias_uteis": 26, "pico": { "date": "2026-06-12", "total": 14 }
  },
  "por_dia": [ { "date": "2026-06-01", "total": 8, "concluidos": 7 } ],
  "por_tipo": [ { "appointment_type_id": "…", "total": 90 } ],
  "por_profissional": [
    { "professional_id": "…", "total": 70, "concluidos": 55, "faltas": 6, "taxa_falta": 10 }
  ],
  "professionals": [ /* render_professional: id, nome, cor … */ ],
  "appointment_types": [ /* render_type: id, nome, cor … */ ],
  "agora": "2026-06-25T12:00:00Z",
  "timezone": "America/Sao_Paulo"
}
```

`professionals` e `appointment_types` viajam junto pelo mesmo motivo do `GET /api/appointments`:
o nome/cor das barras é lookup-no-cliente, e a quebra vem por id. O `professionals` já é o conjunto
efetivo do escopo (§3) — para o profissional, só ele; é dele também que a sidebar monta o filtro.

## 5. BFF e tela

- **`/relatorios/+page.server.ts`** — lê `period` (`hoje`·`semana`·`mes`, default `mes`) e `prof`
  do querystring, converte preset → `date_from`/`date_to` ancorado em *hoje* (o `agora`/timezone
  vêm do próprio backend; o SSR não inventa relógio), faz **um** fetch a `/api/reports/summary`.
- **`/relatorios/+page.svelte`** — os 5 KPIs, o gráfico de volume (dia → profissional no dia
  único), "Por tipo", "Composição por status" e a tabela "Desempenho por profissional", fiéis ao
  protótipo. Estados vazios ("Sem dados no período") preservados.
- **Sidebar** — período (3 presets) + profissional (Todos / cada ativo), no padrão das outras
  seções; para o papel `profissional` a lista de profissionais degenera nele mesmo (§3), então o
  filtro fica travado — o backend já o ignora.

## 6. Testes

- **Backend (TDD):** `load_summary` bate com dados reais montados por generator — totais por
  status, taxa de falta com denominador zero, ocupação (numerador/denominador em minutos, teto
  100%), pico, quebras por dia/tipo/profissional. **Escopo por papel:** profissional só vê os
  próprios; owner vê todos; filtro `professional_id` recorta. Cancelado fora de `ativos` e da
  ocupação. Janela inválida → 422.
- **Web (Vitest, gate de cobertura):** `+page.server.ts` (preset → datas, propagação do filtro,
  erro do backend) e `+page.svelte` (render dos blocos, toggle dia/profissional, vazio).

## 7. Follow-ups (fora desta fatia)

- **Snapshot noturno Oban** ([04 §11](04-arquitetura.md)) — quando a agregação ao vivo custar caro
  (R1). A code interface `load_summary` fica estável: passa a ler do snapshot em vez da tabela viva,
  sem mexer no controller nem na tela.
- **Faturamento** (R4/GAP-10) — v2, quando existir modelo de preço.
- **Intervalo de datas custom** (R2) — só UI; o backend já aceita qualquer `date_from`/`date_to`.
