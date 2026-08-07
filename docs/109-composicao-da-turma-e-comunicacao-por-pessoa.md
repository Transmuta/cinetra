# 109 — Composição da turma e comunicação por pessoa

**Data:** 2026-08-06 · **Fatia:** drawer do agendamento em grupo · **Camadas:** domínio, fronteira
HTTP, BFF, tela.

## O buraco

O drawer de uma turma sabia dizer **o que aconteceu** com cada participante — presença por pessoa,
pacote por pessoa, motivo da falta por pessoa (doc 41 / A2) — e não sabia mudar **quem está** na
turma.

Do lado do domínio isso já existia: `Api.Scheduling.Appointment` tem `:add_participant` e
`:remove_participant` desde a A-D4 (doc 41 etapa 3), com validação de capacidade compartilhada com
a criação, guard do último participante e evento de tempo real (`participant_added` /
`participant_removed`). O que faltava era **rota**. O `router.ex` expunha criar, remarcar, cancelar,
reabrir, excluir e as quatro sub-rotas de presença — nenhuma das duas de composição.

Na prática:

- **entrar** numa turma só acontecia de rabeira: abrir o modal de *novo agendamento*, reconstruir
  profissional, tipo, data e hora de cabeça e torcer para cair no mesmo slot, para o servidor fundir
  (o merge do `schedule_appointment/2`). Quem estava com o bloco aberto na tela tinha de sair dele;
- **sair** não tinha caminho nenhum. A alternativa que a tela oferecia era cancelar o bloco — que
  cancela a sessão dos **quatro**, exatamente o dano que a `:remove_participant` foi escrita para
  evitar.

E a comunicação com o paciente vivia numa segunda lista, no rodapé do painel: a timeline (doc 52 §6)
já era por participante, mas ficava a 300px da lista de participantes. Responder *"quem ainda não foi
avisado?"* numa turma de quatro era comparar duas listas das mesmas quatro pessoas, e nenhuma das
duas respondia sozinha.

## As decisões (2026-08-06)

| Pergunta | Decisão |
| --- | --- |
| Onde | No **drawer** do bloco existente. O modal de criar já compunha a turma na criação. |
| Tirar da turma | **Confirma antes, e não avisa o paciente.** Sem `kind` de mensagem novo — quem precisa avisar fala com o paciente. |
| Comunicação | **Na linha do participante**, com o histórico completo seguindo no rodapé. |
| Turma cheia | **Oferece "adicionar como encaixe"** para quem tem o papel (A9). |
| Presença já resolvida | **Pode tirar**, sem cerimônia no servidor — a tela é que avisa o que se perde. |
| Pacote ao adicionar | Entra **avulso** nesta fatia. Vincular a pacote continua sendo do fluxo de pacotes. |
| Permissões | A matriz de sempre: compor turma é `owner`·`admin`·`recepcao`; disparar mensagem inclui `profissional`. |

## O que foi feito

### 1. Duas rotas novas

```
POST   /api/appointments/:id/participants              patient_ids, encaixe?, expected_version
DELETE /api/appointments/:id/participants/:patient_id  expected_version
```

As duas entram por `Api.Scheduling.transition_appointment/5`, o mesmo wrapper do ciclo de vida, e
não por uma porta própria. É o que as faz herdar de graça as três coisas que toda escrita de bloco já
tem: o fetch sob `in_clinic` (GUC da RLS), o guard de `version` (409) e o 404 do bloco que o papel
`profissional` não enxerga. Elas **são** escrita do bloco — é lá que moram as policies A8/A9 e o
`AgendaNotifier`.

O `DELETE` tira **um** por vez, ainda que a ação aceite lista: a URL de um DELETE nomeia um recurso,
e é assim que a tela usa (uma linha, um X).

### 2. Um bug encontrado no caminho: `:add_participant` não avançava a `version`

Era a **única** mutação do bloco sem `BumpVersion` — `:remove_participant`, `:reschedule`, `:cancel`,
`:reopen`, `:exclude` e `:set_pkg_hold` todas avançavam. E o moduledoc da irmã já dizia por quê:
*"a `version` bumpa, invalidando o cliente que tinha a composição antiga"*. Entrar na turma muda a
composição exatamente como sair dela; a assimetria era acidental.

O que ela custava: dois recepcionistas com o mesmo bloco aberto, um adiciona P3, o outro remove P2
com o `expected_version` de antes — a segunda escrita passava, **sem 409**, e quem a fez nunca ficava
sabendo que a turma tinha mudado. O locking otimista existe para esse caso e estava desligado
justamente na ação que a composição da turma mais usa.

Pego pelo teste `POST participants adiciona e avança a versão do bloco`, escrito antes do conserto.

### 3. Os dois erros do remover ganharam forma de contrato

`Changes.RemoveParticipants` devolvia `InvalidArgument` nos dois casos, o que dava **422 genérico**
para duas situações que a tela precisa distinguir:

