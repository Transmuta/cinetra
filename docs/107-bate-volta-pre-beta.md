# 107 — Bate-volta geral pré-beta

**Data:** 2026-08-05 · **Alvo:** o diff da fatia "volume por dia vira calendário" (commits `2b08851`
e `b461b8a`) **mais** uma varredura de prontidão para produção · **Origem:** pedido de abrir o beta
esta semana "com mais confiança ainda".

Cinco eixos de caça rodaram em paralelo contra a stack de pé (`db` + `api` + `web`): segurança do
diff, performance/query, refatoração/DRY/testes, prontidão de infra e isolamento de tenant. Nenhum
achado deste doc existe sem output de sonda — o que não foi provado não entrou.

## 1. Onde parou, e por quê

Foi até a rodada 5. A rodada 1 achou o suficiente para justificar a 2, a 2 achou o defeito que
derruba a tela, e a 5 pegou um defeito **introduzido pelo próprio conserto** (§4.6) — que é
exatamente o que ela existe para pegar.

## 2. A varredura

| Eixo | Itens | CONFIRMADO | REFUTADO | NÃO SE APLICA |
| --- | --- | --- | --- | --- |
| Segurança (diff) | 22 | 1 | 12 | 9 |
| Performance / query | 20 | 6 | 10 | 4 |
| Refatoração / DRY / testes | 25 | 6 | 10 | 9 |
| Prontidão de infra | 10 | 4 | 6 | — |
| Isolamento de tenant | 10 | 4 | 6 | — |

O que a caça adversarial (rodada 2) achou e a checklist não tinha achado: **o 500 da §3.1**. Nenhum
item de lista pergunta "e se a janela começar num dia que a grade escondeu" — ele só aparece
seguindo o fluxo real com o calendário na mão. Foi o achado mais caro da rodada.

### O que foi refutado e vale registrar

Vários medos legítimos morreram com sonda, e isso é resultado:

- **Vazamento por tenant no `professional_id` do relatório.** Ator da clínica A filtrando pelo
  profissional de B recebe `capacidade 0` e `aberto: false` em todos os dias — a lista de
  profissionais é tenant-scoped, então nada da agenda de B atravessa. E não há oráculo de
  enumeração: a resposta é byte a byte idêntica para UUID inexistente e para UUID real de outra
  clínica.
- **XSS/injeção de CSS nos `style=` novos.** Com o servidor "mentindo" nos campos numéricos
  (`total = '99;background:url(https://evil.example/x)'`), o atributo renderizado sai vazio: a
  aritmética (`heatLevel`, `barPct`) transforma a string em `NaN` antes do atributo. CSP viva é
  `style-src 'self' 'unsafe-inline'`.
- **IDOR na fronteira**, 7 recursos (paciente, histórico, anexos, agendamento, profissional,
  membro): **404 em todos**, e o dado da vítima intacto após PATCH. Canal WebSocket cross-tenant
  recusado nos 4 tópicos, com controle positivo. Vínculo revogado derruba o join mesmo com token
  ainda válido.
- **N+1 no relatório: não existe.** 9 statements, **constantes** para janela de 1/30/90 dias e para
  1/5 profissionais. O índice `(clinic_id, starts_at)` **anexa** apesar dos casts que o AshPostgres
  injeta — a armadilha do `migrations.md` §2 não morde aqui.
- **Envs de produção, guarda de boot, migrations (84/84, `CONCURRENTLY` seguido à risca),
  `/api/ready` tocando o banco de verdade, rate limit ligado em prod, zero segredos versionados,
  log sem vazamento em `:info`.**

## 3. As causas-raiz

Os achados agrupados. Seis sintomas, quatro causas.

### 3.1 Um cast escondendo uma invariante falsa → a tela cai em 500

`monthSpans` fazia `(w.days.find((d) => d !== null) as DayPoint).date`. O `as DayPoint` afirmava ao
`svelte-check` que toda coluna de semana tem pelo menos uma célula visível — e isso é falso sempre
que a janela **começa num dia-da-semana que virou linha escondida** (`weekdays` só mantém dias
`aberto || total > 0`).

