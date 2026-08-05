# 103 — O profissional só lê a agenda

**Data:** 2026-08-04 · **Altera:** [ADR-016](00-decisoes.md#adr-016--papel-owner-obrigatório-e-perfis-com-capabilities-embarcadas)
(fronteira do papel `profissional`) · **Supersede em parte:** [doc 101 §4.1](101-plano-de-acao-analise-arquitetural.md) (a fronteira
entre transições e o resto da escrita do pacote)
· **Acumuladores:** [`00-decisoes.md`](00-decisoes.md), [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md)

Pedido do produto: *"o profissional não pode agendar, pode apenas visualizar a sua agenda e os
agendamentos"*.

A frase é curta e a mudança não é: `profissional` tinha escrita em **cinco** recursos, e três
delas chegavam à agenda por caminhos que a palavra "agendar" não cobre. Este documento registra o
alcance que foi medido, as quatro decisões que ele obrigou a tomar e o que ficou de fora.

---

## 1. O que existia

O papel escrevia em cinco lugares. A coluna "como isso vira agenda" é a que decidiu o recorte:

| Onde | O que podia | Como isso vira agenda |
| --- | --- | --- |
| `Appointment` (`@write_actions`) | lançar, remarcar, cancelar, reabrir, excluir, mexer na turma — sempre na **própria** coluna | direto |
| `Attendance` | marcar presença, falta, reabrir, justificar | fecha o desfecho do bloco; debita pacote e move `Patient.faltas` |
| `Package` (`create`/`update`) | criar a série, `+1`/`−1` da ficha | **o `Materializer` lança as sessões com `authorize?: false`** |
| `PackageSchedule` | trocar a grade da série | decide em que coluna e horário as sessões caem |
| `WaitlistEntry` | pôr, tirar e editar item da fila | a saída natural de um item é virar agendamento |

O A7 na escrita (`Appointment.Checks.OwnProfessionalColumn`) era o que mantinha o papel dentro da
própria coluna. Ele nasceu do achado (b) do [doc 26](26-auditoria-bate-volta-agenda.md):
ler-restrito e escrever-livre é a pior combinação, *porque o autor do estrago não vê o estrago*.

## 2. As quatro decisões

Cada uma tinha uma leitura defensável do pedido; nenhuma se deduzia das outras.

1. **Toda a escrita no agendamento, não só o "criar".** "Apenas visualizar" não convive com
   remarcar e cancelar. Se ficasse só o `schedule` de fora, o papel continuaria movendo o dia
   inteiro — só que sem poder abrir bloco novo.
2. **Presenças também viram leitura.** Foi a escolha menos óbvia, e a recomendação era a
   contrária: marcar presença é a operação clínica do dia a dia. A decisão foi que a agenda fica
   **inteiramente** somente-leitura para o papel; quem registra o desfecho é o balcão.
3. **Pacote e fila fecham junto.** Sem isso a proibição é contornável, e não por sutileza: o
   `Materializer` lança as sessões da série com `authorize?: false` — ele materializa o que a
   série já decidiu, não reautoriza bloco a bloco. **Fechar só a policy do `Appointment` deixaria
   o papel que não pode lançar UM bloco criando uma série de doze.**
4. **A leitura não se mexe em nada.** O recorte A7 de leitura (`Preparations.OwnAgendaOnly`)
   continua idêntico: própria agenda, próprias presenças, e fail-closed no "UUID mole".

## 3. O que mudou

**Policies** — em todas, a lista `[:owner, :admin, :recepcao, :profissional]` virou
`[:owner, :admin, :recepcao]`:

- [`appointment.ex`](../api/lib/api/scheduling/appointment.ex) (A8) · [`attendance.ex`](../api/lib/api/scheduling/attendance.ex)
  · [`package.ex`](../api/lib/api/packages/package.ex) · [`package_schedule.ex`](../api/lib/api/packages/package_schedule.ex)
  · [`waitlist_entry.ex`](../api/lib/api/waitlist/waitlist_entry.ex).

**Removido:** `Appointment.Checks.OwnProfessionalColumn` e a policy que o chamava. Ela só se
aplicava quando o actor era `profissional` — e o papel deixou de alcançar aquelas ações, então a
policy passou a ser inalcançável para **todo** actor. Policy que nunca é avaliada é policy que
mente sobre o que protege, e ainda diluiria a cobertura. O A7 que sobra é o de leitura.

**Mantido de propósito, mesmo redundante:** a A9 (encaixe) em `Appointment` e as transições de
ciclo de vida em `Package` ficaram com listas hoje idênticas às policies gerais dos seus recursos.
Não são a mesma decisão: a A8 responde "quem lança na agenda" e a A9 "quem pode furar a grade".
Se a primeira lista voltar a crescer, é a segunda que segue barrando o furo — apagá-la agora seria
confiar numa coincidência de listas.

**Matriz de acesso** ([`access_matrix.ex`](../api/lib/api/accounts/access_matrix.ex), a tela de
Configurações › Equipe): `agenda` segue `:propria` com o `obs` reescrito ("só VÊ"); `fila` e
`pacotes` caem de `:total` para `:leitura`. O vocabulário ganhou uma nota: **`:propria` diz qual
recorte de linhas, não se a pessoa altera** — os dois eixos sempre foram independentes (relatórios
já usava `:propria` para leitura-própria), e a mudança da agenda só tornou o caso visível.

**Web** (espelho de UX; a autoridade continua sendo o 403 da API):
[`canCreateAppointment`](../web/src/lib/agenda.ts) — e, por alias, `canMutateAppointment`, que
fecha o rodapé inteiro do drawer — e [`canManageWaitlist`](../web/src/lib/waitlist.ts). A criação
de pacote na ficha já era de owner/admin no web, então não teve o que mudar ali (ver §6).

## 4. O que os testes provam

Vermelho antes do conserto, como manda o [CLAUDE.md](../CLAUDE.md): os 7 primeiros testes de
`appointment_test.exs` falharam antes de qualquer policy ser tocada.

Cada bloco de recusa entrou com um **controle positivo** ao lado, e essa é a parte que não é
cerimônia: "tudo dá `Forbidden`" é indistinguível de "o recurso sumiu para o papel", e sumir é
justamente o modo de falha silencioso deste projeto (RLS devolvendo zero linhas, fila vazia lida
como "não há vaga"). Os controles afirmam que ele **continua lendo** a própria agenda, as próprias
presenças, a fila inteira e o pacote.

| Arquivo | O que passou a provar |
| --- | --- |
| `test/api/scheduling/appointment_test.exs` | não agenda (nem na própria coluna, nem sem encaixe), não remarca, não cancela, não exclui, não tira participante, não marca presença nem falta — **e lê** |
| `test/api/waitlist/waitlist_entry_test.exs` | não enfileira — **e lê a fila inteira**, inclusive o que o balcão pôs |
| `test/api/packages/lifecycle_test.exs` | o `+1` da ficha e a criação da série também recusam — **e lê o pacote** |
| `test/api/accounts/access_matrix_test.exs` | o tripwire da agenda voltou ao `escreve?/1` comum, e ganhou sonda para as **presenças** (a metade da célula "Agenda e presenças" que não tinha nenhuma) |
| `web/src/lib/agenda.test.ts`, `waitlist.test.ts`, `AppointmentDrawer.svelte.test.ts` | os predicados de UX e o botão "Agendar" da fila no drawer |

**Gates:** `mix test` 2.042 testes · `mix coveralls` 90,5% (piso 80) · `mix test --only rls` 0
falhas · `npm run coverage` 2.593 testes, 92,8% de statements, exit 0. A única falha vermelha do
backend é pré-existente e sem relação — ver §7.

## 5. Três testes que perderam o sujeito

Não foram "consertados até passar"; cada um provava uma invariante que continua valendo, com um
ator que deixou de existir. Registrar como foram reescritos importa mais que o diff:

- **`fanout_test` — supressão do autor.** Provava que quem faz a ação não recebe a própria
  notificação, usando o profissional agendando na própria coluna. Como o destinatário é resolvido
  por `Membership.professional_id` **sem olhar o papel**, o caso sobrevive em quem acumula as duas
  coisas: **a admin (ou a dona) que também atende** — o caso real da clínica pequena. O teste passou
  a usá-la, e ganhou o controle positivo que faltava (ela **recebe** quando quem agenda é outra
  pessoa; sem ele, o `refute` passaria também se o vínculo tivesse deixado de valer para papel que
  não é `:profissional`).
- **`lifecycle_test` — a âncora do `+1` (achado A3, doc 101).** A rota do bug fechou por
  construção: só o papel `profissional` tem leitura recortada, e nenhum ator que ainda alcança
  `add_session/2` é recortado. O teste ficou, com escopo de owner, guardando `proxima_ancora/2` em
  si — a âncora sai do pacote inteiro, não das sessões de uma coluna. É um teste mais fraco do que
  era, e o comentário dele diz isso.
- **`AppointmentDrawer.svelte.test.ts` — o botão da fila.** Antes o profissional via o botão
  "Agendar" **desabilitado** (a vaga de falta só entra como encaixe, e encaixe nunca foi dele).
  Agora o botão não é desenhado — e o teste afirma, na mesma linha, que a **lista de candidatos
  continua visível**: o que saiu foi a caneta, não a leitura.

## 6. O que ficou de fora, e por quê

- **Comunicação com o paciente** (`comunicacao`, `:propria`) não foi tocada: o pedido é sobre
  agendar, e a matriz sempre tratou comunicação como célula própria. O `messages_controller`
  continua aceitando o papel — só o moduledoc mudou, porque descrevia a lista como *"os mesmos
  papéis que agendam"* e essa frase ficou falsa. **Se a comunicação for reavaliada, que seja por
  decisão, não por arrasto desta.**
- **Divergência pré-existente, não introduzida aqui:** no web, `canManagePatients` (e portanto a
  criação de pacote na ficha) é owner/admin, enquanto a policy do `Patient` aceita `recepcao`. A
  tela é mais restritiva que a API. Não foi mexido — não é desta mudança —, mas fica registrado.
- **Nada de migration.** A mudança é inteiramente de policy; nenhum dado muda de forma.

## 7. Segunda parte — a tela de Profissionais fecha junto

Pedido seguinte, no mesmo dia: *"remova também o acesso a tudo que tem na página de
profissionais, ele não pode ver a listagem e nem mexer nos próprios dados"*.

**Metade já era verdade:** escrever no diretório sempre foi de owner/admin. O que ele tinha era
**leitura** — uma listagem de **uma linha só** (ele mesmo, recortada pela preparation
`OwnProfessionalOnly`) e a própria ficha **completa**, com CPF, RG, endereço, contato de
emergência, razão social, CNPJ, banco, agência, conta e PIX.

### O que quase deu errado

A saída óbvia — fechar `policy action_type(:read)` do `Professional` para o papel — **derrubaria
a agenda dele com 500**, desfazendo em uma linha o que a §2 decidiu. O motivo:
[`Api.Scheduling.load_agenda/4`](../api/lib/api/scheduling.ex) chama
`list_professionals!(scope: scope)` por dentro para montar a coluna, e a policy de leitura é
`SimpleCheck` — ela **nega**, não filtra. Não é a RLS devolvendo vazio: é `Ash.Error.Forbidden`
subindo pela função `!`.

Foi medido antes de escrever qualquer coisa, e é o que decidiu a forma.

### A forma: fechar a superfície, não o recurso

Duas guardas, em camadas diferentes, cada uma com o que só ela consegue fazer:

| Camada | O quê | Por quê ali |
| --- | --- | --- |
| `ProfessionalsController` (`index`, `show`) | `with_roles_scope(@papeis_do_diretorio)` → **403** | É a superfície da TELA. `load_agenda` não passa por este controller, então a agenda sobrevive. |
| `field_policy @ficha_contratual` | a cláusula do papel saiu | Field policy **não derruba a leitura** — devolve `%Ash.ForbiddenField{}` no lugar do valor. O dado sensível para de viajar mesmo por um caminho que ninguém previu. |

A policy de leitura do recurso **fica aberta ao papel, de propósito**, e há um teste dedicado
dizendo isso em voz alta (`a leitura do recurso continua de pé — é dela que a agenda dele se
monta`) para que ninguém "termine o serviço" fechando-a e derrubando a agenda junto.

### Matriz: a linha teve de ser dividida

`profissionais` era **"Profissionais e tipos de atendimento"**, `:leitura` para o papel nas duas
coisas. Só a primeira fechou — os tipos ficam porque a agenda depende deles (sem o tipo não há
cor, nome nem duração no bloco que ele lê). Uma célula não expressa dois valores, então virou
`profissionais` (`:nao`) + `tipos` (`:leitura`), com sonda própria no tripwire.

### Web

O rail escondia destino restrito por um booleano `ownerAdmin`, e este recorte **não é aquele** —
a recepção continua entrando em Profissionais. Em vez de um segundo booleano (e de um `filter`
que dependeria de lembrar qual flag exclui quem), o campo virou
`restrito?: 'owner-admin' | 'sem-profissional'`, com a tradução para predicado no `Rail`, onde os
`can*` já moram.

As três rotas da seção fecharam, e a de cadastro por um caminho diferente das outras duas: o
`load` de `/profissionais/novo` **não toca** `/api/professionals` (só o expediente da clínica),
então não havia 403 da API para herdar — ali a guarda é explícita, com o papel vindo do layout.
Nas outras duas o 403 da API vira página de erro, como já faz a Auditoria; o que mudou é a
**mensagem**: "não foi possível carregar" leria como falha de rede e mandaria tentar de novo uma
tela que, para ele, não existe.

### O que continua funcionando (e tem teste provando)

- **A agenda dele** resolve a própria coluna — `GET /api/appointments` devolve o `Professional`
  dele, com nome e cor. É o controle positivo do 403, no mesmo arquivo de teste.
- **A ficha do paciente e a lista de pacientes** degradam para lista vazia de profissionais em
  vez de quebrar, pelo mesmo padrão que os anexos já usavam (`fetchProfessionals` → `?? []`). O
  efeito visível é o rótulo do profissional sumir de alguns lugares da ficha — para ele, que só
  vê as próprias sessões, é o próprio nome.
- **Horário, exceções e relatórios** não passam por este endpoint e não foram afetados.

**Gates da segunda parte:** `mix test` 2.048 testes · `mix coveralls` 90,5% · `--only rls` 0
falhas · `npm run coverage` 2.635 testes, exit 0 · `npm run check` **0 erros** (os 6 pré-existentes
de `confirmar/[token]` sumiram — foram resolvidos pela outra frente na mesma working tree).

## 8. Pendências

- **`cinetra-prod-age.key` na raiz do repositório.** O teste `segredo_no_working_tree_test.exs`
  falha por isso, e falhava **antes** desta mudança (verificado). Não é regressão nossa e não foi
  tocado: mover ou apagar chave privada é decisão de quem a gerou. Se for a chave `age` de
  produção, ela decifra todo backup — o próprio teste explica o que fazer.
- ~~6 erros de `svelte-check` em `web/src/routes/confirmar/[token]/page.server.test.ts`~~ —
  pré-existentes e de outra frente na mesma working tree; **resolvidos por ela** durante este
  trabalho (`npm run check` fechou em 0 erros).
