# 85 — O link do agendamento: abrir o drawer muda a URL

Pedido de 2026-07-29: *"o que precisamos fazer para que ao abrir o drawer mude a url e assim a gente
ter um link para agendamento?"*.

Antes disso, qual bloco estava aberto era estado local do componente (`let selectedId = $state(…)`
em [`agenda/+page.svelte`](../web/src/routes/(app)/agenda/+page.svelte)): o drawer só existia na aba
de quem clicou, e não havia como mandar um agendamento para alguém. Agora ele viaja em
`?agendamento=<uuid>`, e `/agenda?agendamento=<uuid>` — sem data — abre o bloco direto, no dia certo.

Uma decisão de escopo foi do usuário, no meio da fatia:

| Decisão | Escolha | Consequência |
| --- | --- | --- |
| Redirect para o dia do bloco quando a URL discorda | **Não ter** — "é ruim para UX" | O link resolve o dia **sem** 302; remarcar para outro dia continua só fechando o drawer (§3) |

## 1. Duas fontes, dois papéis — e por que a URL não basta

O caminho óbvio (derivar tudo de `page.url.searchParams`) **não funciona**, e o modo de falha é
silencioso: a barra de endereço muda e o painel não abre.

`pushState`/`replaceState` do SvelteKit — o *shallow routing* — escrevem em **`page.state`** e
deliberadamente **não** em `page.url`. Está no fonte
(`@sveltejs/kit/src/runtime/client/client.js`): as duas funções guardam `page.url.href` em
`PAGE_URL_KEY` justamente para **restaurar** a URL da última navegação real no `popstate`. Ou seja,
depois do primeiro clique, `page.url` continua sendo a URL com que a página carregou.

Então cada fonte responde uma pergunta diferente:

| Fonte | Responde | Quem a escreve |
| --- | --- | --- |
| `?agendamento=` em `page.url` | "que bloco este **link** aponta" | navegação real (link colado, `goto`, F5) |
| `page.state.agendamento` | "que bloco está aberto **agora**" | `pushState`/`replaceState`, e o `popstate` do back/forward |

A combinação é uma linha, e o que a faz funcionar é a diferença entre `undefined` e `null`:

```ts
const noEstado = $derived((pageState.state as { agendamento?: string | null }).agendamento);
const selectedId = $derived(
  noEstado !== undefined ? noEstado : pageState.url.searchParams.get('agendamento')
);
```

* **`undefined`** — o shallow routing nunca falou deste bloco: vale a URL. É o link recebido (e
  renderiza no SSR, sem piscar), e é também o que o back restaura, porque o `popstate` devolve o
  estado daquela entrada do histórico.
* **um id** — abriu por clique.
* **`null`** — fechou por clique, e precisa ser explícito: a URL que sobra em `page.url` ainda tem o
  parâmetro, então "estado vazio ⇒ vale a URL" reabriria o painel que o usuário acabou de fechar.

## 2. Por que shallow routing, e não `goto`

O load da agenda lê `url.searchParams`, e o SvelteKit reexecuta todo load que depende da `url`. Com
`goto`, **cada bloco aberto** custaria a busca do dia inteiro: `GET /api/appointments` mais o
`GET /api/availability` de todas as colunas. O shallow routing muda a URL sem reexecutar load nenhum.

Isso é medido em [`e2e/link-agendamento.spec.ts`](../web/e2e/link-agendamento.spec.ts) pela
**ausência** de requisição, contada na rede do browser — não por um mock dizendo "chamei pushState",
que continuaria verde se o Kit mudasse de contrato.

## 3. A regra que evita a tela pular de data: `date` na URL manda

O link canônico (`/agenda?agendamento=<id>`, sem data) precisa que **alguém** descubra o dia. Quem
descobre é o servidor, em [`diaDoBloco`](../web/src/routes/(app)/agenda/+page.server.ts) — uma
leitura por id, convertendo `starts_at` (instante UTC) para o dia **local** da clínica. Sem essa
conversão, um bloco às 22h30 em São Paulo (01:30Z) abriria a agenda de amanhã, sem o bloco.

Mas resolver o dia pelo bloco **em toda carga** teria um efeito ruim: ao remarcar um agendamento para
outro dia, o load reexecuta com o `?agendamento=` ainda na URL, e a tela levaria a recepção para a
data nova no meio do atendimento. Daí a regra:

> **`date` na URL manda.** Com data, é aquele dia que carrega, e bloco fora dele não abre o drawer
> (o comportamento de sempre). Sem data — o link canônico — o bloco decide.

E a tela sustenta a regra: abrir o drawer escreve `date` junto do id. Parece redundante (a tela já
está naquele dia), mas é o que fixa o dia enquanto o painel está aberto. Remarcar para outro dia
volta a ser o que sempre foi: o bloco sai da janela e o drawer fecha.

