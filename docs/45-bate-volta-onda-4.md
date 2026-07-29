# 45 — Bate-volta: a Onda 4 (notificações + e-mail de acesso removido)

Auditoria do que a sessão de 2026-07-26 construiu: a Frente 10 inteira ([doc 44](44-onda-4-notificacoes.md))
mais o e-mail de acesso removido. A Onda 3, que divide o working tree, ficou **fora do alvo** —
já foi auditada no [doc 43](43-bate-volta-onda-3.md).

**Onde parou:** foi até a rodada 5. A rodada 1 fechou com achados, a 2 acrescentou dois que a
checklist não pegaria, a 3 deu conta da fila inteira (a 4 não foi necessária) e a 5 re-sondou
tudo e achou um item novo no código dos próprios consertos.

**Verde ao fim:** API **1009 testes / 0 falhas / 91,1%**, gate `:rls` **20/0** como
`cinetra_app`, web **1275 / 0** e `svelte-check` limpo, `mix format --check-formatted` e
`--warnings-as-errors` sem ruído.

---

## 1. A varredura

Nenhum achado entrou sem output de sonda. Os `REFUTADO` abaixo foram refutados **medindo**, não
lendo.

### Segurança — zero confirmados

| Item | Estado | Sonda |
| --- | --- | --- |
| Fronteira da API sem BFF | **REFUTADO** | `curl` direto na :4010 → `GET /api/notifications` **401**, `POST /read-all` **401** |
| Tenant vindo do cliente | **REFUTADO** | `clinic_id` nunca sai de params; o controller só lê `unread`/`limit`/`offset`. `UPDATE` em massa emitido carrega `clinic_id = $5` do escopo |
| IDOR / BOLA no `mark_all_read` | **REFUTADO** | SQL emitido: `WHERE (read_at IS NULL) AND (recipient_id = $4) AND (clinic_id = $5)` — a policy filter-check **virou cláusula do WHERE**, não sobrou como checagem por registro |
| Function-level authz nas ações novas | **REFUTADO** | Introspecção: `inbox`→policy ✓, `mark_all_read`→policy ✓. `notify` (create) **sem** policy = forbid por default do Ash, que é o desenho (escrita só de sistema) |
| Mass assignment | **REFUTADO** | `accept` de `mark_read` e `mark_all_read` = `[]` |
| XSS no e-mail novo | **REFUTADO** | `emails.ex` só tem `text_body` nos dois e-mails; sem `html_body`, não há vetor |
| SQL injection no `Poda.em_lote/4` | **REFUTADO** | 2 chamadores, ambos com tabela e condição **literais de módulo**; valores vão parametrizados. O risco está documentado no moduledoc |
| Open redirect no deep-link | **REFUTADO** | `dateParam` exige `^\d{4}-\d{2}-\d{2}$`; o resto são caminhos literais |
| Vazamento de `clinic_id` | **REFUTADO** | `NotificationsJSON` não serializa `clinic_id` |
| Args de job com PII | **REFUTADO** | Os 5 workers carregam só UUIDs e timestamps |
| CSRF / CORS | **NÃO SE APLICA** | Nenhum verbo ou rota nova; `read-all` já existia |
| Auth / magic link / OAuth | **NÃO SE APLICA** | O diff só troca a marca e o texto do e-mail; nenhum caminho de credencial |
| Path traversal / SSRF | **NÃO SE APLICA** | Sem upload e sem `fetch` de URL vinda de request |

### Performance

