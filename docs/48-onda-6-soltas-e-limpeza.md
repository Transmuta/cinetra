# 48 — A Onda 6: features soltas, auditoria e limpeza

Fecha as **Frentes 8, 9, 12 e 13** do [plano de ondas](35-plano-execucao-backlog.md) — a última
onda do backlog consolidado. Depois dela, o doc 35 não tem mais frente pendente.

A ordem de execução não foi a da tabela. Frente 13 primeiro (destravada, e o I67 limpa o terreno
de teste que as outras usam), depois 9, 12 e por fim a 8 — que é a maior e a única que precisava
de **decisão de produto** antes de existir código.

> ## ▶︎ Onde retomar
>
> Tudo entregue e verde: **1.082 testes no backend** (18 doctests, 91,2%), **1.336 no web** e os
> **4 e2e**, `0 falhas`, `svelte-check` limpo, `mix compile --warnings-as-errors` limpo, gate
> `:rls` verde como `cinetra_app`.
>
> Os dois gates de produto que bloqueavam a onda foram **decididos aqui** e estão registrados no
> §5 (A3) e no §4 (D-Aud1) — com a medição que sustenta cada um. Um terceiro item, o desenho do
> F5, foi decidido no §3.
>
> O §6 registra as decisões tomadas **depois** da auditoria, que mudaram o A3: o "salvar mesmo
> assim" foi **removido**, a contagem de conflitos virou exata, o recheck passou para dentro da
> escrita e o e2e saiu do CI. O que sobrou de débito está no [`50`](50-debitos-tecnicos.md).

## 1. O que o levantamento mudou

Como na Onda 5, medir antes de codar mudou a onda. Três itens da Frente 13 **já estavam feitos** e
só o doc 35 não sabia:

| Item | O que se achou |
| --- | --- |
| I67 — `ApiWeb.ScopeGuards` | Existe desde a fatia de Horário, com outro nome: `ApiWeb.TenantScope` (doc 23). Não havia o que extrair. |
| I67 — `in_clinic/2` | `Api.Tenancy.in_clinic/2` já é a definição única; 18 módulos a usam. |
| D-U — boilerplate de socket (D4) | Foi extraído na Onda 5, junto do S2: `abrirSocket/2` em `realtime.ts`, com os três clientes entrando por ele. |
| D-U — projeção de paciente (D5) | `WaitlistJSON.patient/1` já delega para `AgendaJSON.patient/1`. |
| D-Aud2 — índice do filtro por autor | `appointments_versions_user_id_index` e `attendances_versions_user_id_index` **já existem** — nasceram do conserto de FK sem índice da Onda 5 (doc 47 §3A). O filtro por autor da tela chegou indexado sem que ninguém tivesse essa intenção. |

O que **não** estava feito, e virou o trabalho desta onda, está nas seções abaixo.

## 2. Frente 13 — refactors e limpeza

### 2a. I67 — os catorze `sign_in` e a guarda de canal em três cópias

Dois achados independentes debaixo do mesmo item.

**Os helpers de sessão.** `defp sign_in/1` estava copiado, byte a byte, em **17 arquivos** de
teste; `defp authed/2` em 14; `defp email/0` em 30; `member_session`/`active_member_session` em 10.
Não é o teclado que custa: é que a ida-e-volta do magic link é o caminho de autenticação inteiro,
e mudá-lo significava caçar catorze cópias. Foram para `Api.Generators` (as de domínio) e
`ApiWeb.ConnCase` (as de `conn`), com `ConnCase` e `ChannelCase` passando a importar as fábricas
como o `DataCase` já fazia. **−654 linhas, +242.**

**A guarda de `join`.** `same_clinic/2` era idêntica nos três canais (agenda, fila, notificações),
e cada um relia o vínculo à sua maneira. É o **D7** do doc 29 §5, e importa mais que uma
duplicação comum: o WebSocket não passa por plug nem por RLS (R-D1, doc 28), então aquelas linhas
são a fronteira de autorização inteira daquele caminho. Três cópias de uma fronteira são três
lugares onde a próxima correção pode não chegar. Virou `ApiWeb.ChannelScope`.