O mesmo `?agendamento=` também **força uma visão que mostra blocos**: Semana e Mês carregam contagem,
não bloco (doc 25 §10), e um link para um agendamento ali abriria uma barra de ocupação e nenhum
drawer. A Lista fica como está — já mostra os mesmos blocos do Dia.

### Nada de `goto` na navegação com o painel aberto

`navigate()` (setas de data, troca de visão, ocultar coluna) passou a **largar** o `agendamento`:
trocar de dia fecha o drawer. Sem isso o id sobreviveria à navegação e o painel tentaria abrir um
bloco fora da janela nova.

## 4. Histórico: abrir empilha, trocar de bloco refina

`pushState` ao abrir — o **back fecha o drawer**, que é o que se espera de um painel. Trocar de bloco
com ele já aberto usa `replaceState`: empilhar ali faria o back passear pelos blocos visitados antes
de fechar. É o I68 da paginação da Auditoria, documentado em
[`querystring.ts`](../web/src/lib/querystring.ts), aplicado a outro estado da mesma natureza.

## 5. O backend: uma leitura por id que já existia

`GET /api/appointments/:id` são ~15 linhas no controller porque a leitura já estava escrita:
`Api.Scheduling.load_visible_appointment/2`, a **mesma** que o push do `AgendaChannel` usa. Com ela
vêm de graça as quatro recusas que um permalink precisa ter:

| Caso | Resposta | De onde vem |
| --- | --- | --- |
| Bloco de outra clínica | 404 | tenant do escopo (multitenancy por atributo) |
| Bloco excluído (soft-delete, doc 40) | 404 | `prepare HideExcluded` |
| Bloco do colega, papel `profissional` | 404 | `prepare OwnAgendaOnly` (A7) |
| Id malformado | 404 (não 500) | o `nil` do `case` |

Reimplementar o recorte na fronteira do HTTP seria a segunda cópia da regra — e um permalink que
vaza é pior que um permalink que não abre. A resposta leva `timezone` (é ele que diz a que dia local
o bloco pertence) e o sidecar `patients`, pelo mesmo motivo do GET da janela: quem chega pelo link
não baixou dia nenhum, e o bloco carrega ids, não nomes.

O 404 aqui é **caso normal**, não exceção: `fetchAppointment` degrada para `null` e o link inválido
abre a agenda de hoje. Nunca uma tela de erro — a mesma decisão do `?paciente=` da ficha.

## 6. Copiar link

Botão de ícone no cabeçalho do drawer, do mesmo peso do X. O que vai para a área de transferência é
a forma **canônica** (`appointmentLink`, em [`$lib/agenda.ts`](../web/src/lib/agenda.ts)) — sem a
data que está na barra de endereço, porque quem recebe pode abrir o link depois de o bloco ter mudado
de dia.

O toast sai **depois** de a área de transferência aceitar. Dizer "copiado" sem ter copiado é a
mentira do doc 52 §6 outra vez, agora custando uma mensagem colada em branco.

## 7. Quem passou a apontar para o bloco

Um permalink só vale o que se liga a ele. Seis lugares da aplicação falavam de uma sessão e paravam
no dia dela — ou em nada:

| Lugar | Antes | Agora |
| --- | --- | --- |
| Sino (`notificationHref`) | `/agenda?date=` — o dia, e ache a linha | o bloco de que o aviso fala |
| Trilha de auditoria ("Ver na agenda") | o dia do evento | o registro que a linha descreve |
| Ficha → Histórico de atendimentos | nada (leitura sem saída) | cada linha abre a sessão |
| Ficha → Próximas sessões | nada | cada linha abre a sessão |
| Prévia de conflito de horário | nada — "remarque antes de aplicar" | cada conflito abre o bloco, **em outra aba** |
| Sessões do pacote | nada | cada sessão abre o seu bloco |

Todos passam pelo **mesmo** helper, `appointmentHref(id, date)` — e ele leva as **duas** metades,
ao contrário do link de copiar. A diferença é o que acontece quando o bloco não está mais lá:

* link que **viaja** (WhatsApp, e-mail) é aberto dias depois, então data congelada é risco: sem
  ela, o servidor resolve o dia pelo bloco e o link nunca quebra;
* link que a **aplicação** mostra é lido em minutos, e aí a data é o **degrau de queda**: pela regra
  do §3, um bloco excluído (ou remarcado outra vez) ainda abre o dia de que o aviso falava, em vez
  de cair no hoje da clínica sem relação com o que se clicou.

Detalhes que não são simetria:

* **De onde sai o id.** Na trilha depende da natureza da linha: na de agendamento o registro tocado
  **é** o bloco (`record_id`); na de presença o registro é a presença, e o bloco vem do contexto
  (`meta.appointment_id`). Usar o `record_id` nas duas mandaria um id de `attendance` para a agenda
  — que não casa com bloco nenhum e não abriria nada, sem erro visível.
* **`data` e `meta` são jsonb livre**, então id que não é uuid não vira parâmetro de URL. Sem o
  bloco, o link degrada para o dia (é o `appointmentHref(null, date)`).
