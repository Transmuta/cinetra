# 69 — A linha da auditoria volta a dizer o quê, de quem e com quem

> Correção da trilha entregue em [`63`](63-auditoria-completa.md), a partir de duas queixas de uso
> (2026-07-28): *"a auditoria continua sem identificação, não dá para saber nada do que aconteceu"*
> e *"alterei um agendamento que não é de turma e veio mensagem de turma"*.
>
> Não muda decisão nenhuma da 63 — o modelo (tabela de eventos única, diff resolvido na escrita,
> redação, retenção) fica de pé. O que muda é **o que cada linha carrega** e **o que o recorte de
> um registro alcança**.

---

## 1. O que estava errado, medido no banco de dev

A tela do print estava no **"Ver histórico"** de um agendamento (`?record_id=`). Os eventos do
mesmo bloco, na ordem em que o banco os tinha:

```
00:47:29 appointment apply_participant_rollup   agendado → concluido
00:47:29 attendance  mark_present               status: prevista → concluida    (paciente)
00:47:28 attendance  transition                 motivo: "Doente" → —            (paciente)
00:47:28 appointment reopen                     faltou → agendado
00:46:55 appointment apply_participant_rollup   (diff VAZIO)
00:46:55 attendance  justify_absence            falta_justificada: false → true (paciente)
00:46:53 appointment apply_participant_rollup   (diff VAZIO)
00:46:53 attendance  justify_absence            falta_justificada: true → false (paciente)
00:46:47 appointment apply_participant_rollup   agendado → faltou
00:46:47 attendance  mark_absent                motivo: — → "Doente"            (paciente)
00:46:16 attendance  create
00:46:16 appointment schedule
```

A tela mostrou **só as seis linhas de `appointment`**. Quatro causas independentes:

| # | Defeito | Efeito na tela |
|---|---|---|
| **A** | O filtro `record_id` casava **só** a coluna `record_id`. As presenças têm id próprio. | O histórico do bloco perdia as cinco linhas que contam a história (quem faltou, por quê, quem entrou) e sobravam as do bloco — boa parte delas o mero **reflexo** daquelas. |
| **B** | `apply_participant_rollup` grava **sempre**, porque sempre bumpa a `version` (é o lock otimista do bloco). | Justificar uma falta — que não muda o desfecho — escrevia uma linha com **diff vazio**. Duas das seis linhas do print não diziam nada. |
| **C** | A frase do rollup dizia **"pela turma"**. A ação roda em todo bloco, de um paciente ou de vários. | "Atualizou a situação pela turma" num atendimento individual: afirmação falsa. |
| **D** | A regra "todo `*_id` é ruído" engolia `professional_id`. | Remarcar **trocando de profissional** gravava diff vazio: "Remarcou o agendamento", e mais nada. Três dessas no banco de dev. |

E uma quinta, que é a queixa da identificação: **cada linha só exibia a metade do contexto que o
próprio registro carrega**. O `Appointment` não tem paciente (quem tem são as presenças) e a
`Attendance` não tem profissional (quem tem é o bloco) — então a linha de agenda dizia
"Atualizou a situação · Dra. Bea · ter 28/07, 08:45", sem dizer **de quem** era a sessão. Num dia
de trabalho a agenda inteira é do mesmo profissional: todas as linhas ficam idênticas.

## 2. O que passou a valer

### A — o recorte de um bloco inclui os participantes dele

`Api.Audit.list_events/2`, filtro `record_id`:

```elixir
Ash.Query.filter(query, record_id == ^id or meta["appointment_id"] == ^id)
```

`meta["appointment_id"]` só existe em evento de presença, então o OR não alarga o recorte de
nenhum outro recurso.

**Custo, medido em 80 mil linhas** (`EXPLAIN ANALYZE`, mesmo plano da app):

| Forma | Tempo | Buffers |
|---|---|---|
| antes (`record_id = X`) | 17,4 ms | 2.106 |
| agora (com o OR) | 23,7 ms | 4.134 |