| Item | Estado | Sonda |
| --- | --- | --- |
| Cron O(clínicas) lendo o caro antes do barato | **CONFIRMADO** → CR-A | 139 queries/rodada; 21 de 23 clínicas sem ninguém a avisar tinham a agenda lida assim mesmo |
| `oban_jobs` sem poda | **CONFIRMADO** → CR-B | 779 jobs `completed` em 4 dias, nada os apagando; o diff acrescenta +314 linhas/dia |
| Índices novos não usados | **REFUTADO** | `pg_stat_user_indexes` pelo caminho da app: `inbox_index` idx_scan 4, `unread_index` idx_scan 1 |
| Índice redundante | **REFUTADO** | O parcial não é prefixo do outro: predicados distintos, e os dois anexam |
| Paginação ausente | **REFUTADO** | É o próprio #54; teto de 200 em `Api.Pagination` |
| `clinics` sem GUC voltando vazio no servidor | **REFUTADO** | `pg_class.relrowsecurity`: `clinics` **f**, `memberships` **f** (globais por ADR-017). Como `cinetra_app` sem GUC: 23 clínicas visíveis |
| Pool vs concorrência | **PARCIAL** → §4 | `pool_size: 10` contra `housekeeping: 2 + notifications: 5`. É o D-R, que já estava aberto — este diff o agravou |
| N+1 no request | **NÃO SE APLICA** | Os caminhos novos de request são leitura paginada + COUNT |

### Refatoração

| Item | Estado | Sonda |
| --- | --- | --- |
| Segunda fonte da verdade do "bloco aberto" | **CONFIRMADO** → CR-E | `appointment.ex:339` tem a lista idêntica no guard do `:cancel`; `AppointmentStatus` não tinha `aberto?/1` — enquanto o irmão `Attendance` tem `viva?/1` "ao lado do enum" |
| Comentário que contradiz o código | **CONFIRMADO** → CR-A | O docstring de `para_cada_dono/3` afirmava que a pergunta barata vinha antes da cara; o código fazia o contrário |
| Namespace emprestado (`Poda.clinicas/0`) | **CONFIRMADO** → §4 | Os crons de notificação dependem de `Api.Housekeeping.Poda` para listar clínicas; listar clínica não é poda |
| Regra de negócio fora da action | **REFUTADO** | Fan-out e policies nos lugares de sempre; o controller só traduz params |
| Rules do Elixir (pattern matching, `map_size`, nomes) | **REFUTADO** | `map_size(donos) == 0` no lugar de `== %{}`; predicados sem `is_`; sem `String.to_atom` |

**O que a rodada 2 achou que a 1 não acharia:** os dois consertos de correção — **CR-C** (falha de
entrega engolida) e **CR-D** (janela de unicidade com margem zero). Nenhum dos dois está em
checklist nenhuma; os dois saíram de perguntar "o que acontece quando isto falha?" e de rodar o
mecanismo para ver.

---

## 2. As causas-raiz

### CR-A — o cron lia o caro antes do barato 🔴

Medido, 23 clínicas no dev: **139 queries por rodada** do `SessionSoonJob`, sendo 23 leituras de
agenda — uma por clínica. E:

```
clinicas_com_prof_usuario | clinicas_sem_ninguem_para_avisar
                        2 |                              21
```

21 daquelas 23 varreduras eram trabalho jogado fora, **a cada 5 minutos, para sempre** —
6.048 varreduras de agenda por dia sem destinatário possível.

É a mesma classe do **CR-7 da Onda 3** ([doc 43](43-bate-volta-onda-3.md)), e a diferença é que
lá doía por clique e aqui doía por tique de relógio. Pior: o docstring que eu mesmo escrevi em
`para_cada_dono/3` **afirmava** que a ordem certa estava aplicada. A ordem vivia nos chamadores
(os dois jobs), enquanto a guarda barata estava dentro de uma função que só rodava depois da
leitura cara.

### CR-B — a fila que executa as podas não tinha poda 🔴

O projeto ganhou duas podas (trilha e caixa) e nenhuma para `oban_jobs`:

```
   state   | count        tamanho | mais_antigo | mais_novo
 completed |   779        744 kB  | 2026-07-21  | 2026-07-25
```

779 linhas em 4 dias de dev, nada as apagando — e a Onda 4 garante **+314 linhas por dia**
(288 do `SessionSoonJob` + 24 do resumo + 2 das podas), antes de qualquer job por evento.

### CR-C — a falha de entrega do único canal era engolida 🔴

O e-mail de acesso removido existe porque é o **único** canal que alcança quem saiu. E ele não
tinha sinal de falha nenhum:

```
retorno de send_access_revoked_email/2: {:ok, %{id: "d3b8e5..."}}
perform com clínica inexistente: :ok
```