- *não está nesta turma* → agora `Ash.Error.Query.NotFound` → **404**. É a resposta certa para
  `DELETE /participants/:patient_id`: o recurso da URL não existe;
- *é o último* → agora `code: last_participant` → **422 com código**, que é o canal por onde o drawer
  aponta a saída certa ("cancele o agendamento") sem repetir o texto do servidor.

`Api.Packages.Bulk` decide `sozinho?` antes de chamar e nunca cai em nenhum dos dois — a mudança é
de contrato da fronteira, não de comportamento da massa.

### 4. A releitura das presenças no resultado

`ManageParticipants` devolve o que o `manage_relationship` acabou de gravar; `RemoveParticipants`
devolve o que sobrou de uma leitura própria. **Nenhuma das duas passa pelo `bloco_load/0`** — então
aproveitá-las faria o bloco sair da fronteira sem os campos de pacote, e o cartão da agenda perderia
o pacote de todo mundo no primeiro participante que entrasse ou saísse. É o mesmo defeito que o
`bloco_load/0` existe para evitar, pela porta nova.

Por isso `transition_appointment/5` relê nas duas ações. Custa uma leitura a mais numa escrita que é
clicada uma vez por participante, não por sessão.

### 5. A tela

**Tirar da turma** — um X fantasma por linha (só assume `danger` no hover/focus, o tratamento que o
Excluir do rodapé já usa), com `ConfirmDialog` antes. O texto do diálogo **muda** quando a presença
já tem desfecho:

> A presença de Maria já tem desfecho e será **apagada** junto — se ela consumia uma sessão de
> pacote, a sessão volta para o pacote.

Isso não é enfeite. A presença é **destruída**, não cancelada, e o consumo do pacote é
`count :usadas, :attendances` no servidor — então tirar quem compareceu **devolve a sessão ao
pacote**. O servidor permite de propósito (é o caminho de desfazer um lançamento errado); quem não
podia deixar isso acontecer em silêncio era a tela.

**Adicionar** — fechado por padrão, atrás de um clique: a turma é lida muito mais vezes do que é
composta, e um combobox sempre aberto no meio da lista disputaria a atenção com os controles de
presença. Turma cheia **não** desabilita nada por antecipação — a capacidade é limite operacional, e
o servidor a trata assim (422 `group_full`). A tela deixa tentar, e o 422 vira a oferta de encaixe,
exatamente como o `schedule_conflict` faz no criar e no remarcar.

**Comunicação por pessoa** — cada participante ganhou uma linha de resumo
(`ParticipantCommunication`) com o estado atual e o botão de disparo. A regra do botão é a do
**servidor**, não a da timeline: há botão exatamente quando o `Dispatch` aceitaria o disparo (sem
`sem_envio`, sem trava de repetição). O rótulo muda com o histórico — "Enviar" na primeira vez,
"Reenviar" depois.

A resposta do paciente ganha do estado da mensagem: "Entregue" é um fato sobre o envio, "Confirmou
presença" é um fato sobre a **sessão**, e é o segundo que muda o que a recepção faz a seguir.

### 6. O que saiu junto

O "Reenviar" **saiu da timeline** e a `podeReenviar/1` foi apagada. Ele mudou de lugar; não ganhou um
irmão. Dois botões para o mesmo POST dariam duas respostas para a mesma pergunta — que é a mesma
razão pela qual o antigo "Enviar agora" já tinha sido removido daquela seção. A timeline passou a ser
histórico **puro**: cada tentativa, o canal de cada uma, a resposta e o instante de tudo.

A `podeReenviar/1` era deliberadamente mais estreita (só depois de uma falha) porque governava um
botão pendurado no histórico. Com a ação morando na linha da pessoa, manter duas regras para "posso
mandar?" na mesma tela seria a divergência contra a qual o próprio `$lib/messages.ts` alerta em três
lugares.

### 7. O segundo bug encontrado no caminho: o drawer fechava a cada ação

Relatado ao vivo: *"quando faço alguma ação no drawer de agendamento, ele fecha"*. Não era da
composição da turma — era de **todas** as ações do painel desde sempre; a turma só o tornou óbvio,
porque adicionar e tirar gente são duas ações seguidas no mesmo painel e a segunda não tinha painel
para acontecer.

**A causa: `page.state` é volátil.** Qual bloco está aberto viajava só ali (shallow routing, para o
`goto` não refazer a busca do dia inteiro a cada bloco aberto). Medido no browser em 2026-08-06:
depois de um `invalidate('agenda:dados')`, `history.state` continua com `{agendamento: <id>}` e a
barra de endereço também — só o espelho em memória do Kit volta a `{}`. E o `page.url` que sobra é o
da última navegação **real**, que nunca teve o parâmetro; então a segunda fonte (a URL, que serve o
link recebido) também dizia "nenhum bloco aberto".

