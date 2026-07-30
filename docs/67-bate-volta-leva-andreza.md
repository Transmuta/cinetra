# 67 — Bate-volta da leva da Andreza (AN-01, 03, 04, 05, 07)

Auditoria do que a leva do [`64`](64-leva-andreza-plano.md) entregou: a gramática visual do card
(`AN-01`), a fórmula dos KPIs (`AN-05`), o telefone obrigatório (`AN-04`), o motivo em falta e
remarcação (`AN-03`) e a origem na fila (`AN-07`).

**Alvo:** os commits `b383c16` (AN-04), `c7882ee` (AN-03/07) e `4ecd7bd` (AN-01/05), mais a
revisão do PPM que ficou fora deles. **Fora do alvo:** auditoria (`63`), comunicação (`65`) e
observabilidade — frentes de outra sessão que tocam os mesmos arquivos.

**Onde parou:** rodada 5. A rodada 1 achou 3, a 2 achou 3 (uma delas o único bug de comportamento),
a 3 consertou as cinco causas e a 5 provou os consertos na app rodando e achou 1 item novo.

---

## 1. A varredura

### Segurança

| Item | Estado | Prova |
| --- | --- | --- |
| Bypass do BFF | NÃO SE APLICA | nenhum endpoint novo; os campos entram em rotas já sob `:authenticated` |
| Tenant vindo do cliente | NÃO SE APLICA | nenhum `clinic_id` no diff vem do corpo |
| IDOR / BOLA | NÃO SE APLICA | nenhuma busca nova por id |
| Function level authz | REFUTADO | os `accept` novos são de ações existentes, com as policies existentes |
| **Mass assignment** | **REFUTADO** | `:schedule` passou a aceitar `veio_da_fila`/`dias_na_fila`; o ConnCase forja os dois no corpo e a resposta volta `false`/`nil` (`waitlist_controller_test.exs:262`, verde). `whitelist/2` itera os átomos **permitidos** e busca por chave string — sem `String.to_atom` em entrada de usuário |
| CORS / CSRF | NÃO SE APLICA | sem rota de mutação nova |
| Autenticação / token | NÃO SE APLICA | o diff não toca auth |
| XSS | REFUTADO | `grep '@html'` no diff do web = zero; a fórmula do KPI vai em `title`/`aria-label` e o nome do paciente no `title` do `ConfirmDialog`, que o repassa como prop ao `Modal` (Svelte escapa) |
| SQL injection | NÃO SE APLICA | sem SQL montado à mão |
| SSRF / open redirect / path traversal | NÃO SE APLICA | sem URL vinda da request |
| Vazamento de `clinic_id` | REFUTADO | os 4 campos novos do JSON não incluem tenant |
| Vazamento em log | NÃO SE APLICA | nenhum `Logger` novo |
| Secrets | NÃO SE APLICA | nenhum literal de credencial |
| DoS / paginação | NÃO SE APLICA | nenhuma listagem nova |
| Dependência vulnerável | NÃO SE APLICA | `mix.exs`, `mix.lock`, `package.json` intocados no alvo |

### Performance

| Item | Estado | Prova |
| --- | --- | --- |
| **N+1 no `convert`** | **REFUTADO** | o `clinic_now/1` que entrou em `Waitlist.convert/3` resolve o fuso por `ClinicTimezone.fetch/1`, que é `:persistent_term` — zero query depois da primeira |
| Seq scan / índice | NÃO SE APLICA | as duas migrations só somam colunas; nenhuma query nova filtra por elas |
| Query sem `LIMIT` | NÃO SE APLICA | sem leitura nova |
| Aggregate / calculation caro | NÃO SE APLICA | nenhum novo |
| Índice em FK | NÃO SE APLICA | nenhuma FK nova |
| Transação longa / pool | REFUTADO | o `clinic_now` roda **antes** da transação de escrita |
| Crescimento sem poda | NÃO SE APLICA | são colunas em linhas que já existiam |
| **O(n²) no front** | **CONFIRMADO** | a ocupação da coluna fazia `appts.find(...)` dentro do `filter`, num `$derived` que o tempo real reexecuta a cada push. Não é gargalo medido (n < 20 por coluna), mas ignora uma correspondência de índice que já existia |

### Refatoração