`Api.Mailer.deliver/1` devolve `{:error, _}` — **não levanta**. O `rescue` que existia no job
nunca via a falha, e `perform/1` devolvia `:ok` incondicionalmente. Um SMTP fora do ar marcaria a
tentativa como concluída: sem retry, sem log, sem rastro.

### CR-D — a janela de unicidade tinha margem zero ⚠️

```
unique declarado: [period: 300, fields: [:worker]]
insert 1: id=818 conflito?=false
insert 2 (imediato): id=818 conflito?=true  mesmo_id?=true
insert 3 (300s depois, anterior completed): id=819 conflito?=false
```

A dedupe é real e conta jobs `:completed`. O cron roda a cada 300 s e a janela era de 300 s:
bastava a rodada seguinte chegar uma fração de segundo cedo para ser engolida como duplicata, e o
lembrete pararia de sair **em silêncio**. E a unicidade não protegia de nada — quem garante uma
inserção por intervalo já é o próprio cron.

O irmão do achado: `max_attempts: 3` num job de **janela**. A janela é derivada do relógio de
quando o job roda, então uma retentativa 30 s depois cobre um intervalo diferente e **sobreposto**
ao da rodada seguinte — o profissional receberia o mesmo lembrete duas vezes.

### CR-E — terceira cópia da lista de "bloco aberto" 🟡

`@vivos [:agendado, :confirmado, :em_atendimento]` nos lembretes é a mesma lista que
`appointment.ex:339` usa no guard do `:cancel` ("cancela-se um bloco **aberto**"). O
`AppointmentStatus` não tinha função nenhuma para isso — enquanto o irmão `Attendance` já resolve
exatamente assim, com `viva?/1` "ao lado do enum que define os status".

---

## 3. O que foi corrigido

Cinco consertos, todos com **teste vermelho antes**, re-sondados na rodada 5 com a mesma sonda que
achou o achado.

| Causa | Conserto | Re-sonda (rodada 5) |
| --- | --- | --- |
| **CR-A** | `Reminders.por_dono_da_coluna/4` substitui `para_cada_dono/3`: a janela entra como argumento e as **duas** leituras acontecem na mesma função, na ordem certa — não há como um chamador novo inverter | **139 → 55** queries/rodada; `appointments` **23 → 2**, exatamente as 2 clínicas com dono de coluna. Guarda: teste conta queries em `appointments` e exige **0** numa clínica sem vínculo |
| **CR-B** | `{Oban.Plugins.Pruner, max_age: 7 dias}` na lista de plugins | Teste de configuração vermelho→verde; a janela de 7 dias é escolha humana registrada no config |
| **CR-C** | `perform/1` separa as duas saídas: sumiço de conta/clínica → `:ok` (não é caso de retry); falha de entrega → `{:error, motivo}` + log | Adapter `Api.Support.FailingMailer` força a falha; o job agora devolve `{:error, {:network, :sem_relay}}` e loga `entrega falhou` |
| **CR-D** | `unique` removido dos crons; `max_attempts: 1` nos dois jobs de lembrete | Teste: duas inserções seguidas não se dedupam (ids distintos, `conflict?` falso) e os dois workers declaram `max_attempts: 1` |
| **CR-E** | `AppointmentStatus.abertos/0` + `aberto?/1` ao lado do enum; `Reminders` e o guard do `:cancel` passam a ler de lá | 144 testes de notificações + agendamento verdes, incluindo as transições de cancelamento |

Auditoria do diff dos consertos (a segunda tarefa da rodada 5): o `FailingMailer` troca
`Application.env` global — sondei se algum teste `async: true` manda e-mail e **não há**: os 29
arquivos que tocam e-mail são todos `async: false`. **REFUTADO**.

---

## 4. O que ficou para você

Nada aqui foi corrigido, e cada item diz por quê.