De quebra, uma query a menos por `join`: `scope_for/2` lê o vínculo **com o usuário junto**
(`load: [:user]`), onde a agenda e a fila faziam duas idas ao banco.

> **A mutação que só o teste novo pegou.** Trocando `same_clinic/2` para devolver sempre `:ok`, os
> **testes dos três canais continuaram verdes** — porque a segunda guarda (vínculo ativo) também
> barra o tópico de outra clínica. É defesa em profundidade funcionando, e é também a razão de o
> `ChannelScopeTest` existir: ele isola a primeira pergunta, e foi o único a ficar vermelho.

### 2b. I68 — paginar não é navegar

O rodapé de paginação da **auditoria** não passava `replaceState`. Cada clique em "próxima"
empilhava uma entrada no histórico, então sair da tela pedia tantos "voltar" quantas páginas a
pessoa tivesse folheado. Pacientes e Fila já estavam certas; a Auditoria (mais nova) copiou o
`navigate` sem a opção.

Consertado pela raiz: as quatro telas com estado na URL (Pacientes, Fila, Auditoria, Notificações)
passaram a usar `$lib/querystring`, onde as três opções da navegação — `keepFocus`, `noScroll`,
`replaceState` — são o contrato escrito uma vez.

### 2c. D-U — o resto da duplicação fila↔agenda

- **D2** (`finish`/`parseIds`): foram para `$lib/server/mutate`, ao lado do `MutationResult` que
  ambos manipulam. `parseIds` tinha **duas versões divergentes** — a de `server/professionals.ts`
  aceitava string vazia como id válido;
- **D3** (`/pacientes` gêmeo): as duas rotas `+server.ts` eram byte-idênticas. A regra foi para
  `$lib/server/patient-search`; as rotas continuam existindo (cada picker chama a sua) e agora são
  duas linhas cada.

### 2d. D-R — o pool contra as filas, medido

O worry existia desde o doc 30 e foi agravado pela Onda 4 (doc 45 §4). A medição:

```
pg_stat_activity, dev, pool_size: 10  →  11 conexões
  10 idle em COMMIT (o pool, que as mantém abertas)
   1 em LISTEN "public.oban_insert"   ← o notifier do Oban, FORA do pool
```

E a aritmética que ninguém tinha escrito: `queues: [housekeeping: 2, notifications: 5]` significa
que **7** das conexões do pool podem estar em job ao mesmo tempo. Com o pool em 10, sobravam 3
para HTTP e WebSocket.

Duas mudanças: o default de `POOL_SIZE` foi para **16** (`7 filas + 8 HTTP/WS + 1 stager`), com a
conta escrita no `runtime.exs`; e um teste novo (`Api.ObanPoolTest`) **trava a soma dos limites das
filas**, de modo que criar uma fila — ou subir um limite — fique vermelho com a mensagem apontando
para o `POOL_SIZE`. As duas configurações moram em arquivos diferentes e nunca se olharam; agora
uma olha a outra.

### 2e. I66 — o e2e que faltava, com sessão de verdade

`e2e/switch-clinic.spec.ts` percorre a jornada inteira no browser: criar conta → magic link lido na
caixa de dev do Swoosh → onboarding → segunda clínica pelo menu → **trocar o tenant ativo** e
conferir que a tela seguinte mostra a outra clínica.

Sem atalho de sessão forjada, de propósito: forjar o cookie pularia justamente o encanamento que o
e2e existe para cobrir (o BFF repassando o `_api_key`, o `LoadScope` resolvendo o tenant, a GUC de
RLS recortando as linhas).

Três tropeços que só o teste rodando revelou, e que valem por si:

1. **`API_PUBLIC_ORIGIN` não resolve de dentro do container.** Ela é a origem *pelo browser do
   host* (`localhost:4010`); o processo do Playwright roda dentro do container, onde a certa é
   `API_URL` (`http://api:4000`). Com a errada, a sonda de "a stack está de pé?" dava negativo e o
   teste **pulava em silêncio** — que é pior que falhar;
2. **`/api/health` não serve de sonda**: está atrás do pipeline `:authenticated` e responde 401 com
   a API perfeitamente viva. A sonda certa é `/dev/mailbox/json`, que responde exatamente o que o
   teste precisa (API viva **e** `dev_routes` ligado);
3. **o `to` da caixa do Swoosh é lista de strings**, não de pares `[nome, endereço]` — e a caixa
   lista do mais novo para o mais velho, então `find` e não `pop`.

### 2f. D1 (doc 47 §4) — os índices de FK que **não** entraram

O doc 47 sugeriu a Frente 13 como casa para as quatro FKs sem índice liderando. Medido de novo,
pelo plano real:

| FK | plano | buffers |
| --- | --- | --- |
| `attendances.appointment_id` | **Seq Scan**, 10.218 linhas descartadas | **345** |
| `attendances.patient_id` | Index Scan no composto, com a coluna **não** liderando | 75 |
| `packages.patient_id` · `package_schedules.package_id` | Seq Scan em tabela de 1 linha | 1 |

**Decisão: não entram agora.** O caminho que os usaria não existe — `Appointment`, `Package` e
`Patient` não têm ação `destroy` (tudo arquiva), e a única deleção do sistema é a de `Attendance`
(sair da turma), que não dispara nenhuma destas checagens. Um índice íntegro e nunca escolhido,
mantido a cada `INSERT` de uma tabela quente, é exatamente a lição do **D-A** — e o próprio
`on_delete_test.exs` já dizia, na Onda 5, que o índice deve entrar **junto da F8** (eliminação
LGPD), medindo o caminho inteiro. Mantida a dívida declarada, com a medição agora no doc.

## 3. Frente 9 — F5, "quem está vendo este dia"

Feature nova e isolada, na mesma peça que a fila usa (`ApiWeb.Presence`) e pelas mesmas razões:
morre com o socket, não vai ao banco e não trava nada.

O desenho **não estava no protótipo**, então foi decidido aqui:

- **só a visão de DIA rastreia.** A Semana assina os 5–7 tópicos de dia da janela; rastrear no
  `join` sem filtro colocaria uma pessoa como "vendo" sete dias ao mesmo tempo, e o aviso deixaria
  de significar a única coisa que ele serve para dizer. O predicado é o `mode` que o cliente já
  declara desde o D-G/D-H (`block` = Dia/Lista);
- **a chave é o usuário, não o socket**: duas abas da mesma pessoa são uma pessoa na tela;
- **o nome vem do servidor**, do vínculo lido no `join` — nunca do corpo do cliente, como na fila;
- **na tela**, uma pilha discreta de iniciais na barra da agenda (`DayViewers`), que só aparece com
  alguém. É informação periférica, não alerta: quem de fato impede duas remarcações simultâneas
  continua sendo a exclusion constraint do agendamento.

## 4. Frente 12 — D-Aud1: a trilha perdeu o "de Z"

`countable: true` vira `COUNT(*) OVER ()`, uma window function que lê o **recorte inteiro** apesar
do `LIMIT`. Medido nos dois lados:

```
auditoria (dev, 102 linhas na clínica)   com count: WindowAgg sobre as 102, 16 buffers
                                         sem count: sort + limite,          13 buffers
caixa do sino (20.065 linhas, doc 44 §2) com count: 10.265 buffers, 12,9 ms
                                         sem count:     26 buffers,  0,11 ms
```

A diferença pequena na auditoria é só porque a tabela de dev é pequena; o que importa é a **forma**
do plano, que não depende do tamanho — e ela já tinha sido medida no extremo.

**Decisão: a trilha vai a `count: false`**, e o rodapé passa a ser "1–50" com a seta de próxima
(o `more?` continua exato — o Ash busca `limit + 1`). O critério é o crescimento: a trilha é a
tabela que mais cresce do projeto (3× a base) e "quantas versões esta clínica acumulou" não é uma
pergunta que alguém faça.