| Item | Estado | Prova |
| --- | --- | --- |
| Lógica duplicada | REFUTADO | `TelObrigatorio` é módulo único para os dois cadastros; `telefoneValido` é fonte única no web |
| Duas funções com o mesmo papel | REFUTADO (documentado) | `telefoneValido` **diverge** de `recebeWhatsapp` de propósito (não tem a guarda de estrangeiro, porque o servidor não tem) — está escrito na docstring e coberto por teste |
| Constante repetida | NÃO SE APLICA | — |
| Regra de negócio fora da action | REFUTADO | as validações vivem em `Ash.Resource.Validation`; o web só antecipa |
| **Comentário que contradiz o código** | **CONFIRMADO** | a tabela da escada descrevia a variante de 1 linha **empilhada** (41px), que o código deixou de fazer ao virar compacta |
| Elixir / Ash / OTP, item a item | REFUTADO | sem `String.to_atom`, sem `case` aninhado, sem regra em controller; `accept` novo justificado no próprio arquivo |
| Docs no repo | OK | este relatório e o `64` são arquivos locais |

**O que a rodada 2 achou que a 1 não tinha achado:** os três itens da causa **A** e **B** abaixo —
todos de *laço não fechado* ou *duas portas discordando*, que nenhuma checklist lista porque não são
defeito de linha, são defeito de percurso. É a medida do que o ângulo adversarial pagou.

---

## 2. As causas-raiz

| # | Causa | Sintomas |
| --- | --- | --- |
| **B** | **Duas portas para o mesmo desfecho, discordando** | o `reopen` do bloco não limpava o motivo da falta; o `reopen` por participante limpava |
| **A** | **`AN-03` entregue sem a ponta da UI** | `reschedule_reason` era coluna inalcançável (modal não perguntava, BFF não enviava, nada exibia); `motivo` era coletado e nunca relido |
| **C** | **O sinal novo não chegou aos vizinhos** | a legenda não explicava o badge de composição que a fatia inventou |
| **D** | **Comentário desatualizado pelo próprio diff** | a tabela da escada |
| **F** | **O(n²) desnecessário** | a ocupação da coluna |
| **E** | **Métrica com duas implementações** | `occupancyRate` (web, sem clamp) × `ocupacao_pct` (backend, clamp 100) — **não corrigido**, ver §4 |

---

## 3. O que foi corrigido

### B — o `reopen` do bloco deixava o motivo pendurado

**A sonda que achou** (`mix run` contra o banco de dev, clínica descartável):

```
DEPOIS DA FALTA : %{status: "faltou", motivo: "nao avisou"}
DEPOIS DO REOPEN: %{status: "prevista", motivo: "nao avisou"}
```

Uma presença de volta a `:prevista` carregando a explicação de uma falta que deixou de existir. A
causa: a cascata escreve pela ação `:transition`, que aceitava só `[:status, :falta_justificada]` —
o `reopen_attendance` (por participante) limpava o motivo, o do bloco não podia.

**Teste vermelho** (`appointments_controller_test.exs:1076`): *"o motivo sobreviveu ao reopen: não
avisou"*. Ele exigiu fechar o bloco antes — com uma presença só faltando, o rollup mantém
`:agendado` e o `reopen` é recusado pelo F4; as duas presenças precisam faltar.

**Conserto:** `:motivo` entra no `accept` de `:transition`, e o `maybe_reset` da
`CascadeToAttendances` passa a zerar os **dois** campos do desfecho. `reset_justificada?: true` tem
um único chamador (o `reopen`), então a mudança é escopada.

**Re-sonda (rodada 5), mesma sonda:**

```
DEPOIS DA FALTA : %{status: "faltou", motivo: "nao avisou"}
DEPOIS DO REOPEN: %{status: "prevista", motivo: nil}
```

### A — o `AN-03` não fechava o laço na tela

A D-H3 decidiu "o campo aparece sempre, com rótulo dizendo que é opcional". Metade não cumpria:

- **`reschedule_reason` era inalcançável.** `grep` no `web/` achava o campo só em fixture de teste:
  o `RescheduleModal` não perguntava, o BFF não enviava, nada exibia. Coluna que a interface não
  alcança é coluna que não existe. **Conserto:** campo opcional no modal, repasse no
  `?/remarcar` (só quando preenchido — `""` gravaria string vazia onde o "não informado" é `null`)
  e exibição no drawer, **sem** amarrar a um status: um bloco remarcado continua `agendado`, e
  condicionar a exibição esconderia o motivo no único estado em que ele é a informação nova;
- **o motivo da falta era coletado e nunca relido.** O irmão `cancel_reason` é exibido desde a
  Frente 4. **Conserto:** exibido por participante, ao lado dos controles de presença.

Testes: `AppointmentDrawer.svelte.test.ts` ganhou os dois casos.

### C — a legenda não explicava o sinal que a fatia criou

