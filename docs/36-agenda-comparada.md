# 36 — A agenda comparada: nosso modelo vs. Google Agenda (e os outros)

Análise do modelo de dados de `Api.Scheduling` contra o modelo canônico de calendário
(iCalendar/RFC 5545, que é o que o Google Agenda implementa) e contra os sistemas de
**agendamento** (Cal.com, Calendly, os schedulers de EHR tipo Epic Cadence). Escrita a pedido de
*"fomos por um caminho interessante?"*.

Complementa [`25-agenda.md`](25-agenda.md) (o desenho) e [`30`](30-decisoes-pendentes-agenda.md)
(o que ficou em aberto). Não propõe fatia nova; termina em **cinco achados acionáveis** (§7).

---

## 1. O veredito, antes do detalhe

**Sim, o caminho é bom — e a razão é que não copiamos um calendário.** A escolha estrutural
correta foi enxergar que estamos construindo um **alocador de recurso escasso**, não um
**registro de intenção**. Google Agenda é a segunda coisa; a agenda de uma clínica é a primeira.
Quase toda divergência boa do nosso modelo desce dessa distinção, e quase todo risco vem de onde
copiamos o calendário mesmo assim.

Concretamente:

| | Google Agenda | Nós | Quem está certo |
| --- | --- | --- | --- |
| Duas coisas no mesmo horário | permitido, normal | **proibido pelo banco** | nós — fisioterapeuta não se bilocaliza |
| Recorrência | `RRULE`, expandida na leitura | linhas materializadas (Fatia 3) | nós, para este domínio |
| Participante | `attendees[].responseStatus` (RSVP) | `Attendance` com **desfecho** | nós |
| Disponibilidade | quase inexistente | motor de 4 camadas | nós |
| Tempo | relógio de parede + `tzid` | instante UTC | **eles** — e isso nos custa (§4.1) |
| Interoperar | é o padrão do mundo | nada | eles — e vai doer (§6.3) |

O ponto mais forte do modelo é a **exclusion constraint**. O ponto mais frágil é a
**representação do tempo**. Os dois são a mesma decisão: escolhemos UTC porque `tsrange` exigia
instante absoluto — a garantia mais forte que temos foi comprada com a representação de tempo
mais frágil.

---

## 2. Nosso modelo em uma página

```
Clinic (timezone, slot_minutos, cap_turma_padrao)
  └─ ClinicHours        (dow 0..6 → periods [["08:00","12:00"], …])   [] = fechado
  └─ ScheduleException  (data, tipo: fechado|horario, periods, professional_id?)   ← polimórfico
  └─ Professional
       └─ ProfessionalHours (dow → modo: herda|custom|fechado + periods)
  └─ Appointment  ── has_many ──▶ Attendance (patient_id, status, falta_justificada, package_id)
       starts_at/ends_at :utc_datetime · status · encaixe · obs · version · package_id · pkg_hold
       EXCLUDE USING gist (professional_id =, tsrange(starts_at, ends_at, '[)') &&)
         WHERE encaixe = false AND status <> 'cancelado'
  └─ SlotHold     (reserva com TTL, exclusion constraint irmã)
  └─ WaitlistEntry ── has_many ──▶ AvailabilityRule (semana|data)
```

Motores puros ao lado: `Periods` (forma/ordem/disjunção), `Availability` (precedência de 4
camadas), `LocalTime` (a ponte UTC ↔ minuto-do-dia, o **único** lugar que conhece o fuso).

---

## 3. O modelo do Google, em uma página

O Google Agenda é uma implementação do iCalendar. O `Event` tem:

- `start`/`end` como **`date`** (dia inteiro) ou **`dateTime` + `timeZone`** — o fuso viaja
  *junto do evento*, não do calendário;
- `recurrence: ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"]`, `RDATE`, `EXDATE` — **uma linha**, instâncias
  expandidas na leitura; instância alterada vira linha separada com `recurringEventId` +
  `originalStartTime`;
