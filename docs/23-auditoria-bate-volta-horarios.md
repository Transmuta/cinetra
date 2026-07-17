# 23 — Auditoria bate-volta: Horário e Exceções

Auditoria da fatia [22 — Horário e Exceções](22-horarios-e-excecoes.md), contra a stack rodando
(`docker compose`: `db`+`api`+`web`). Três eixos caçados em paralelo por subagentes
especializados (segurança, performance, refatoração/DRY), cada achado provado com sonda. Espelha
[21 — Auditoria bate-volta: Tipos](21-auditoria-bate-volta-tipos.md).

## 1. Onde parou

Caça completa (rodadas 1+2), consolidação, conserto (rodada 3) e verificação (rodada 5). **9
achados**: 0 de segurança, 3 de performance, 3+3 de DRY/rules (3 introduzidos, 3
pré-existentes/estruturais). **6 corrigidos**, 3 para decisão humana. Suíte final: backend
**246 testes, 0 falhas, 85,7%**; web **304 testes, 0 falhas, ~96%**; `mix format` limpo.

## 2. A varredura

| Eixo | Itens checados | CONFIRMADO | REFUTADO | N/A |
| --- | --- | --- | --- | --- |
| **Segurança** | RLS (leitura/escrita/fail-closed/ENABLE+FORCE), mass-assignment (`clinic_id`/`professional_id`/`confirm`), RBAC (401/403), injeção de períodos/`dow`, DoS, IDOR, BFF (`encodeURIComponent`, parse), XSS | **0** | 18 | 1 |
| **Performance** | índice FK `clinic_id`/`professional_id`, filtro `is_nil`+sort, N upserts, seed onboard, `pre_check?` | **3** | 3 | 1 |
| **DRY/rules** | format, `input/1` dup, interface morta, Members, `SetTenantGuc`, `Ash.read!`, policies, validações, idiomático, web | **6** | 8 | — |

**O que a rodada 2 (adversarial) achou que a 1 não tinha:** segurança — estresse do parser de
fronteira (`periods`/`dow` hostis via `iex` → todos `{:error,_}`, nenhum 500). Performance — F5
(7 transações no save da semana) e F3 (redundância do índice standalone só aparece ao ver o
planner escolher o composto). DRY — interface morta e a divergência do `error_field` em Members.

**Segurança: zero achados.** RLS provada de baixo, como o role `movimento_app` (NOBYPASSRLS):
GUC=A não vê linhas de B em `clinic_hours` nem `schedule_exceptions`; sem GUC, 0 linhas
(fail-closed); INSERT tagueado para outra clínica → `new row violates row-level security policy`.
Mass-assignment barrado em dobro (whitelist do controller + `accept` da ação). A fatia reusa as
defesas já validadas em Tipos/Membros e elas seguram.

## 3. As causas-raiz

