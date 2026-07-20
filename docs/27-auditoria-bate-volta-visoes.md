# 27 — Auditoria bate-volta: as visões da agenda (Entrega 2)

Auditoria da **Entrega 2** da fatia agenda (Semana, Mês, Lista e `GET /api/appointments/counts`),
contra o diff não-commitado sobre `0a07f4c` e a **stack rodando**: `psql` como `movimento_app`
(NOBYPASSRLS), telemetria de query no `mix run`, `mix test`, e o navegador em `localhost:5173`.

Três caças por checklist em paralelo (segurança, performance, refatoração) e uma caça
adversarial pelos fluxos reais. **Parou na rodada 5**, com a fila de conserto fechada.

| Rodada | O que fez | Resultado |
| --- | --- | --- |
| 1 | Checklist, os três eixos | Segurança **0**; performance **5**; refatoração **6** |
| 2 | Adversarial, no navegador | **1 achado, com três sintomas** — nenhuma checklist o pegaria |
| 3 | Conserto, por causa-raiz | 5 causas consertadas |
| 5 | Re-sonda + auditoria do diff dos consertos | Sem regressão; 4 itens para decisão humana |

## 1. A varredura

**Segurança — zero achados**, 22 itens (10 REFUTADO, 12 NÃO SE APLICA). O que mais importava
provar era o recorte A7 num endpoint de **agregação**: um número vaza tão bem quanto uma linha.
Provado por telemetria, fora do `mix test` (que roda como `postgres`, BYPASSRLS): o predicado é
aplicado **pelo banco**, não em memória — o agendamento do colega não chega a ser lido.

```
### SQL (scope=profissional):
... WHERE (a0."pkg_hold" = $1) AND (a0."professional_id" = $2) AND (a0."starts_at" < $3) ...
### SQL (scope=owner):
... WHERE (a0."starts_at" < $1) AND (a0."ends_at" > $2) AND (a0."pkg_hold" = $3) ...
```

O `professional_id` existe só sob o escopo `profissional` e some sob `owner` — é a
`OwnAgendaOnly` valendo através da code interface. A RLS segura sozinha em seguida: como
`movimento_app`, com a GUC da clínica B, a leitura das cinco tabelas da agregação devolve
**0 linhas** da clínica A.

**Performance — 5 achados**, com a medição que interessava: **16 queries, invariantes** em dias,
profissionais e volume (1 dia × 1 prof = 31 dias × 10 profs × 1.770 agendamentos = 16). Sem N+1,
e o `load: [:attendances]` corretamente ausente.

**Refatoração — 6 achados**, todos de segunda-fonte-da-verdade, nenhum de estilo.

## 2. O que a rodada 2 achou e as checklists não

Uma causa, **três sintomas**, cada um uma frase falsa diferente. Com todos os profissionais
ocultos na barra lateral:

| Visão | Dizia | Por que é falso |
| --- | --- | --- |
| Semana | "Sem expediente" nos 7 dias | a clínica abre seg–sáb; quem sumiu foram os profissionais |
| Mês | células vazias | idêntico a um dia genuinamente sem agendamento |
| Lista | "Nenhum agendamento neste dia" | havia 2 agendamentos, apenas filtrados |

A visão Dia tem esse estado desde a Entrega 1 — `EyeOff` + *"Nenhum profissional em exibição"* +
**"Mostrar todos"** — e o [doc 25 §6](25-agenda.md) o descreve como *"fácil de esquecer, porque
só aparece por ação do usuário"*. Foi esquecido nas três visões novas.

> **A parte desconfortável:** os testes que eu mesmo escrevi **codificavam o defeito**. O caso
> "profissional oculto sai do numerador e do denominador" do `WeekView` usava uma fixture de
> **um** profissional — então ocultá-lo era "todos ocultos", e a asserção era `"Sem expediente"`.
> O teste passava verde afirmando exatamente a frase errada. Nenhuma quantidade de checklist
> pega isso; só rodar a tela pega. É a mesma lição que a [§8.1 do doc 26](26-auditoria-bate-volta-agenda.md)
> já tinha registrado por outro caminho.