- `attendees[]` com `responseStatus` ∈ {needsAction, declined, tentative, accepted};
- `status` ∈ {confirmed, tentative, cancelled} — só três, e nenhum é "faltou";
- `transparency` (opaque/transparent = ocupa ou não o free/busy), `visibility`;
- `sequence` + `etag` para concorrência (`If-Match`), `iCalUID` para identidade entre sistemas;
- `syncToken` para sincronização incremental, webhooks para push.

E, de forma decisiva: **nenhuma restrição de sobreposição**. O Google agenda duas coisas no mesmo
horário sem reclamar. Conflito é *consultável* (FreeBusy API), nunca *impedido*. Salas são
"resource calendars" — outro calendário, com a mesma ausência de garantia.

---

## 4. As sete divergências que importam

### 4.1 Tempo — instante absoluto (nós) vs. relógio de parede + `tzid` (eles) 🔴

Guardamos `:utc_datetime` (`timestamp(0) without time zone` no Postgres) e um `Clinic.timezone`
único. O Google guarda `2026-08-03T09:00:00` **mais** `America/Sao_Paulo`.

A diferença só aparece quando as regras de fuso mudam:

> Um paciente marcado para 3 de agosto às 09:00 vira `12:00Z` no banco. Se o Brasil reinstituir o
> horário de verão antes dessa data — decisão política, não técnica —, `12:00Z` passa a ser
> **10:00** na parede. O agendamento anda uma hora sozinho. No modelo do Google, `09:00` +
> `America/Sao_Paulo` é reinterpretado pela `tzdb` atualizada e continua às 09:00.

O `LocalTime` já trata as duas transições de DST (`:gap` → empurra, `:ambiguous` → primeira
ocorrência) e o moduledoc até explica por que testar com `America/Santiago`. Mas isso protege a
**escrita**; não protege dados **já escritos** de uma mudança futura na `tzdb`.

Por que escolhemos assim: a exclusion constraint precisa de `tsrange`, e `tsrange` precisa de
instante absoluto. Foi uma troca consciente e registrada (A2, `12:158`). A avaliação honesta é que
**a troca vale a pena** — o risco é baixo (Brasil sem DST desde 2019; a clínica é de um fuso só) e
a garantia comprada é alta. Mas é uma dívida real, e o custo de fechá-la é baixo hoje e alto
depois: uma coluna redundante `starts_at_local` (data + minuto) ou um `tzid` por agendamento
transformaria "reinterpretar tudo" num `UPDATE`, em vez de num incidente.

Ver **achado A1**.

### 4.2 Recorrência — `RRULE` (eles) vs. linhas materializadas (nós) ✅

Não temos recorrência, e não vamos ter: a série de pacote (Fatia 3) **materializa N linhas**.
Isso é certo, por três razões independentes:

1. **A constraint não alcança um `RRULE`.** Não existe exclusion constraint sobre uma regra não
   expandida. Nossa garantia central depende de as linhas existirem. Adotar `RRULE` seria abrir
   mão da §4.3 — a decisão é acoplada, não uma preferência.
2. **A regra do negócio não é expressável em `RRULE`.** RN-19: feriado **pula e estende** a série
   (uma série de 10 sessões vira 11 semanas de calendário). Não há `RRULE` que diga isso;
   `EXDATE` remove a ocorrência, não a reagenda no fim.
3. **Cada sessão tem estado próprio.** Presença, falta justificada, consumo de pacote. Instância
   expandida de `RRULE` não tem onde guardar isso sem virar linha — que é onde já começamos.

Custo que estamos pagando de propósito: não existe "editar todas as ocorrências futuras" barato
(vai ser um lote), o volume cresce linear, e a identidade da série vive num `package_id` sem FK.
Para o volume medido (~10k linhas) isso é irrelevante.