1. **Higiene não rodada** (F#1): `mix format` esquecido — 7 arquivos, o gate de CI barraria o
   merge.
2. **Escrita da semana não-transacional** (F5): `update_clinic_hours` fazia 7 transações
   independentes no hot path do save — 7× o custo de checkout, e sem atomicidade.
3. **Índices desalinhados com o acesso real** (F3+F1): índice standalone de `clinic_id`
   redundante com a identidade composta que já lidera por ele; e a FK `professional_id` sem
   índice de apoio ao seu cascade.
4. **Duplicação ao extrair o `TenantScope`** (D#2+D#3): a extração levou as guardas e a escada
   de erro, mas deixou o `input/1` copiado e uma interface de leitura morta.

## 4. O que foi corrigido

| # | Causa | Sonda que achou | Conserto | Re-sonda (rodada 5) |
| --- | --- | --- | --- | --- |
| #1 | format | `mix format --check-formatted` → failed (7 arquivos) | `mix format` | `--check-formatted` → **FORMAT CLEAN** |
| F5 | 7 transações no save | telemetry: 1 `set_day` = begin+set_config+INSERT+commit | `update_clinic_hours` num único `Repo.transaction`, upserts compartilhando a GUC, `return_notifications?` emitidas fora | 97 testes verdes; **sem alerta `missed_notifications`** (prova que o caminho de notificações é exercido); 1 `Repo.transaction` por estrutura |
| F3 | índice `clinic_id` redundante | EXPLAIN escolhe o composto, nunca o standalone | drop dos dois índices standalone (migration `scheduling_index_tuning`) | `pg_indexes`: `clinic_hours_clinic_id_index` e `schedule_exceptions_clinic_id_index` **sumiram**; só restam pkey+compostos |
| F1 | FK `professional_id` sem índice | `EXPLAIN … WHERE professional_id=` → Seq Scan | índice **leading** `[:professional_id]` à mão (o Ash prefixaria `clinic_id` e não serviria) | `EXPLAIN` (seqscan off): **Bitmap Index Scan on schedule_exceptions_professional_id_index** |
| #2 | `input/1` duplicado | grep: corpo idêntico em 2 controllers | `TenantScope.whitelist/2` compartilhada; ambos delegam | tipos + exceções: 97 testes verdes; teste "IGNORA professional_id" verde |
| #3 | interface morta + read cru | grep: `define` sem chamador; `Ash.read!` na mão | `list_clinic_exceptions` usa `list_schedule_exceptions!(query: …)` | teste "lista ordenadas por data" verde |

**Migration nova (`scheduling_index_tuning`) auditada (rodada 5):** RLS segue `enabled+forced`
nas duas tabelas após o migrate (a migration só mexe em índices); FK `professional_id` agora
indexada.

## 5. O que ficou para você (decisão humana)

O item estrutural abaixo é decisão de arquitetura, não descuido.

- ~~**`MembersController` fora do `TenantScope`** (pré-existente, D#4).~~ **RESOLVIDO** (pós-auditoria,
  a pedido): `MembersController` migrado para `import ApiWeb.TenantScope`, apagadas as 5 cópias
  privadas (guardas + escada de erro). O agravante do `field: null` no 422 de convite duplicado
  sumiu junto — coberto por teste de regressão novo ("convite do mesmo e-mail duas vezes devolve
  422 com o campo preenchido"). Suíte de Membros 14/14 verde; backend 247/86,0%.
- **`SetTenantGuc` em namespace de domínio** (estrutural, D#5). A change é 100% genérica
  (lê `changeset.tenant`, seta a GUC), mas mora em `Api.Directory.Changes` e agora é reusada por
  `Api.Scheduling` — esta fatia **aprofundou** o acoplamento cruzado. Sonda: as 3
  `change Api.Directory.Changes.SetTenantGuc` em `scheduling/*`. **Correção:** mover para um
  namespace neutro (`Api.Changes.SetTenantGuc`). Não feito: é decisão de arquitetura que toca o
  `AppointmentType` e os moduledocs — não patch de auditoria.

### Sonda de UI: como foi provada, e a limitação do host

O **Playwright não pôde dirigir a UI**: no host, `localhost:5173` está **sombreado por outro app
(“Plito”)** — quirk de localhost do WSL2 —, então o browser do MCP cai no app errado (e as
sondas `snapshot`/`evaluate` do MCP ainda estavam quebradas nesta sessão). A porta publicada do
container é real, mas o processo do host na 5173 tem precedência para quem chega de fora.

O `web/` foi provado então **de dentro do container** (onde `localhost:5173` é o Movimento de
verdade), com `npm run check` (typecheck, 0 erros), a suíte Vitest (304 testes: componentes +
handlers + BFF) e um **fluxo autenticado ponta-a-ponta** via `curl`: magic link (API 4010 real) →
mailbox → `/auth/callback` (**303**, cookie `_api_key` setado) → `GET /configuracoes/horario`
(**200**, renderiza o editor: “Horário de atendimento da clínica”, “Espelhar Seg → Seg–Sex”,
“Salvar”, as linhas dos dias) e `GET /configuracoes/excecoes` (**200**, “Exceções da agenda”,
segmented “Fechar o dia inteiro/Horário específico”, “Nenhuma exceção”). Ou seja:
browser→BFF(SSR)→API→DB→render provado nas duas telas. O que falta é só o *clique* visual no
Playwright, bloqueado pelo sombreamento da 5173 no host — não uma lacuna do app.