O `statusSignal` (D13) introduziu um estado visual novo: numa turma já registrada, o badge deixa de
ser a palavra do status e vira a composição ("3 de 4 concluídas"), com **ponto neutro** quando a
turma é mista. Esse ponto é o mesmo `--color-muted` de "Agendado" e "Cancelado": **três estados,
uma cor** — e a legenda descrevia dois. É o HOM-002 reaparecendo dentro da própria correção dele.

**Conserto:** terceiro bloco na legenda ("Turma"), com o badge de exemplo e o que ele significa.

### D e F — o comentário e o O(n²)

A tabela da escada passou a descrever a variante compacta (24px) em vez da empilhada (41px), que o
código deixou de fazer. E a ocupação da coluna passou a usar o índice em vez de `appts.find`, já
que `intervalos` é o `map` de `appts` na mesma ordem.

### Verificação final

- backend **1476 testes, 2 falhas** — as duas de `rls_smoke_test.exs` (`bulk_cancel`/`bulk_adjust`),
  **provadas alheias**: com a validação do profissional stashada, as mesmas duas falham;
- web **1690 testes, 0 falhas**; `svelte-check` **0 erros** (os 2 da auditoria já saíram);
- o diff dos consertos foi auditado: `:transition` não é alcançável de fora (`grep` na `api_web/`),
  os renders novos não usam `{@html}`, e o `reset_justificada?` tem chamador único.

---

## 4. O que ficou para você

### E-1 — a ocupação tem duas implementações que discordam acima de 100%

**O que é.** `occupancyRate` (web) devolve `ocupado / capacidade` **sem clamp**; `ocupacao_pct`
(backend) devolve `Kernel.min(100, ...)`. Com encaixes, a mesma clínica no mesmo período mostra
**130% na barra da agenda e 100% no KPI de relatórios**.

**A sonda.**

```
web:     return capacidade > 0 ? ocupado / capacidade : null;      # agenda-views.ts:187
backend: Kernel.min(100, round(ocupado / capacidade * 100))        # scheduling.ex:926
```

**Por que não foi corrigido.** É **estrutural e pré-existente**: a divergência já valia para Semana
e Mês, que usam `occupancyRate` desde a Entrega 2. O `AN-01` **ampliou a superfície** (levou a barra
para o cabeçalho do Dia) e **documentou a regra do backend** no tooltip do KPI — ou seja, hoje as
duas versões convivem na mesma tela e uma delas está escrita na outra. Escolher qual vale é decisão
de produto: o clamp esconde sobrecarga (que a `OccupancyBar` mostra de propósito, em vermelho), e
tirá-lo do backend muda um número que a gestão já leu.

**Qual seria a correção.** Uma fonte só: ou o backend para de grampear e o relatório passa a poder
mostrar >100%, ou `occupancyRate` grampeia e a barra perde o vermelho de sobrecarga. Não dá para
manter as duas sem escolher qual é a verdade.

### E-2 — o moduledoc da cascata ficou incompleto (achado da rodada 5)

**O que é.** A `CascadeToAttendances` documenta `reset_justificada?:` como *"zera `falta_justificada`
junto (é o caso de reabrir)"*. Depois do conserto **B**, ela zera também o `motivo` — o nome da opção
e a descrição passaram a contar menos do que o código faz.

**A sonda.** `cascade_to_attendances.ex:19` contra o `maybe_reset/2` corrigido.

**Por que não foi corrigido.** A rodada 5 não conserta — e o item é da mesma família do achado **D**
que a leva acabou de corrigir, então merece ser visto e não emendado no impulso.

**Qual seria a correção.** Uma linha no moduledoc (e, se quiser ser exato, renomear a opção para
algo como `reset_desfecho?`, que é o que ela de fato faz).

### E-3 — `data-linhas` diz 4 num card individual que desenha 3

**O que é.** O atributo nomeia o **degrau da escada**, não quantas linhas foram renderizadas: a
quarta linha só existe em turma (`{#if linhas > 3 && grupo}`). Um card individual de 50 min sai com
`data-linhas="4"` e três linhas na tela.

**A sonda.** A medição do PPM: `altura=78 linhas=4 natural=61 filhos=[16,18,15]` — três filhos.

**Por que não foi corrigido.** Só afeta teste e depuração, e renomear o atributo mexeria em asserção
de teste sem ganho para quem usa a tela. Mas ele **enganou a própria medição do PPM** durante esta
sessão, o que é argumento para o nome.

**Qual seria a correção.** Ou renomear para `data-degrau`, ou capar em 3 quando `!grupo`.