**Isto é o oposto do que a maioria copia**, e é onde mais economizamos bug. `RRULE` é fonte
clássica de defeito: expansão infinita, `EXDATE` órfão, split de "este e os seguintes", DST no
meio da regra.

### 4.3 Sobreposição — constraint (nós) vs. conselho (eles) ✅ com ressalvas

```sql
EXCLUDE USING gist (professional_id WITH =, tsrange(starts_at, ends_at, '[)') WITH &&)
  WHERE (encaixe = false AND status <> 'cancelado')
```

Isto é mais forte do que a maioria dos sistemas **comerciais** de agendamento faz. O padrão do
mercado é `SELECT … WHERE overlaps` seguido de `INSERT` — que tem janela TOCTOU e falha exatamente
no cenário que importa: dois recepcionistas no mesmo slot. Nós temos a garantia no lugar onde
corrida se resolve. O `'[)'` embutindo "encostar não é conflito" e o predicado parcial embutindo
RN-12/RN-13 **no próprio índice** é elegante: a regra de negócio virou DDL, não código que alguém
pode esquecer de chamar.

Três ressalvas honestas:

- **A garantia é desligável por um booleano.** `encaixe = true` isenta a linha nos dois sentidos.
  Quem pode marcar `encaixe` é decidido por *policy* (A9) — e essa policy **não existia** na
  primeira passada; o bate-volta ([26 §3](26-auditoria-bate-volta-agenda.md)) achou um
  `profissional` desligando a proteção contra dupla-marcação mandando um campo no corpo. O
  invariante mais forte do sistema depende do elo mais frágil (autorização em aplicação). Não há
  conserto óbvio — encaixe é requisito de negócio —, mas merece um teste de regressão explícito
  tratado como teste de **segurança**, não de feature.
- **O paciente não está protegido.** A constraint chaveia `professional_id`. Nada impede o mesmo
  paciente em dois blocos sobrepostos com profissionais diferentes; A-D5 só **avisa**. O Google
  tem o mesmo comportamento e para ele está certo (uma pessoa pode ter dois compromissos). Para
  paciente presencial, "avisar" é uma escolha defensável — mas é escolha, e vale registrá-la como
  tal em vez de deixá-la implícita na ausência de constraint.
- **A constraint é global (sem `clinic_id`), por ADR-017.** Correto para um profissional que
  atende em duas clínicas — ele não se bilocaliza entre tenants. O efeito colateral já foi pago no
  bate-volta E5: uma referência cross-tenant vira vetor, e a defesa é validação em aplicação
  (`ProfessionalInClinic`) em **todo** caminho de escrita que aponte para um profissional. Isso é
  sistêmico, não pontual.

E o que **ainda não é** escasso: sala, equipamento (GAP-15, fora do v1). A forma atual amarra a
constraint à coluna `professional_id`. Quando sala entrar, ou se cria uma segunda exclusion
constraint (fácil, N recursos = N constraints) ou se generaliza para `resource_bookings(resource_id,
tsrange)` com uma constraint só e o agendamento apontando N recursos — que é o que os schedulers de
EHR fazem. A segunda é mais correta e bem mais cara. Não decidir agora está certo; saber que a
escolha existe, também.

### 4.4 Participante — `Attendance` (nós) vs. `attendees[]` (eles) ✅

O `responseStatus` do Google é **intenção** (você vem?). Nossa `Attendance` é **desfecho** (você
veio?) — `prevista`/`concluida`/`faltou`/`cancelada` + `falta_justificada` + `package_id` por
participante. São coisas diferentes, e a que fatura é a nossa.

O detalhe que mais me convence é a divergência permitida: o bloco pode estar `:concluido` com um
participante `:faltou`. Modelo de calendário não representa isso — e sem representar não há
política de falta, não há consumo de pacote por paciente, não há relatório de taxa de falta.
`package_id` no participante e não no bloco (D11, "não existe pacote de turma") é a mesma lucidez.