**Pacientes e Fila mantêm o total.** Não é inconsistência: aquelas listas têm teto natural
(centenas, dezenas) e o número responde uma pergunta real ("quantos pacientes eu tenho?").

## 5. Frente 8 — A3 / `futureConflicts`

A maior da onda, e a única que exigia decisão antes de código. **O motor não existia no backend** —
o doc 35 dizia "ligar", mas só o protótipo tinha.

### 5a. As duas decisões do gate

**(1) Estender a D12 às três outras portas: sim, e é bloqueio.** A D12 já dizia, para o horário do
profissional, que os futuros conflitantes *bloqueiam a mudança*. A extensão para a semana da
clínica, para a exceção da clínica e para a folga do profissional mantém a regra: **nada é gravado
enquanto houver conflito**, e a lista dos afetados volta no 409 para a pessoa resolver.

Com uma saída explícita: `confirm: true` aplica assim mesmo — e o botão que a envia **só existe
dentro do modal**, ou seja, ninguém confirma sem ter visto a lista. É o que separa um gate de um
"tem certeza?".

**(2) A precedência esquecida pela RN-16: o protótipo estava errado.** O `simulate` do `addHoliday`
dava prioridade à exceção pré-existente do **profissional** sobre a exceção da clínica sendo
simulada — *inclusive quando a nova era um fechamento*. Isso contradiz o motor real, onde
fechamento da clínica é a camada (A) e vence tudo (a assimetria "feriado vence o pontual do
profissional", `Availability`).

Em vez de escolher entre as duas regras, o `ImpactAnalysis` **não implementa precedência nenhuma**:
sobrepõe a mudança nas fontes já carregadas e pergunta ao `Availability.day_periods/3` — o mesmo
motor da agenda, da validação de escrita e do pacote. Consequência: a análise não *pode* discordar
do que vai acontecer depois de salvar, porque é literalmente a mesma função. O item da RN-16 fecha
por construção, e a divergência do protótipo fica registrada como divergência.

### 5b. O que é conflito

Só quem **cabia antes e deixa de caber depois**. Não é "está fora do novo expediente": um encaixe
já fora do expediente atual continua fora depois — a mudança não o piorou, e listá-lo transformaria
a tela num inventário de encaixes antigos a cada ajuste de horário. A comparação é sempre
*antes × depois*.

### 5c. As peças

| Camada | O quê |
| --- | --- |
| `Api.Scheduling.ImpactAnalysis` | Puro. Recebe agendamentos + fontes + a mudança; devolve os conflitos ordenados. Quatro formas de mudança: semana da clínica, grade do profissional, exceção da clínica, exceção do profissional. |
| `Api.Scheduling.future_conflicts/2` | Carrega (3 queries: agendamentos futuros abertos com teto de 500, profissionais citados, as 4 fontes por `gather_sources/3`) e enriquece com nome do profissional e dos pacientes — quem lê a lista precisa decidir o que remarcar, e uuid não ajuda. |
| Gate | `gate_de_conflitos/3`, entre a validação e a escrita das quatro portas. |
| HTTP | **409 `future_conflicts`** com a lista no `meta` (é 409 e não 422 pela regra do projeto: o pedido *está certo*, o mundo é que diz não). `confirm` no corpo, lido por `confirmado?/1` — só `true` confirma. |
| Web | `$lib/scheduling-conflicts` (parse + frases) e `ConflictsModal`, ligados nas **quatro** telas: Horário, Exceções e a ficha do profissional (grade e folgas). |

> **O `await tick()` antes do `requestSubmit()`** não é decorativo, e está comentado nos três
> lugares: no Svelte 5 o DOM só é atualizado no flush, então submeter no mesmo tick mandaria o
> hidden com o valor **antigo** (`confirm=false`) e o servidor recusaria de novo, em loop. É o
> mesmo tropeço que a presença da turma pagou (doc 41), onde só o clique ao vivo revelou.

## 6. As decisões que foram tomadas depois (2026-07-27)

Os itens que este doc tinha deixado abertos foram **decididos e implementados** na mesma sessão.
O registro de cada um está no [`50`](50-debitos-tecnicos.md) quando virou débito, e aqui quando
virou código:

### O e2e saiu do CI, e o alvo virou variável

O job `web-e2e` foi **removido**: ele precisa da stack inteira (API, banco, caixa de e-mail de dev)
e o workflow sobe só o web — um job que pula com aviso é ruído com cara de cobertura. Ele roda
local, e apontar para hml/produção é `E2E_BASE_URL` + `E2E_API_ORIGIN` (ver `web/e2e/README.md`).

Rodá-lo fora do CI **achou três specs podres na hora**: `/entrar` mudou o título ("Bem-vindo de
volta"), o estado neutro virou "Verifique seu e-mail", e o toggle de tema **mudou de lugar** — saiu
das telas de entrada e vive no `Rail` do app, então o e2e de tema passou a precisar de sessão. Os
três corrigidos; os quatro specs passam.

### O "salvar mesmo assim" não existe mais

O `confirm` saiu de ponta a ponta (domínio, fronteira, BFF, as três telas). **Mudar horário por
cima de agenda marcada não é uma opção do produto**: o modal informa o que quebraria e a recepção
remarca. Isso também dissolveu o item da ficha do profissional — não há mais como confirmar uma
lista que não foi vista, porque não há mais o que confirmar.

### A contagem é real; a lista é que tem teto

O teto de 500 **na leitura** era um buraco: se os conflitos estivessem depois do 500º, o gate
passava calado. Agora a leitura vai por `stream?` (sem teto), o `total` é exato e a resposta
detalha os **10 primeiros** — "10 de 80" é o que a recepção consegue usar; 80 linhas não.

De quebra ficou mais barato: as presenças e os pacientes são lidos **depois** de saber quem
conflita, e só para os 10 que a tela mostra.

### O recheck acontece dentro da escrita

O gate deixou de rodar antes da transação. Nas duas portas de horário ele roda **dentro** do
`Api.Repo.transaction` que grava (conflito → `Repo.rollback`); nas duas de exceção, **dentro da
ação**, num `before_action` (`CheckFutureConflicts`) — o mesmo lugar em que o `CheckAvailability`
confere o expediente ao agendar. O que resta de janela está no [`50 §D-5`](50-debitos-tecnicos.md).

### A paleta fica como está

Não era decisão em aberto, e este doc errou ao chamá-la assim. Acrescentar uma cor é acrescentá-la
nos dois lados, e há uma tripwire em cada um dizendo isso por escrito. Registrado em
[`50 §D-3`](50-debitos-tecnicos.md).

## 7. Lições

- **medir antes de codar mudou a onda de novo.** Cinco itens da lista já estavam feitos, e um
  deles (D-Aud2) por acidente feliz de outra onda. É a terceira onda seguida em que o levantamento
  vale mais que a estimativa;
- **defesa em profundidade esconde regressão.** A mutação de `same_clinic/2` passou nos três testes
  de canal porque a segunda guarda também barra. Quando duas guardas cobrem o mesmo caso, o teste
  de cada uma **isolada** é o que separa "está protegido" de "estava protegido por acaso";
- **o e2e que pula é pior que o e2e que falha.** A primeira execução pulou por uma variável de
  ambiente errada e reportou sucesso. Se a sonda de ambiente pode dar falso-negativo, ela precisa
  ser exatamente o recurso que o teste vai usar — foi o que fez trocar `/api/health` pela caixa de
  e-mail;
- **quando duas regras discordam, prefira apagar uma.** A precedência da RN-16 tinha duas
  respostas possíveis; a saída não foi escolher, foi fazer a simulação passar pelo motor real e
  deixar de existir uma segunda regra para discordar.