A frequência é o que fazia doer: toda mutação do drawer termina em `invalidateAll` (o default do
`use:enhance`) e o tempo real ainda recarrega sozinho 400ms depois do evento da própria escrita.

**O conserto** é uma terceira fonte, acima das duas: `intencao`, um `$state` local com o que **esta
aba** abriu ou fechou por clique — que sobrevive à recarga porque não é o Kit quem a escreve. Quem a
zera é o `popstate`, porque no back/forward é o histórico que sabe se aquela entrada tinha painel
aberto, e é exatamente aí que `page.state` volta a ser confiável (o Kit o restaura da entrada).
`navigate` (trocar de dia/visão) também a zera: a navegação de verdade devolve a palavra à URL.

Duas medições fecham o caso, e a segunda importa tanto quanto a primeira:

```
invalidate('agenda:dados') com o painel aberto → page.state {} → drawer fechado   (antes)
o mesmo, depois do conserto                     → drawer aberto                    (depois)
back com o painel aberto                        → drawer fechado                   (antes e depois)
```

O primeiro teste e2e escrito para isto **passava com o bug de pé**: ele afirmava logo depois do
clique, e o painel só fechava na janela dos 400ms do `recarregar`. Daí a espera explícita
(`DEPOIS_DA_RECARGA`) no arquivo — sem ela o teste não prova o que o nome dele diz.

## Testes

| Camada | Onde |
| --- | --- |
| Fronteira HTTP | `api/test/api_web/controllers/appointments_controller_test.exs` — `describe "composição da turma (doc 109)"`: 13 testes (versão, `group_full`, encaixe, 409, 403 do `profissional`, 400 sem ids, último participante, 404 do forasteiro, tirar quem concluiu, 401) |
| BFF | `web/src/lib/server/appointments.test.ts` — rotas, escape de id, propagação de `group_full` e `last_participant` |
| Actions | `web/src/routes/(app)/agenda/page.server.test.ts` — `adicionar_participante` e `remover_participante` |
| Lógica pura | `web/src/lib/messages.test.ts` — `comunicacaoDaPessoa` (11 testes) |
| Componentes | `AppointmentDrawer.svelte.test.ts` (composição + comunicação), `AddParticipant.svelte.test.ts`, `ParticipantCommunication.svelte.test.ts` |
| Página (drawer × recarga) | `web/src/routes/(app)/agenda/page.svelte.test.ts` — sobreviver ao `invalidate`, e o back continuar fechando |
| e2e | `web/e2e/drawer-permanece-aberto.spec.ts` — cancelar e compor a turma, no browser de verdade |

### E a leitura nova, que `mix test` é cego para provar

`presencas_do_resultado/4` acrescentou uma **leitura por-tenant depois da escrita**, dentro do mesmo
fluxo — exatamente a segunda cegueira do gate `:rls` descrita em
[`.claude/rules/migrations.md`](../.claude/rules/migrations.md) §3: a GUC da escrita anterior fica
pendurada na transação do sandbox e o cenário roda verde mesmo sem `in_clinic`.

Provada por `psql`, sob o role restrito, com o controle positivo junto (2026-08-06):

```
cinetra_app, sem GUC   → attendances: 0    appointments: 0
cinetra_app, com GUC   → attendances: 31
postgres (superusuário)→ attendances: 31
```

O `0` sozinho não distinguiria "RLS funcionando" de "tabela vazia"; o `31` dos dois lados é o que
fecha. A leitura está dentro de `in_clinic(scope, …)` no wrapper, que é quem seta a GUC.

O gate `--only rls` também foi rodado sob `DATABASE_USER=cinetra_app` (35 passaram) — ele prova a
porta de entrada, não esta leitura, e está registrado aqui para não ser confundido com a prova acima.

## O que ficou de fora, e por quê

- **Vincular a pacote ao adicionar** → registrado como **D-28** em
  [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md). O `:add_participant` aceita `package_id` e a
  fatia manda `nil`: quem entra pelo drawer entra avulso, e a sessão não debita do pacote. É o item
  com custo real dos dois, porque é silencioso.
- **Avisar o paciente ao tirar da turma** → registrado como **D-29**. Decisão explícita: nenhuma
  mensagem sai. Exigiria um `kind` novo em `Api.Messaging` — o `cancelamento` fala do bloco inteiro,
  e numa turma de quatro o bloco não foi cancelado. O diálogo diz isso em uma linha, para a recepção
  não supor o contrário.
- **A corrida do teto.** Duas entradas concorrentes numa turma com uma vaga ainda podem passar as
  duas (a validação conta numa transação e o `manage_relationship` grava em outra). Continua aceito
  pela decisão de 2026-08-01 registrada em `Validations.GroupCapacity` — e agora o `BumpVersion` no
  add fecha o caso **sequencial**, que era o comum: dois recepcionistas trabalhando no mesmo bloco
  aberto, um depois do outro.