O que **não** temos e eles têm: o laço de RSVP (o paciente confirmar). F7 registra que
`confirmado`/`em_atendimento` hoje só nascem de seed. É lacuna de produto, não de modelo — as
colunas já existem.

### 4.5 Disponibilidade — motor de 4 camadas (nós) vs. quase nada (eles) ✅

O Google historicamente **não tem** modelo de disponibilidade; "horário de trabalho" é dica visual.
Appointment Schedules chegou depois e é fino: janela semanal + buffer + horizonte.

Nosso `Availability` é comparável ao "schedules + date overrides" do Cal.com e aos templates de
provider do Epic — com uma vantagem: as **duas assimetrias load-bearing estão escritas e
justificadas** (feriado da clínica vence o horário especial do profissional; folga do profissional
vence o horário especial da clínica). A maioria dos sistemas deixa essa precedência indefinida e a
descobre em produção. Do mesmo modo, `:fechado` ≠ linha ausente (RN-10) resolve explicitamente o
tri-estado que normalmente vira um `NULL` ambíguo.

Onde somos **mais finos** que Cal.com/Calendly, e vai aparecer como pedido de produto:

- sem **buffer** antes/depois (limpeza de maca, troca de sala);
- sem **antecedência mínima** ("não aceitar agendamento para daqui a 5 minutos");
- sem **horizonte** ("não deixar marcar além de 90 dias");
- sem disponibilidade **por tipo** ("avaliação só nas terças");
- sem sala/equipamento (§4.3).

Nenhum desses quebra o modelo — todos entram como camada adicional no motor puro, que é
exatamente o lugar barato. Isso é evidência de que a arquitetura está certa: as extensões óbvias
são aditivas.

### 4.6 Ações nomeadas (nós) vs. `PATCH` no evento (eles) ✅

`:reschedule`, `:mark_completed`, `:mark_missed`, `:cancel`, `:reopen`,
`:set_falta_justificada` — a **intenção** é o que a trilha grava (`store_action_name?`) e o que o
cliente casa no evento de tempo real. No Google você faz `PATCH` e ninguém consegue distinguir
"remarcou" de "corrigiu um typo no horário".

Para um domínio clínico/auditável isso é claramente superior, e combina com o paper trail
`:changes_only`. Custos: superfície de API maior, e cada estado novo custa ação + policy + teste.

Uma observação de forma: as transições permitidas estão espalhadas em
`Validations.StatusIn, from: [...]` dentro de cada ação. Funciona, e o bate-volta F4 provou que é
preciso. Mas **não existe um lugar onde a máquina de estados esteja declarada** — para saber se
`cancelado → concluido` é possível, é preciso ler as seis ações. `ash_state_machine` (extensão
oficial do Ash, não está nas deps) declara `transitions` numa tabela só e gera a validação. É
refatoração barata de legibilidade, não conserto de bug. Ver **achado A4**.

### 4.7 Concorrência — `version` + `SlotHold` (nós) vs. `etag`/`sequence` (eles) ✅

Locking otimista com `version` inteiro e guarda de 409 no wrapper é o mesmo mecanismo do
`sequence`/`If-Match` do Google, só que no domínio em vez do HTTP. Equivalente. A diferença
prática: um cliente nosso não consegue mandar `If-Match` e receber `412` — precisa conhecer o
campo. Irrelevante enquanto o único cliente é nosso BFF.

O `SlotHold` com TTL + exclusion constraint irmã é **mais forte que qualquer coisa que o Google
tenha**, e é a resposta certa para a corrida oferecer→confirmar (GAP-16). A purga dos vencidos na
DML (porque `now()` é `STABLE` e não entra em índice) é a solução correta e não-óbvia. Bom
trabalho aqui.

---

## 5. Onde estamos claramente melhores

1. **Garantia no banco, não em conselho** (§4.3) — mais forte que a maioria dos SaaS de
   agendamento, que ainda fazem check-then-insert.