Provado na app rodando, clínica com sábado fechado, `/relatorios` **sem querystring** (`period=mes`,
o default da tela):

```
HTTP_STATUS=500
CORPO="500 | Algo deu errado | Algo deu errado | Voltar ao início"
TEM_CALENDARIO=0
```

Alcance, para uma clínica **seg–sex** (o formato mais comum), no preset padrão:

```
2026-08-01 (dia 1 = sáb)  ->  *** CRASH ***     <- o mês do beta
2026-11-01 (dia 1 = dom)  ->  *** CRASH ***
2026-02-01 / 2026-03-01   ->  *** CRASH ***
```

Para clínica que abre sábado, cai em fev/mar/nov. E no preset `trimestre` a janela começa num
domingo **toda sexta-feira** (`hoje=2026-08-07(sex) -> from=2026-05-10(dom)`).

Como o erro estoura no render do componente (não no `load`), o SvelteKit cai **para além do shell**:
o usuário perde a navegação inteira, não só o cartão.

### 3.2 Um predicado com quatro grafias em três arquivos

"Este dia é fechado?" estava escrito quatro vezes, e **já divergindo**: `reports.ts` usava
`d.total > 0`, os componentes usavam `dia.total` por truthiness. Hoje coincidem; no dia em que
`total` ganhar sentinela ou a regra passar a considerar feriado, quem corrigisse uma deixaria as
outras para trás. Daí saíam três sintomas: a linha do `calendarGrid`, o `resumo()`/ponto/estilo do
calendário e o `{@const fechado}` da semana.

### 3.3 Testes que afirmavam mais do que mediam

Treze mutações aplicadas no web, uma a uma. Cinco sobreviveram — e duas delas desfaziam **a tese do
doc 106**: dava para apagar o ponto do dia fechado e devolver a cor de heat à célula fechada com a
suíte inteira verde. O nome acessível estava coberto; a **marca visual** não.

Junto: `Math.max(1, …)` do `heatLevel` era inalcançável (comparadas as duas versões em todos os
pares `0 ≤ total ≤ max ≤ 400`, nenhuma divergia), e mesmo assim um comentário de quatro linhas, um
item do doc 106 e um teste prometiam a propriedade que ele não entregava. E a fronteira HTTP só
provava `aberto: true` — o `false`, que é a razão de ser da feature, nunca atravessava.

### 3.4 Um gate que rodava decorativo

O CLAUDE.md mandava `mix test --only rls  # roda como cinetra_app`. Não rodava: `config/test.exs`
usa `DATABASE_USER` com default `"postgres"`, que é BYPASSRLS. A rodada dava **2060 testes, 0
falhas** sem exercitar uma policy sequer. O CI está correto (o job `api-rls` passa as env vars); a
instrução local é que mentia — e mentia justamente para quem seguisse o processo antes de abrir PR.

## 4. O que foi corrigido

Ordem: segurança → performance → refatoração, causa antes de sintoma. Todo conserto entrou com
teste vermelho primeiro.

### 4.1 O 500 do calendário (causa 3.1)

Vermelho primeiro, com o helper que o próprio arquivo de teste já tinha (`2026-06-14` é domingo):

```
TypeError: Cannot read properties of undefined (reading 'date')
 ❯ src/lib/reports.ts:255:65   <- a linha do `as DayPoint`
```

Conserto em duas partes: `calendarGrid` descarta a semana sem nenhuma célula visível (além de
quebrar, ela era um vão sem leitura), e o cast saiu — `monthSpans` virou total, com fallback para a
segunda-feira da semana. **O cast era o defeito de raiz**: ele silenciou o `svelte-check` no exato
ponto em que o tipo não se sustentava.

Re-sonda na app rodando, mesmo cenário que dava 500:

```
HTTP_STATUS=200
TEM_CALENDARIO=21
```

E os quatro presets a 375px, sem rolagem horizontal de página (`docScroll == docClient == 375`):

```
TRIMESTRE={"temCalendario":true,"nCells":77,"hoje":["05/08: 11 atendimentos, 0 concluídos"]}
MES      ={"temCalendario":true,"nCells":26,"hoje":["05/08: 11 atendimentos, 0 concluídos"]}
SEMANA   ={"temCalendario":false,"hoje":["qua 05/08  11 0 concl."]}
HOJE     ={"temCalendario":false}
```

### 4.2 O predicado, numa definição só (causa 3.2)

`diaFechado/1` nasceu em `reports.ts` com teste próprio, e as quatro grafias sumiram. Sobrou uma:

```
$ rg "!dia\.aberto|!d\.aberto|d\.aberto \|\| d\.total|dia\.aberto \|\| dia\.total" web/src/
web/src/lib/reports.ts:85:	return !d.aberto && d.total <= 0;
```

### 4.3 Os testes que não mediam (causa 3.3)

- **Marca visual do dia fechado** — `data-fechado` no botão e `data-testid` no ponto, derivados de
  `diaFechado()`. As duas mutações sobreviventes agora morrem: apagar o ponto → 1 falha; devolver a
  cor de heat ao dia fechado → 1 falha (a segunda só morreu depois de o teste passar a afirmar
  também o `style`, o que a primeira versão do meu conserto não fazia).
- **`heatLevel`** — o `Math.max(1, …)` morto saiu, o comentário passou a nomear quem garante a
  propriedade (o `ceil` sobre um guard de zero) e o teste virou `heatLevel(1, 400) === 1`, que é o
  caso real "um atendimento numa janela movimentada" e que pega uma troca de `ceil` por `round`.
- **Fronteira HTTP** — teste novo cobrindo a janela segunda→domingo e afirmando
  `[true, true, true, true, true, true, false]` no wire, mais o objeto inteiro do domingo. Provado
  que pega a regressão de serialização: `render_dia` devolvendo `aberto: true` fixo → vermelho.
- **Helper duplicado** — `janelaDePontos` foi para `$lib/testing/fixtures` (pasta já fora da
  cobertura) com **um** contrato; as duas cópias com `concluidos` divergente sumiram.

### 4.4 `nextCell` com passo nulo travava a aba

Medido pelo eixo de performance: com delta `(0,0)` sobre célula vazia o `for(;;)` não termina —
5 milhões de voltas sem sair, e uma rodada de Vitest travada por inteiro. Não é alcançável pelos
quatro deltas do componente, mas o modo de falha é congelar a aba, não errar o foco. Guard de uma
linha na entrada.

### 4.5 As 39 colunas de `professionals` (performance P-3)

`summary_professionals` lia a tabela inteira — CPF, RG, PIX, banco, agência, endereço — para
renderizar 6 campos e calcular capacidade. As field policies redigem esse bloco para quem não é
owner/admin, mas **para owner/admin o dado sensível saía do banco e entrava na memória do processo
web a cada carga de Relatórios**, sem uso nenhum. É o mesmo corte que `patients_for` já tinha feito
e que Relatórios não herdou.

SQL emitido depois do `select`, capturado do log da app:

```sql
SELECT p0."id", p0."nome", p0."ativo", p0."cor_indice", p0."crefito",
       p0."nome_exibicao", p0."segue_horario_clinica" FROM "professionals"
```

### 4.6 O gate de RLS, e o defeito que o conserto dele introduziu (causa 3.4)

O comando do CLAUDE.md foi corrigido, e o teste passou a **recusar** rodar sob role que bypassa RLS
— senão a próxima pessoa recebe o mesmo verde vazio.

