# 49 — Bate-volta: a Onda 6 (soltas, auditoria e limpeza)

Auditoria em rodadas contra a **stack rodando** do diff da Onda 6 (commit `c1cefcd`): Frente 8
(`ImpactAnalysis` + `future_conflicts/2` + gate nas quatro portas + 409 + `ConflictsModal`),
Frente 9 (presença por dia), Frente 12 (`count: false` na trilha) e Frente 13 (`ChannelScope`,
helpers de sessão, `$lib/querystring`, `mutate.finish/parseIds`, `patient-search`, `POOL_SIZE`,
e2e do `switch-clinic`).

Rodada no loop principal, sem delegar. Nenhum achado sem output de sonda colado.

## 1. Onde parou

Parou na **rodada 5**, com **três achados corrigidos** — um deles grave — e **dois itens** de
decisão humana. O achado grave só apareceu na rodada 2: a rodada 1, que segue a checklist, passou
por ele sem ver.

## 2. A varredura

### Segurança (16 itens; 0 confirmados)

| Item | Estado | Sonda |
| --- | --- | --- |
| Bypass do BFF / ataque direto na API | NÃO SE APLICA | Nenhuma rota nova; o pipeline `:authenticated` não mudou |
| Tenant vindo do cliente | REFUTADO | `future_conflicts/2` usa `scope.clinic_id`; o `professional_id` das mudanças vem do path e passa por `ensure_professional_in_clinic` **antes** do gate (leitura + ordem do `with`) |
| IDOR / BOLA | REFUTADO | Os 12 testes de `future_conflicts_test.exs` rodados como **`movimento_app`** (NOBYPASSRLS): 12/0. Inclui "não enxerga a agenda de outra clínica" |
| Function-level authz | REFUTADO | As quatro portas são `with_admin_scope`; nenhuma action Ash nova |
| Mass assignment | REFUTADO | `confirm` é lido por `confirmado?/1`, fora do whitelist que alimenta o `accept` |
| CORS / CSRF | NÃO SE APLICA | Nenhuma rota de mutação nova |
| Brute force / enumeração no magic link | NÃO SE APLICA | O e2e **usa** o fluxo; não o altera |
| Token de magic link | REFUTADO | O e2e lê `/dev/mailbox`, que só existe sob `dev_routes` (`Application.compile_env`), ausente em prod |
| OAuth (iss, sub) | NÃO SE APLICA | Fora do diff |
| Sessão / revogação | REFUTADO | `ChannelScope.scope_for/2` relê o vínculo a cada join; `channel_scope_test.exs` cobre revogado e sem-vínculo |
| Timing | NÃO SE APLICA | Nenhuma comparação de segredo no diff |
| XSS | REFUTADO | `grep '{@html'` nos componentes novos: vazio. Svelte escapa `{c.professional.nome}`, `{c.patients.join()}`, `{initials(nome)}` |
| SQL injection | NÃO SE APLICA | Nenhum SQL cru novo fora de teste |
| SSRF / open redirect / path traversal | NÃO SE APLICA | O `page.goto(pathname+search)` do e2e é código de teste |
| Vazamento de `clinic_id` | REFUTADO | Corpo real do 409 impresso: `{"error":"conflict","code":"future_conflicts","meta":{"conflicts":[{...}]}}` — sem `clinic_id` |
| Vazamento em log / secrets / headers / deps | REFUTADO | Zero `Logger` novo; `mix.lock` e `package-lock.json` intocados |

### Performance (5 concerns; 0 confirmados)

| Item | Estado | Sonda |
| --- | --- | --- |
| N+1 no `future_conflicts/2` | **REFUTADO** | `QueryCounter`: **11 queries com 1 agendamento, 11 com 6** (3 profissionais, 2 pacientes). Não cresce |
| Plano da leitura de futuros | REFUTADO | `Index Scan using appointments_clinic_id_starts_at_index`, **5 buffers** para 14 linhas |
| `count: false` da trilha regrediu algo? | REFUTADO | O `more?` continua exato (o Ash busca `limit+1`); teste de `more?` sob filtro cobre |
| `load: [:user]` do `ChannelScope` | REFUTADO | A repartição do `QueryCounter` mostra uma leitura de `memberships`, não duas |
| Gate roda em **todo** save de horário | ACEITO | 11 queries por save de expediente — ação de admin, rara. Não é achado |

### Refatoração / regras (0 violações)