## 3. As causas-raiz

Onze achados, cinco causas.

| Causa | Achados que ela explica |
| --- | --- |
| 1 · O estado "todos ocultos" não existe fora da visão Dia | os 3 sintomas da rodada 2 |
| 2 · A leitura carrega o que não usa | P-2 |
| 3 · Fronteira temporal com duas fontes | A (janela UTC), B (janela do mês) |
| 4 · Andaime de teste divergente e teto ausente | D (3 fábricas), P-5 |
| 5 · Contrato do wire e rótulos com dois donos | C (rótulo da seta), E (wire), F (comentário) |

## 4. O que foi corrigido

### Causa 1 — o estado vazio das três visões

`AgendaEmptyState.svelte` extraído do `DayGrid` (que passou a usá-lo, com os 20 testes dele
intactos — a refatoração é comportamentalmente idêntica por construção) e ligado nas três visões
novas, cada uma com o predicado testado. Os testes que codificavam o defeito foram reescritos: o
de recorte parcial agora usa **dois** profissionais e afirma que sobra a conta do que ficou; o
caso de todos ocultos ganhou teste próprio, afirmando a ausência da frase falsa.

Re-sonda no navegador, nas três visões: o estado honesto com saída aparece, e o caminho normal
não regrediu — domingo continua dizendo "Sem expediente", porque ali **é** verdade.

### Causa 2 — `SELECT` de 17 colunas para usar 4 (P-2)

Medido: **3,2 MB de heap** por request de Mês numa clínica cheia (10 profissionais × 31 dias)
para produzir 310 células de contagem, trazendo inclusive `obs`, que é texto livre. Um
`select` de quatro campos na leitura. Re-sonda por telemetria:

```
### SQL: SELECT a0."id", a0."status", a0."professional_id", a0."starts_at", a0."ends_at" FROM "appointments" ...
```

**5 colunas**, `obs` fora — e o predicado do A7 intacto, reconferido sob escopo `profissional`.

### Causa 3 — a mesma janela escrita duas vezes

`LocalTime.window!/3` passou a ser a única definição de *"a janela UTC de `[from, to]` locais é
semi-aberta"*; antes o `Date.add(to, 1)` e a política de 00:00 local estavam no controller **e**
no domínio. Duas fontes sobre **quais blocos pertencem ao dia**: mudar a convenção num lado faria
a Semana discordar do Dia por um agendamento de borda, com sintoma mudo. No web, `monthWindow/1`
mudou-se para `agenda-views.ts`, ao lado de `monthGrid` — a Semana já delegava a `weekDays`, só o
Mês reimplementava a aritmética fora do módulo que se declara a casa das grades.

### Causa 4 — o andaime de teste

Três fábricas `dia()` com o mesmo nome, o mesmo papel e três contratos incompatíveis (uma por
objeto parcial, uma posicional, uma sem overrides). Unificadas em `dayCountFixture` /
`professionalCountFixture` / `agendaProfessionalFixture`, em `lib/testing/fixtures.ts` — que já
existia para isso e ninguém usou.

E o teto de query de `/counts`, que **não existia** (o do doc 26 §7 cobre só `/availability`):
o teste afirma que 31 dias custam o mesmo que 1 dia, e menos de 30 queries. Nasceu verde de
propósito — é guarda de regressão sobre uma propriedade medida, não conserto de bug. Se alguém
trocar o agrupamento em memória por um laço por dia, o resultado na tela é idêntico e só ele
acusa.

### Causa 5 — os três menores

**(C)** O botão "anterior" reconstruía o mapa `PASSO` por ternário aninhado sobre o valor do
próprio mapa, que o "próximo" lia direto. Uma quinta visão em `VIEWS` deixaria o "próximo" certo
e o "anterior" caindo calado em *"Dia anterior"* — com o `Record<AgendaView, …>` satisfeito e o
TypeScript quieto. Hoje as duas formas saem do mesmo registro, com teste nas quatro visões.

**(E)** As linhas de contagem passavam do domínio direto para o JSON, deixando metade do contrato
HTTP morando em `Api.Scheduling`. `render_professional_count/1` devolve a nomeação do wire à
fronteira, como `render_professional/1` e `render_type/1`.