| Item | Sonda | Por que não agora | Correção proposta |
| --- | --- | --- | --- |
| ~~**Os doctests de `AppointmentStatus` não rodam**~~ ✅ **FEITO** (2026-07-26, por decisão sua depois do relatório) | Não havia `doctest Api.Scheduling.AppointmentStatus` em teste nenhum | — | `test/api/scheduling/appointment_status_test.exs` criado: os 2 doctests passaram a rodar, mais um teste que afirma que todo status de `abertos/0` é valor do enum — um átomo com typo ali não quebra compilação, vira filtro que nunca casa |
| **`memberships` ainda é O(clínicas) por tique** | Depois do CR-A: 23 queries em `memberships` a cada 5 min, uma por clínica; escala linear | Fora do escopo do achado consertado (que era a ordem, não a cardinalidade), e a correção muda a forma de `Fanout.professional_users/1`, que tem outros chamadores | Uma query só, agrupada por `clinic_id` (`memberships` não tem RLS), respondendo "quem tem vínculo profissional" para todas as clínicas de uma vez. É o D-L aplicado aqui |
| **Pool contra a concorrência das filas** | `pool_size: 10` vs `housekeeping: 2 + notifications: 5` | É o **D-R**, item já aberto na Frente 13 — este diff o agravou, não o criou | Decidir o par (pool, concorrência) junto, com a medição do D-R |
| **`Poda.clinicas/0` emprestando namespace** | Os crons de lembrete dependem de `Api.Housekeeping.Poda` para listar clínicas | É nome, não comportamento; mover agora espalharia churn por 4 arquivos sem ganho medível | Mover `clinicas/0` + `por_clinica/1` para um namespace neutro — mesma dívida do `SetTenantGuc`, que já está anotada |
| **`session_soon` pode ser ruído** | — | Decisão de produto de 2026-07-26, tomada **contra** a recomendação 🔴 do doc 31 §3d | Tirar a linha do crontab. Fica registrado que a objeção existe |
| **`Membership` sem trilha de auditoria** | `pg_class`: só `appointments_versions` e `attendances_versions` | Estrutural, e já registrado no doc 44 §4 | `TrailMixin` no `Membership` — mesmo gesto dos outros dois recursos |

---

---

## 5. Segunda passada (2026-07-26, mesma sessão)

A primeira passada deixou **quatro lacunas de cobertura**, identificadas numa auto-revisão. A
segunda passada existiu para fechá-las — e as duas que ninguém tinha olhado renderam achado.

### O que as lacunas devolveram

| Lacuna | Resultado |
| --- | --- |
| **Sonda 2 do IDOR** (RLS cross-tenant), nunca rodada | **REFUTADO com prova.** Como `cinetra_app` com a GUC da clínica A: `a_ve_a = 66`, `a_ve_b = 0`, `SELECT` sem `WHERE` = 66 (não 71), e `UPDATE` cross-tenant = **UPDATE 0**. A segunda defesa existe e morde |
| **`web/` nunca exercido no browser** | **2 achados** — ver CR-1 e CR-2 abaixo |
| **`SELECT *` desnecessário** | **REFUTADO com prova, e a auto-revisão estava errada.** Mesmo plano e **mesmos 4 buffers** com 18 colunas ou com 2, sobre 11 linhas reais: a tupla do heap vem inteira de qualquer jeito. Eu tinha chamado isso de "achado provável" **lendo a lista de colunas** — o mesmo erro do D-A. Só reabre se `obs` passar do limiar de TOAST |
| **Rodada 2 rasa** | Fluxo real contado + fronteira forçada: o fluxo rendeu o CR-1; a fronteira **REFUTOU** o IDOR por HTTP (404 e `updated_at` da linha alheia intacto, 5 dias antigo) |

### CR-1 — o badge fazia duas queries, e a primeira era lixo 🔴

Contado num carregamento real de `/pacientes` (`docker compose logs api`):

```
SELECT n0."read_at" FROM "notifications" ... (limit 1)   ← ninguém lê o resultado
SELECT coalesce(count(*), $1) FROM "notifications" ...   ← o número
```

O `fetchUnreadCount` pedia `?unread=1&limit=1` e **descartava a lista**. No endpoint mais chamado
do sistema — roda no load do layout, em toda navegação. O #54 tinha trocado "1 query + transferência
enorme" por "2 queries + transferência mínima", quando "1 query + nenhuma transferência" estava
disponível.