2. **Desfecho por participante** (§4.4) — habilita falta, pacote e relatório; calendário nenhum
   modela.
3. **Precedência de disponibilidade explícita e justificada** (§4.5).
4. **Intenção preservada** por ações nomeadas + trilha (§4.6).
5. **Isolamento multi-tenant real** (atributo + RLS + policies) — o análogo do Google é ACL de
   calendário, incomparavelmente mais fraco.
6. **Motores puros** (`Periods`, `Availability`, `LocalTime`) sem banco e sem escopo: testáveis
   sozinhos, e é o que torna as extensões da §4.5 baratas.
7. **Não ter recorrência** (§4.2) — a economia de bug menos visível e provavelmente a maior.

---

## 6. Onde estamos piores, ou onde vai doer

### 6.1 A representação do tempo é a dívida real (§4.1)
Baixa probabilidade, alto custo, e o custo de mitigar cresce com o número de linhas. Achado A1 —
**recusado em 2026-07-24**, ver §7.1.

### 6.2 A varredura de `:in_range` não tem limite inferior — e a premissa que travou o conserto está errada 🔧

O filtro é `starts_at < ^to and ends_at > ^from`, e os índices são
`(clinic_id, professional_id, starts_at)` e `(clinic_id, starts_at)`. Um btree ascendente atende
`starts_at < to` varrendo **tudo que veio antes de `to`** — isto é, o histórico inteiro — e
descartando pelo residual `ends_at > from`. Não morde hoje (10k linhas); morde quando a clínica
tiver três anos de agenda.

O conserto conhecido é limitar por baixo: `starts_at > from − duração_máxima`. O
[doc 30 (P5)](30-decisoes-pendentes-agenda.md) fechou esse caminho decidindo que *"não há teto — a
duração vem dos tipos de atendimento (que também não têm máximo)"*, e concluiu que só sobrava o
índice GiST não-parcial.

**A premissa está factualmente errada.** Os dois lugares que definem duração já têm teto de
8 horas:

- [`appointment_type.ex:135`](../api/lib/api/directory/appointment_type.ex#L135) —
  `duracao_minutos … constraints: [min: 5, max: 480]`
- [`appointment.ex:459`](../api/lib/api/scheduling/appointment.ex#L459) —
  `duration_minutos … constraints: [min: 5, max: 480]`

Com um teto provado, `starts_at > from − 8h` é válido e o btree existente resolve, sem GiST novo.
A ressalva é a mesma lição do `CHECK` de duração positiva (commit `3a2f27c`): 480 é invariante de
**aplicação**, e o `:in_range` passaria a *depender* dele — uma linha escrita por fora da ação
(`Ash.Seed`, `INSERT` de manutenção) com 10 horas ficaria **invisível** na leitura, sem erro
nenhum. Então o conserto correto é o par: `CHECK (ends_at <= starts_at + interval '8 hours')` **e
depois** o limite inferior na query. Achado A2.

### 6.3 Zero interoperabilidade 🔴

Não existe `.ics`, feed, CalDAV nem export. O profissional não consegue ver a agenda no celular
sem abrir nosso app. Isso é o serviço que o Google presta e que ninguém mais precisa prestar — um
feed ICS somente-leitura por profissional é barato e de alto valor percebido.

Com uma ressalva séria de LGPD que precisa ser desenhada junto: **URL de feed ICS é credencial
portadora** (quem tem o link lê tudo, para sempre) e o título do evento carrega nome de paciente.
Se for feito, tem que ser token revogável por profissional e conteúdo mínimo — ou, melhor, só
inicial/código no `SUMMARY`. Não é "expor uma rota". Achado A3.

### 6.4 O que um calendário maduro tem e nós não
Sem ordem de prioridade, para não parecer esquecido: evento de dia inteiro (não precisamos —
feriado é `ScheduleException`, e isso é **mais** limpo), lembrete/notificação ao participante,
anexos, sincronização incremental por `syncToken` (temos WebSocket, que resolve o caso ao vivo mas
não o "estive offline 2 dias"), e o par `visibility`/`transparency`.

---

## 7. Achados acionáveis

| # | Achado | Tipo | Custo | Urgência |
| --- | --- | --- | --- | --- |
| ~~**A1**~~ | ~~**Guardar o relógio de parede junto do instante.**~~ **RECUSADO (2026-07-24)** — ver a decisão abaixo. Se a regra de fuso mudar, o conserto é uma migração global de uma vez, não uma coluna carregada para sempre. | 🔧 dívida | — | **aceito com risco** |
| **A2** | ✅ **FEITO (2026-07-24).** `CHECK (ends_at <= starts_at + interval '480 minutes')` + corte `starts_at > from − 8h` no `:in_range`, com a constante em fonte única (`Api.Scheduling.Duration`). Fechou o D-A **sem** GiST: Seq Scan (10.099 descartadas, 1,41 ms) → Index Scan (0,11 ms), mesma resposta. Detalhe em [`35`](35-plano-execucao-backlog.md#d-a-fechado-pelo-teto-não-pelo-índice) | 🔧 dívida | baixo | — |
| **A3** | **Feed ICS somente-leitura por profissional**, com token revogável e `SUMMARY` mínimo (LGPD). O único ponto onde o Google presta um serviço que vamos ter que prestar. | 🟡 fatia | médio | pós-v1 |
| **A4** | **Declarar a máquina de estados** (`ash_state_machine`) em vez de espalhar `StatusIn, from:` por seis ações. Legibilidade; não é bug. | 🔧 refactor | baixo | oportunista |
| **A5** | **Registrar como decisão** que a dupla-marcação do **paciente** é avisada e não impedida (§4.3), em vez de deixá-la implícita na ausência de constraint. E tratar o teste de `encaixe` da A9 como teste de segurança, com regressão explícita. | 📋 registro | trivial | agora |

### 7.1 A1 — recusado (2026-07-24)

**Decisão:** o modelo de tempo fica como está — instante UTC + `Clinic.timezone`, sem coluna
redundante de relógio de parede e sem `tzid` por linha.

**Razão:** o cenário (a tzdb mudar debaixo de agendamento já gravado) é de baixa probabilidade, e
quando acontecer o conserto é uma **migração global feita de uma vez** — reconverter as linhas
afetadas com a regra antiga fixada — em vez de uma segunda fonte de verdade que toda escrita de
horário precisa manter em sincronia para sempre. Trocar um evento raro e datado por um invariante
permanente não paga.

**O que isso implica aceitar, conscientemente:**

- se a regra de fuso mudar, os agendamentos **futuros já gravados** andam na parede até a migração
  rodar, e a trilha de auditoria não registra esse deslocamento (ninguém escreveu nada);
- a migração vai precisar da regra vigente **na escrita** — na prática, fixar a versão antiga da
  `tzdata` para reconverter. É trabalho conhecido, mas feito sob pressão;
- o ganho lateral que a coluna traria (data local indexável, útil ao D-A/A2 e ao `GROUP BY` de
  relatório) some junto. Se ele voltar a ser desejado, é por **motivo de performance medida**, não
  por causa do fuso — e aí é outra decisão.

## 8. Fechamento

O modelo não é um calendário com campos a mais — é um alocador de recurso escasso que empresta do
calendário só o que serve. As decisões que mais vão pagar são as três que **divergem** do Google:
constraint em vez de conselho, desfecho em vez de RSVP, linhas materializadas em vez de `RRULE`. As
duas que mais vão cobrar são as duas em que **seguimos** um modelo mais simples do que o do Google:
o tempo em UTC puro (§4.1) e a ausência total de interoperação (§6.3).

Nenhuma delas é erro. As duas são dívidas nomeáveis, com conserto conhecido e barato hoje — que é
a melhor situação em que uma dívida pode estar.