**(F)** Um comentário em `agenda.ts` prometia que a continuação de um bloco que atravessa a
meia-noite *"aparece no dia seguinte quando a Entrega 2 trouxer as outras visões"*. A Entrega 2 é
este diff, as visões chegaram, e a continuação **não** existe: a Semana e o Mês creditam a duração
inteira ao dia do `starts_at`, e a Lista mostra só os blocos do dia buscado. O comentário agora
diz que é caso não resolvido, não caso adiado para uma entrega nomeada.

### Estado ao fim

Backend **539 testes / 90,3%** · Web **858 testes / 93,5% stmts, 81,0% branch** ·
`mix format` e `svelte-check` limpos · as quatro visões reconferidas no navegador.

## 5. O que ficou para decisão humana

### (a) A janela de leitura não tem limite inferior — lê o histórico inteiro

O `Index Cond` fecha só por cima: `starts_at < to`. O limite de baixo é `ends_at > from`, e
`ends_at` não está em índice nenhum, então vira `Filter`.

```
Sort  (actual time=4.996..5.017 rows=638)
  Buffers: shared hit=1648
  ->  Seq Scan on appointments a0  (actual rows=638)
        Rows Removed by Filter: 39362      <<<<<<
```

**Leu 40.000 linhas para devolver 638.** Cresce com o histórico da clínica, não com a janela
pedida (confirmado em dois pontos: 730 linhas → 15 buffers; 40.000 → 1.648).

**Por que não foi corrigido:** a correção óbvia — um `starts_at > from - <duração máxima>` que
feche o range no índice — exige responder **qual é a duração máxima de um agendamento**, e hoje
não existe teto: `duration_minutos` é livre. Escolher 24h por conta própria faria sumir da agenda
qualquer bloco mais longo que isso, calado. As alternativas são um índice GiST **não-parcial**
sobre o range (o `appointments_no_overlap` existente é parcial e não serve) ou um teto explícito
de duração no schema. É decisão de arquitetura, e o achado é **pré-existente** na action
`:in_range` — a Entrega 2 só o tornou quente, porque o Mês é a visão que abre por padrão e pede
31 dias.

### (b) O Mês pede o mês, não a grade — e as células de fora não dizem isso

A grade chega a 42 células; o teto do servidor é 31 dias. A janela pedida é o **mês**, então
Jul 26–31 numa grade de agosto aparecem sem contagem. Hoje o único sinal é a opacidade de 50%,
e a mesma ausência de barra significa "sem agendamento" nas células de dentro do mês. Um usuário
pode ler ausência onde há apenas dado não buscado.

Saídas: duas requisições para cobrir a grade, subir o teto para 42 dias, ou marcar visualmente a
célula como não-carregada. As três são decisão de produto, e interagem com (a) — aumentar a
janela piora exatamente a leitura que (a) descreve.

### (c) `:in_range` não tem paginação

Segura hoje pelo teto de 31 dias no controller (~2.500 linhas num mês cheio). Registrado porque
é o mesmo `read` que a Fatia 3 (pacotes) vai reusar, e lá as janelas são maiores.

### (d) `professional_id` sem índice próprio para a checagem de FK

`appointments_professional_id_fkey` é `ON DELETE RESTRICT` e não há btree em `professional_id`
isolado — o composto `(clinic_id, professional_id, starts_at)` tem o prefixo errado e o gist é
parcial. Atenuado porque profissional **arquiva** em vez de excluir, exatamente como o achado (h)
do doc 26 registrou para `appointment_type_id`. Pré-existente, fora deste diff.

### (e) Aberto desde a Entrega 2, não é achado: o profissional vê a escala do colega

O papel `profissional` recebe `capacidade_minutos` de todos os colegas ativos (com `total: 0`).
Não é exposição nova — a visão Dia já entrega a escala completa via `/api/availability`, sob o
mesmo `with_member_scope`. É a pergunta de produto que o [doc 25 §8b](25-agenda.md) deixou
aberta, e vale para as duas visões de uma vez.