**Conserto:** rota própria `GET /api/notifications/unread-count`, devolvendo `{unread: N}`.
**Re-sonda:** a mesma navegação agora emite **uma** query em `notifications`, o `COUNT`.

### CR-2 — página além do fim era um beco com mensagem mentirosa 🟡

Sondado no browser, numa caixa de 65 notificações:

```
page=2 -> linhas=20  botoes_off=0
page=4 -> linhas=5   botoes_off=1     (65 = 20+20+20+5)
page=5 -> linhas=0   botoes_off=0     ← nem rodapé
```

O rodapé só renderiza dentro do `{:else}` de "há linhas", então numa página fora de faixa o
usuário via **"Nenhuma notificação — avisamos aqui quando algo mudar"** tendo 65, e sem caminho de
volta que não fosse editar a URL. Chega-se lá quando a poda apaga linhas enquanto se pagina, ou
por link velho.

**Conserto:** o `load` redireciona (303) para a primeira página quando `current > 1` e não há
resultado — mesmo espírito do `parsePage`, que já normaliza `?page=` inválido. Caixa
genuinamente vazia na página 1 continua sendo estado vazio.
**Re-sonda:** `page=5 -> 303 -> /notificacoes`, e seguindo o redirect: 20 linhas.

### Auditoria do diff destes consertos

A rota nova reabre a lista de fronteira, e ela foi passada: **401** sem sessão, corpo é
exatamente `{"unread":0}`, e `mix phx.routes` confirma que não há colisão com `/notifications`
nem com `POST /notifications/:id/read`. O `redirect/2` aponta para um literal — sem parâmetro do
usuário, sem open redirect.

**Verde ao fim da segunda passada:** API **1014 testes / 0 falhas / 91,2%**, gate `:rls` **20/0**,
web **1278 / 0**, `svelte-check` limpo.

### O que a segunda passada acrescenta ao handoff

| Item | Sonda | Por que não agora | Correção proposta |
| --- | --- | --- | --- |
| `fetchUnreadCount` duplica o `try/catch` + `apiFetch` de `fetchNotifications` | Leitura do diff do conserto | Achado da rodada 5, que não conserta. E é duplicação pequena, com justificativa (formatos de resposta diferentes) | Uma casca `getJson(event, path)` compartilhada pelas duas |

---

## 6. Sobre o método

- **A rodada 2 pagou a auditoria.** A checklist achou os dois problemas de volume (CR-A, CR-B);
  os dois de **correção** — entrega engolida e cron que se auto-dedupa — saíram de perguntar "o
  que acontece quando isto falha?" e de **rodar o mecanismo**. Nenhuma lista os teria pego.
- **O docstring mentiroso foi pista, não ruído.** O que denunciou o CR-A foi ele afirmar uma
  ordem que o código não tinha. Comentário que descreve intenção é útil justamente por poder ser
  confrontado com a execução.
- **Conserto estrutural > conserto pontual.** O CR-A poderia ter sido resolvido movendo duas
  linhas em cada job. Foi resolvido movendo a **decisão** para dentro de uma função só, com a
  janela como argumento — assim o próximo chamador não tem como errar a ordem. A Onda 3 consertou
  o mesmo problema no `Fanout` de forma pontual, e ele voltou uma onda depois, em outro arquivo.

### E o que a segunda passada ensinou

- **A auto-avaliação de cobertura não vale como cobertura.** A primeira passada foi declarada
  completa e tinha quatro lacunas. Duas eram inofensivas; duas renderam achado, e uma delas
  (CR-1) estava no caminho mais chamado do sistema. Rodar a skill de novo custou menos que
  confiar na estimativa.
- **Achado sem sonda mente nas duas direções.** O `SELECT *` foi listado como "achado provável"
  por leitura da lista de colunas, e a medição mostrou **zero** diferença de buffers. É o mesmo
  erro do D-A — concluir pela forma do SQL em vez do plano — só que desta vez inventando um
  problema em vez de perder um.
- **O browser acha o que o teste de componente não acha.** O beco do `?page=5` passou por
  `svelte-check`, por 7 testes de componente e pela leitura do template. Bastou pedir a página no
  servidor com uma sessão real.