**A rodada 5 pegou o conserto errado.** A checagem nasceu em `setup_all`, e ali ela: (a) roda mesmo
quando a tag está excluída e (b) não tem conexão do sandbox. Resultado medido no `mix coveralls`:
`0) Api.RlsSmokeTest: failure on setup_all callback, all tests have been invalidated` — **35 testes
invalidados na suíte inteira**. Pior, o `coveralls` ainda saía com exit 0, então o estrago passaria.

Segundo erro, também pego antes de fechar: estes testes **não são excluídos por padrão** — eles
rodam junto com a suíte como `postgres`. Uma recusa incondicional quebraria o job `api` do CI.

A versão final mora em `setup` e só dispara quando a rodada **pediu** o gate (`:rls in
ExUnit.configuration()[:include]`). Os três cenários, medidos:

```
A. suíte normal como postgres        -> 35 tests, 0 failures     (status quo, CI `api` intacto)
B. --only rls como postgres          -> 35 failures, alto e claro
C. --only rls como cinetra_app       -> 0 failures               (CI `api-rls` intacto)
```

### Gates, ao fim

```
FORMAT_EXIT=0   COMPILE_EXIT=0 (--warnings-as-errors)
COVERALLS_EXIT=0   18 doctests, 2061 tests, 0 failures   [TOTAL] 90.5%
CHECK_EXIT=0    svelte-check found 0 errors and 0 warnings
WEB_COVERAGE_EXIT=0   217 arquivos, 2693 testes
```

## 5. O que ficou para você

Nada aqui foi consertado: ou é decisão de arquitetura, ou é custo/processo fora do repositório, ou
depende de acesso a produção. Ordenado por dor no dia 1 do beta.

### 5.1 Não há como saber que o beta quebrou

- **A stack de observabilidade não faz parte do deploy.** `compose.dokploy.yml` tem quatro serviços
  (`db`, `migrate`, `api`, `web`); toda menção a Alloy/Grafana/Loki ali é **comentário**. O
  `compose.obs.yml` são 8 serviços em arquivo separado, subidos à mão, sem job de CI.
- **O destinatário do alerta não chega ao container.** `grafana-alertas.yml` usa
  `${GRAFANA_ALERTA_EMAIL}`, montado `:ro` — quem expande é o Grafana, a partir do próprio ambiente.
  A variável não está no `environment:` do serviço, não há `env_file`, e o `.env.local` não a
  define. Todas as outras interpoladas estão declaradas; essa é a única esquecida. E
  `GRAFANA_SMTP_ENABLED` está ausente do `.env.local` (default `false`).
- **Não existe monitor externo de uptime**, e o desenho de health depende dele **explicitamente**
  (`compose.dokploy.yml:163`: "quem precisa saber se o produto está usável é o monitor externo").
  Está marcado `Pendente` no doc 62 desde então. Alerta hospedado na máquina que caiu não é enviado.
- **O alerta de 5xx é contagem de linha com piso 10** (`sum(count_over_time({level="error"}[5m])) >
  10`). Uma API devolvendo 500 em **100% das requisições** não alerta se servir menos de ~11
  req/5min — que é o perfil de um beta. A métrica com label de status
  (`api_prom_ex_phoenix_http_requests_total`) é raspada e não é consultada por regra nenhuma.

**Correção sugerida:** declarar `GRAFANA_ALERTA_EMAIL` no `environment:` do `grafana`, ligar o SMTP,
rodar `deploy/observability/verificar.sh` na VPS (ele foi escrito exatamente para essa pergunta) e
subir um check externo apontando para `/ready`. Trocar a regra de 5xx por razão sobre a métrica do
PromEx, com piso de volume.

**Não sondável daqui:** se a stack de obs foi subida na VPS, e se essas variáveis foram definidas
direto no painel do Dokploy fora do arquivo — o que refutaria boa parte deste item. **É a primeira
coisa a confirmar.**

### 5.2 O backup saiu do repo ontem, e o restore nunca foi ensaiado