O importante é que **a forma não mudou**: as duas varrem o recorte da clínica pelo
`audit_events_feed_index` e aplicam o predicado como filtro — o `audit_events_record_index`
(`clinic_id, resource, record_id, at`) nunca anexou aqui, porque a tela não manda `resource`
junto. Fica registrado como pendência: um índice que sirva os dois ramos do OR
(`(clinic_id, record_id, at)` + expressão sobre `meta->>'appointment_id'`) transformaria a
varredura num BitmapOr. **Não foi criado agora** — a regra do projeto é que índice de expressão só
entra depois de medido *pelo caminho da app*, e a tela é de uso administrativo esporádico.

### B — escrita derivada que não muda nada não vira linha

Opção nova em `Api.Audit.Capture`:

```elixir
skip_unchanged: [:apply_participant_rollup]
```

Vale **só para `update`**: num `create` o diff vazio ainda significa "nasceu" e num `destroy` ele
é a regra. O rollup continua rodando e continua bumpando a `version` — o que ele deixou de fazer é
**relatar** o que não aconteceu.

### C — a frase não inventa turma

`Atualizou a situação pela turma` → **`Atualizou a situação pelos participantes`** (e
`Atualizou a situação` no chip do filtro). Verdadeira no bloco de um e no de vários.

### D — a FK que é decisão de alguém fica no diff

Opção nova em `Api.Audit.Capture`: `keep: [:professional_id]`, para o `Appointment`. O uuid é
resolvido **por nome** na leitura, junto com os de `meta`, e a linha passa a dizer
`Profissional: Dra. Bea → Dr. Ciro`.

### E — cada linha diz quem, com quem e quando

O enriquecimento de `Api.Audit.list_events/2` ganhou o contexto da agenda, em **duas leituras em
lote por página** (nunca uma por entrada — o N+1 que o [`25 §11.4`](25-agenda.md) proíbe na tabela
que mais cresce; travado em `test/api/audit/feed_queries_test.exs`):

- linha de **agendamento** → `participants`, os pacientes do bloco (campo novo no JSON);
- linha de **presença** → `professional`, resolvido pelo bloco.

Na tela (`entryContext`) o **quem vem primeiro**, porque é o que discrimina uma linha da seguinte:

```
Caio Paciente · Dra. Bea · ter 28/07, 08:45
Ana, Caio e mais 2 · Dra. Bea · ter 28/07, 08:45     (turma: dois nomes e a conta)
```

O paciente **não se repete** quando a própria frase já o nomeia ("Marcou a falta de Caio") — ali
o nome de novo logo abaixo é ruído, não contexto.

## 3. Verificação

- `mix test test/api/audit test/api_web/controllers test/api/scheduling/appointment_test.exs` —
  229 testes, 0 falhas;
- suíte da API inteira: **1.516 testes, 2 falhas**, as duas pré-existentes em `rls_smoke_test.exs`
  (`bulk_cancel` / `bulk_adjust`) e confirmadas como tais com `git stash` das mudanças desta fatia;
- `npm run check` (0 erros) e Vitest: 1.856 testes, 0 falhas;
- **ao vivo**, pelo caminho real (`mix run` no dev, como `cinetra_app`, com RLS ligada — o
  caminho que já escondeu bug de GUC invisível ao `mix test`): agendar → faltar → justificar →
  reabrir, e depois ler o histórico do bloco:

```
[attendance/create]                       Ana Paula · Henrique Castro
[appointment/schedule]                    Ana Paula · Henrique Castro
[attendance/mark_absent]                  Ana Paula · Henrique Castro   motivo: — → "Doente", status: prevista → faltou
[appointment/apply_participant_rollup]    Ana Paula · Henrique Castro   status: agendado → faltou
[attendance/justify_absence]              Ana Paula · Henrique Castro   falta_justificada: false → true
[appointment/reopen]                      Ana Paula · Henrique Castro   status: faltou → agendado
```

As presenças estão lá, cada linha tem paciente **e** profissional, e o `justify_absence` **não**
produziu rollup — que é exatamente o par de linhas vazias do print original.

## 4. Pendências deixadas em aberto

- **índice para o recorte por registro** (§2A) — medido, não criado; depende de volume real;
- os `participants` são os do bloco **hoje**, não os do instante do evento. É a mesma regra que
  já vale para o nome do paciente e do profissional (a trilha grava `label` no instante só onde o
  registro pode desaparecer). Um bloco excluído perde os participantes na leitura — a linha
  degrada para o que já tinha, não quebra.