* **`session_soon` era o único aviso de bloco sem `appointment_id`** no payload — o job passava só o
  `starts_at`. Passou a receber o bloco inteiro; é o aviso mais imediato do conjunto (quem o lê está
  a 15 minutos de atender), e era o que menos podia parar no dia.
* **`slot_opened` mudou de destino**: ia para `/fila` e agora abre o bloco cancelado/faltou, porque
  é no drawer dele que mora a lista de **quem cabe naquele horário** com o "Agendar" ao lado
  (AN-12, doc 64). `/fila` era o destino de antes daquela seção existir, e obrigava a recepção a
  refazer no olho o casamento que a notificação já tinha feito ("3 pacientes cabem"). Sem id no
  payload, cai na fila como antes.
* **`daily_digest` continua no dia**, e é o único que deve continuar: ele é sobre N sessões ("você
  tem 6 amanhã"), não sobre uma.
* **A prévia de conflito abre em outra aba** — o único link do app assim. O 409 não salvou nada,
  então o formulário de horário atrás do modal ainda tem a edição inteira por aplicar; navegar nesta
  aba jogaria fora exatamente o trabalho que o modal está pedindo para viabilizar.

## 8. O que a unidade não pegava

O primeiro desenho (só a URL) **passou em oito testes de unidade** e falhou no primeiro clique do
browser. A causa: o mock de `$app/state` era um objeto solto, então o `$derived` nunca recalculava e
o teste media o render inicial para sempre.

O conserto do teste é tão importante quanto o do código, e virou ferramenta:
[`$lib/testing/fake-page.svelte.ts`](../web/src/lib/testing/fake-page.svelte.ts) é um `$app/state` de
mentira **reativo** (daí o `.svelte.ts`, que permite runes fora de componente), com `url` e `state`
separados — e os mocks de `pushState`/`replaceState` fazem o que o Kit faz: escrevem o estado, não
tocam a URL.

Vale para qualquer tela que derive comportamento da URL. Sem isso, o e2e seria a única rede — e o
Playwright **não roda no CI** neste projeto (decisão de 2026-07-27, `playwright.config.ts`).

Cobertura da fatia:

| Camada | Arquivo | Prova |
| --- | --- | --- |
| Domínio/HTTP | `appointments_controller_test.exs` | 200, 401 e os quatro 404 (mutei o actor da leitura e o teste de A7 ficou vermelho) |
| BFF | `lib/server/appointments.test.ts` | id escapado, 404 → `null`, rede fora |
| Load | `agenda/page.server.test.ts` | dia local do bloco (22h30 → dia anterior), `date` manda, visão coagida |
| Tela | `agenda/page.svelte.test.ts` | abre pelo link e pelo clique, fecha de fato, não empilha, não navega na hidratação |
| Puro | `lib/agenda.test.ts` | o link canônico não leva `date`; o interno leva as duas metades |
| Browser | `e2e/link-agendamento.spec.ts` | zero recarga ao abrir, back fecha, link canônico resolve o dia, link morto sem erro no console |
| Destinos (§7) | `notifications.test.ts`, `AuditEntry`, `PatientHistory`, `PatientUpcoming`, `ConflictsModal`, `PackageSessionsModal` | cada um aponta para o bloco, com o dia local (não o UTC) e degradando quando não há id |
| Payload | `reminders_test.exs` | `session_soon` passou a carregar `appointment_id` |

Do lado do dado real, `notifications.data` no banco de desenvolvimento já traz
`appointment_id` + `date` em todo aviso de agenda — a serialização (`NotificationsJSON`) manda
`data` inteiro, então o que o fan-out grava é o que o sino lê.

## 9. O que ficou de fora

* **Limpar o parâmetro órfão** de um link morto. Exigiria shallow routing na hidratação, e é
  exatamente aí que o roteador ainda não iniciou (`started` só vira `true` depois do `hydrate` —
  `client.js`), o que em dev é erro no console. O parâmetro não abre nada e não sobrevive ao próximo
  carregamento; o `?paciente=` inválido tem o mesmo tratamento.
* **A borda do dia no e2e.** O caso que prova a conversão de fuso (bloco de 22h, cujo dia UTC é o
  seguinte) fica no teste do load, com fuso mockado: a API recusa criar agendamento fora do
  expediente, e nem encaixe passa (bloqueio absoluto, D14).
* **Link para a fila, o pacote ou a ficha.** Só o agendamento ganhou permalink; os outros continuam
  alcançáveis apenas pela navegação.
* **`package_bulk_adjusted`/`_canceled` no sino.** São N sessões em datas diferentes — não há um
  bloco nem um dia para onde levar. Abrir a agenda no padrão continua sendo o certo.
* **E2E do sino até o drawer.** O elo foi verificado ao vivo pela ficha (link → clique → drawer, sem
  erro no console) e cada metade tem teste; um e2e do sino exigiria semear membro `profissional`
  vinculado a usuário só para observar o fan-out, e provaria a mesma composição.