`deploy/backup/` foi removido em `d3ced07` (2026-08-05). O próprio commit lista o que saiu junto: o
gate fail-closed antes do `migrate`, **o RPO que era 1h por construção** e a cifra `age` com privada
offline. O doc 87 §4.4/§4.5 registra como pendência aberta: conferir a periodicidade real dos
snapshots, confirmar cifra em repouso e **ensaiar o restore, que agora é 100% manual** — com a
observação "antes de existir paciente real".

O beta cria dado clínico real. Hoje a cobertura é snapshot da Hostinger + snapshot de projeto do
Dokploy, com periodicidade não verificada e procedimento de recuperação nunca executado.

### 5.3 O e2e não roda no CI, e as páginas `.svelte` estão fora da cobertura

Duas decisões defensáveis sozinhas que se cruzam num buraco: a cobertura exclui as páginas `.svelte`
**porque** são território do e2e (`vite.config.ts`), e o e2e saiu do CI em 2026-07-27. As 23 specs —
incluindo `login`, `agendar`, `tempo-real`, `a11y-*` — só rodam se alguém lembrar. É a fatia com
mais contato com o usuário.

**Correção sugerida:** rodar o e2e contra HML depois do deploy de `develop` (as env
`E2E_BASE_URL`/`E2E_API_ORIGIN` já existem para isso), em vez de subir a stack no runner.

Nota relacionada: o job `deploy` tem dois `exit 0` com aviso — sem `DOKPLOY_DEPLOY_WEBHOOK_*` ou
`DEPLOY_URL_*` configurados, ele fica **verde sem ter deployado nem verificado**. O commit `d3ced07`
diz que `DEPLOY_URL_*` nunca foi configurado; se ainda não estiver, um `deploy` verde não prova nada.

### 5.4 O gate de RLS continua cego a leitura interna — terceira medição

A regra em `.claude/rules/migrations.md` §3 já descrevia duas cegueiras. Esta rodada mediu uma
**terceira**, num ponto novo: removi o `with_clinic` de `ComputeEndsAt` (que lê `appointment_types`
dentro do caminho de escrita de `schedule_appointment`) e rodei o gate como `cinetra_app`:
**0 falhas**. O moduledoc daquela própria função conta que essa leitura já quebrou o formulário no
navegador "enquanto 463 testes passavam".

O conserto de §4.6 fez o gate parar de rodar decorativo; ele **não** resolve isto, que é estrutural
(a GUC fica pendurada na transação do sandbox). Continua valendo a regra: leitura por-tenant nova em
caminho de escrita se prova por `psql` sob o role restrito, com controle positivo — não pelo gate.

### 5.5 Dois débitos de banco, já documentados e contidos

- **`message_opt_outs` lido sem GUC** (`opted_out?/3`): sob `cinetra_app`, `false` para uma linha
  que existe; `true` sob GUC. Um paciente que pediu "SAIR" continuaria recebendo mensagem paga.
  **Contido por construção** — os dois produtores gravam `clinic_id NULL` — e já registrado em
  `docs/50-debitos-tecnicos.md:792-822`. O gatilho é o dia em que uma clínica tiver número próprio.
- **`memberships` sem RLS**: 452 linhas de 418 clínicas legíveis sob o role de produção, única das
  18 tabelas com `clinic_id` nessa condição. **Não é esquecimento** (o `LoadScope` resolve o vínculo
  antes de existir tenant; policy por tenant derrubaria o login) e a exploração pela fronteira foi
  **refutada** — `PATCH`/`DELETE /api/members/:id` de outra clínica dão 404. O que falta é defesa em
  profundidade: aqui são duas camadas, não três.

### 5.6 Performance que só aparece em escala

Medidos em banco sintético de 2M linhas (derrubado ao fim); o dev, com 30 blocos na maior clínica,
não mostra nada disso.

- **`load: [:attendances]` do papel `profissional`** vira `INNER JOIN` contra uma subquery de
  `appointments` **sem a janela** (a janela vem de `arg(:to)/arg(:from)`, e argumento de ação não é
  re-vinculável no join). Medido: 297 sondas de índice para devolver 33 linhas. **O que cresce é a
  carreira do profissional, não a janela** — 10 anos de histórico ≈ 14 ms.