`priv/` intocado (regra 1 de `migrations.md`); nenhuma migration nova; `Ash.Query` pela code
interface (`find_appointments!`), como manda `ash.md`; TDD seguido em todas as peças novas;
`mix format` e `mix compile --warnings-as-errors` limpos.

### O que a rodada 2 achou que a 1 não achou

**Tudo.** A rodada 1 fechou com zero confirmados. Os três achados abaixo vieram do ângulo
adversarial — e o primeiro deles é o mais grave da onda.

## 3. As causas-raiz

**Uma causa, dois sintomas graves, e um terceiro independente.**

**C1 — o motor recebe o mesmo dado em duas formas, e ninguém escreveu qual vale.**
`ImpactAnalysis` é chamado de dois lugares: do **domínio** (e dos testes), onde `data` é `%Date{}`
e `tipo` é átomo; e da **fronteira HTTP**, onde os dois são string. A comparação
`appt.date == data_de(attrs)` é `~D[2027-03-15] == "2027-03-15"` → **falso, sempre**.

Sintomas:

- **(a)** o gate das **duas portas de exceção** (clínica e profissional) **nunca disparava** pela
  fronteira: 201 no lugar de 409, com a exceção criada por cima da agenda;
- **(b)** `String.to_existing_atom` sobre `tipo`/`modo` — valores que o **cliente** escolhe —
  derrubava a request com `ArgumentError` (**500**) num caminho cuja escada é 422.

Por que os testes não viram: os de domínio passavam `Date` e átomos, que é a forma *interna*. **A
regra atravessava a fronteira e o teste não.**

**C2 — `modo` não era validado antes da escrita** (pré-existente, exposto pela sonda de C1-b). Um
`modo` inventado atravessava `validate_professional_week` e morria no
`{:ok, _} = set_professional_hours_day(...)` dentro da transação: `MatchError` → **500**.

**C3 — o `confirmando` da tela de Horário não zerava no erro que não é conflito**, deixando a
flag ligada para o próximo save. As outras duas telas zeravam; a de Horário era a divergente.

## 4. O que foi corrigido

### C1 — a normalização da fronteira

**A sonda que encontrou** (`ConnCase` atravessando o router, com agendamento no dia):

```
=== SONDA gate da exceção (HTTP) ===
esperado 409 future_conflicts; obtido: status 201
{"clinic_exception":{"data":"2027-03-15","nome":"Feriado",…}}

=== SONDA modo inválido (com agenda) ===
EXCEÇÃO ArgumentError: 1st argument: not an already existing atom
```

**O vermelho primeiro:** seis testes novos em `impact_analysis_test.exs`, no bloco "o rascunho
vindo da fronteira" — data em string casando, data de outro dia continuando a não afetar, `dow`
em string, enum inexistente não estourando, data malformada não estourando. 4 falhas na primeira
execução, pelas razões certas.

**O conserto:** `data_de/1` normaliza `%Date{}`/ISO-string; `dia_da_semana/1` normaliza
inteiro/string; `normalizar/2` procura o valor numa **lista fixa** (`ExceptionKind.values()`,
`WeekdayMode.values()`) em vez de criar átomo — valor fora da lista vira `:invalido`. E
`conflicts/4` ganhou `valida?/1`: diante de um rascunho que nem descreve um estado possível, **o
gate se abstém** e deixa a validação do recurso responder o 422 de sempre. Fail-open é o certo
aqui porque o gate é regra de **negócio** e o Ash barra logo em seguida — acusar conflito
devolveria 409 para o que é 422.

**Cobertura permanente:** o buraco existia porque nenhum teste atravessava o router nessa porta.
Entraram quatro testes em `clinic_exceptions_controller_test.exs` e três em
`professionals_controller_test.exs` — os dois lados que estavam mortos.

### C2 — `modo` validado antes de escrever

`validate_professional_day/2` ganhou a primeira cláusula do `cond`: `not modo_valido?(modo)` →
`{:error, "modo inválido"}`, com `@modos_validos` saindo do próprio enum. Vermelho primeiro
(`modo inventado devolve 422, não 500`).

### C3 — o `confirmando` que ficava ligado

Ramo de erro-que-não-é-conflito da tela de Horário passou a zerar `conflitos` e `confirmando`.
Sem isso, uma tentativa já confirmada que falhasse por outro motivo deixaria o próximo "Salvar"
pulando o gate **sem a pessoa ver lista nenhuma** — que é exatamente o que o D12 existe para
impedir.

### A re-sonda da rodada 5

A mesma sonda que achou, depois do conserto:

```
=== RE-SONDA rodada 5 ===
exceção da clínica sobre agenda    → 409 (era 201)
tipo inventado                     → 422
modo inventado                     → 422 (era 500)
modo AUSENTE (diff do conserto)    → 422
folga do profissional sobre agenda → 409 (era 201)
```

**Auditoria do diff dos consertos.** O código novo (`data/1`, `inteiro/1`, `normalizar/2`,
`valida?/1`, `modo_valido?/1`) reabre duas listas:

- *criação de átomo a partir de entrada* — fechada por construção: `normalizar/2` compara contra
  uma lista fixa e nunca chama `to_atom`;
- *entrada malformada derrubando a request* — a sonda "modo AUSENTE" existe por causa disto: um
  `modo: nil` passaria o `valida?` (nil não é `:invalido`) e chegaria ao `Availability.layer_d`,
  que não tem cláusula para ele — `CaseClauseError`. **O conserto de C2 fecha essa porta antes**,
  e a sonda prova (422).

**Gates, depois de tudo:** backend **1.080 testes / 0 falhas**, gate `:rls` **20 testes como
`movimento_app` / 0 falhas**, web **1.334 / 0**, `svelte-check` limpo,
`mix compile --warnings-as-errors` limpo, as duas coberturas passando.

## 5. O que ficou para você — **e o que foi decidido depois**

> **Atualização (2026-07-27).** Os dois itens abaixo foram levados para decisão e **resolvidos na
> mesma sessão**, junto de outras quatro. O registro do que virou código está no
> [`48 §6`](48-onda-6-soltas-e-limpeza.md); o que virou débito aceito está no
> [`50`](50-debitos-tecnicos.md). Em resumo:
>
> - **D1 (a ficha confirma duas listas mostrando uma)** — **dissolvido**: o "salvar mesmo assim"
>   deixou de existir. Sem `confirm`, não há como confirmar lista nenhuma;
> - **D2 (TOCTOU)** — **estreitado**: o recheck passou para dentro da transação que grava (nas
>   portas de horário) e para dentro da ação (nas de exceção), como o `CheckAvailability` faz ao
>   agendar. O que resta de janela sob `READ COMMITTED` está registrado em
>   [`50 §D-5`](50-debitos-tecnicos.md).
>
> O texto original dos dois fica abaixo, porque é o diagnóstico que levou à decisão.

### D1 — na ficha do profissional, um `confirm` cobre duas listas, e a pessoa vê uma

**O que é:** `runProfessionalSave` orquestra `updateProfessionalHours` **e**
`syncProfessionalExceptions` com o **mesmo** `confirm`. Se a grade conflita, a pessoa vê a lista
da grade, confirma — e as exceções também passam pelo gate confirmadas, sem que os conflitos
*delas* tenham sido mostrados.

**A sonda:** leitura da orquestração (`professionals.ts`), onde `confirm` é lido uma vez do form e
passado aos dois passos.

**Por que não foi corrigido:** a correção certa é uma análise **única** sobre as duas mudanças
antes de qualquer escrita — o que é mudança de contrato (um pré-check combinado, ou um endpoint
de ficha que receba grade e exceções juntas). A alternativa barata — não propagar o `confirm` às
exceções, deixando um segundo 409 aparecer — deixaria a ficha meio-salva entre os dois modais, que
é pior. É decisão de arquitetura, e a skill manda não abrir isso no meio de uma rodada.

**Qual seria a correção:** `future_conflicts/2` aceitando uma **lista** de mudanças, e a ficha
chamando-o uma vez com as duas.

### D2 — o gate lê fora da transação que escreve (TOCTOU)

**O que é:** `gate_de_conflitos/3` roda **antes** da transação de escrita. Entre a análise e o
`INSERT`, alguém pode agendar exatamente no horário que a mudança vai fechar — e o agendamento
novo fica fora do expediente sem nunca ter aparecido em lista nenhuma.

**A sonda:** leitura de `update_clinic_hours/3` — o `Api.Repo.transaction` começa depois do gate.

**Por que não foi corrigido:** fechar a janela exige a análise **dentro** da transação de escrita,
e a análise faz 11 queries em até 500 agendamentos — segurar essa transação aberta pelo tempo da
análise troca uma corrida rara por lock em tabela quente. O custo do erro é baixo (um agendamento
fora do expediente, visível e remarcável); o custo do conserto ingênuo, não.

**Qual seria a correção:** mover o gate para dentro da transação **e** trocar a leitura de 500
linhas por uma consulta que responda só "existe algum conflito?" — ou aceitar a janela, que é o
que este doc registra.