- **Não há teto de linhas**, só de dias (`@max_dias 92`). Uma clínica com 5.000 blocos no trimestre:
  **270 ms e 4.701 reads a frio**, um heap block por linha (multi-tenant, inserção intercalada). O
  comentário do `@max_dias` justifica o teto dizendo que "a leitura seleciona só 4 campos", o que é
  verdade por linha e não diz nada sobre a quantidade delas.
- **`capacity_minutes` é O(dias × profissionais × exceções)** — `on_date` é `Enum.find` linear.
  Pior caso plausível (50 profissionais, exceção todo dia do trimestre): 27 ms de CPU. Um
  `Map.new(exceptions, &{&1.data, &1})` no `gather_sources` mata o termo.
- **`attendances.appointment_id` sem índice próprio**, com FK `ON DELETE CASCADE`: Parallel Seq Scan
  de 2M linhas, 87 ms por bloco deletado. **Latente** — nenhum caminho da aplicação hard-deleta
  agendamento hoje (a exclusão é `excluded_at`); o gatilho é o CASCADE a partir de `clinics`.

### 5.7 `?prof=` não-UUID derruba a tela com 500 (pré-existente)

Achado de segurança, mas de disponibilidade: `+page.server.ts` repassa `?prof=` sem validar, o
controller aceita qualquer binário não-vazio, e o Ash levanta `InvalidFilterValue` fora de um
`{:error, _}` — o `!` estoura dentro de `in_clinic/2`. Confirmado no browser logado:
`/relatorios?period=trimestre&prof=nao-e-uuid` → página 500.

**Não vaza nada** (prod não tem `debug_errors`; o cliente recebe "Não foi possível carregar os
relatórios"), e a rota tem rate limit de 200/min. É pré-existente ao diff — `git show HEAD:` mostra
as mesmas linhas — e por isso ficou fora da fila de conserto, mas é uma URL compartilhável que
qualquer pessoa produz colando um link editado.

**Correção sugerida:** `Ecto.UUID.cast/1` na fronteira do controller, caindo em `nil` ("todos") ou
422. Mais defensivo: mapear `Ash.Error.Query.InvalidFilterValue` para 422 na camada de fronteira, o
que vale para todo controller.

### 5.8 Duas notas menores

- **`URL assinada não é revogável.** TTL de 10 min (upload) / 5 min (download) / 15 min (avatar).
  Logout, revogação de vínculo e rebaixamento de papel **não** invalidam URL já emitida — natureza
  de presigned SigV4. É risco aceito por desenho, mas não está registrado como decisão. Junto:
  `no-store` está ausente em `/api/members` e `/auth/me`, que agora carregam `avatar_url` assinada,
  enquanto `/attachments/:id/download` tem — inconsistência com a régua do doc 96 S-9.
- **Queda silenciosa de clínica.** Sessão com `active_clinic_id` de clínica sem vínculo cai no
  default **sem aviso**. Não vaza (provado: o corpo não traz dado da outra clínica), mas quem teve o
  vínculo de B revogado passa a operar em A achando que está em B.

---

## Apêndice — escritas feitas durante a rodada

Todas anunciadas e revertidas:

- `cinetra_dev`: sábado da Clínica QA82 fechado e restaurado **duas vezes** (reprodução e re-sonda
  do 500), conferido idêntico ao estado anterior (`{{08:00,12:00}}`); 2 linhas em
  `message_opt_outs` criadas e removidas (tabela vazia antes e depois); um magic link pedido e
  consumido para logar no browser.
- Banco `perf_scratch` (2M linhas) criado para os planos em escala e derrubado (`DROP DATABASE`).
- Arquivos de sonda temporários criados em `api/test/` e `web/src/` pelos cinco eixos, todos
  apagados — `git status` conferido ao fim.
