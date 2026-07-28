# A ficha do paciente encolhe — e passa a responder "quando ele volta?"

A ficha (`/pacientes/[id]`) nasceu na [Fatia Pacientes](24-auditoria-bate-volta-pacientes.md), ganhou
Pacotes na [Fatia 3](../.claude/rules/testes.md), Histórico na Frente 7 ([doc 43](43-bate-volta-onda-3.md))
e Anexos no [doc 51](51-ficha-anexos-e-storage.md). Cada fatia acrescentou um cartão; nenhuma mediu
o que a soma tinha virado. Este doc registra a redução de 2026-07-27, que partiu de uma queixa de
uso:

> *"a ficha técnica ficou muito grande, a página"*

## 1. O que a medição mostrou

Medido no browser (viewport 1280×720, área útil ~663px), não estimado:

| Ficha | Antes | Depois |
| --- | --- | --- |
| **Mariana Alves Teste** — 1 sessão, 0 pacotes, cadastro quase vazio | **1.592px** (2,4 telas) | **~1.010px** (1,5) |
| **Paciente Volume 173** — 42 sessões, cadastro cheio | **3.096px** (4,7 telas) | **1.785px** (2,7) |

O número que redefiniu o diagnóstico é o primeiro: **a ficha mais vazia possível já tinha 2,4
telas.** Não era "muito dado", era muito continente. E a altura era **a mesma** com o cadastro cheio
ou vazio — os 27 campos desenhavam um travessão quando não havia valor, então preencher a ficha não
mudava um pixel.

Três causas, medidas uma a uma.

### 1.1 — 20 dos 27 campos eram `—`

Na ficha da Mariana, 74% do espaço do cadastro estava reservado para dado que não existe.
"Contato de emergência" custava 174px para exibir três travessões; "Atendimento & convênio", 330px
para exibir dois valores.

### 1.2 — Quatro fatos ditos duas vezes (um deles, três)

`Idade` (stat do topo + cartão Identificação), `Consentimento LGPD` (stat + cartão Consentimentos),
`Comunicação` (chip do topo + cartão), e o pior:

```
Tipo de atendimento          Convênio
Unimed                       Unimed          ← células vizinhas, texto idêntico
```

mais o chip `Unimed` no cabeçalho. **Três vezes na mesma tela.** O comentário do próprio código
([`+page.svelte:179`](../web/src/routes/(app)/pacientes/[id]/+page.svelte)) já aplicava esse critério
para tirar "Comunicação" dos stats — só não tinha ido até o fim.

### 1.3 — "Histórico de atendimentos" mostrava o futuro

[`list_patient_history`](../api/lib/api/scheduling.ex) ordenava `session_starts_at: :desc` **sem
recorte de data**. Em 27/07/2026, o topo do cartão era `25/09/2026 — Previsto`, `23/09/2026 —
Previsto`, `16/09/2026 — Previsto`: as ~10 primeiras linhas eram coisas que não tinham acontecido,
dentro de um cartão chamado histórico.

Pior que o rótulo: **o teto de 50 era gasto com elas**. Um paciente com pacote longo perdia o
próprio passado — e o único aviso era um `<p>` mudo ("há mais no histórico") que informava a
truncagem sem oferecer caminho.

E a pergunta que a recepção faz com o telefone na mão — *"quando ele volta?"* — a ficha **não
respondia em lugar nenhum**.

## 2. Os quatro movimentos

### M1 · Campo vazio não ocupa espaço

O cadastro deixou de ser markup e virou dado (`cartoes`, um `$derived`). Campo sem valor não
renderiza; cartão que ficou sem nenhum campo não é desenhado. Descrever os cartões como dado é o que
permite a terceira decisão: **contar** o que ficou de fora.

Porque esconder o vazio esconde junto o "falta preencher". O rodapé devolve isso em uma linha —
`20 campos não preenchidos · Completar cadastro` — em vez de em 20 travessões, e só para quem pode
editar (owner·admin): oferecer o caminho a quem leva 403 é pior que não oferecer.

### M2 · O repetido sai

Saem `Idade` de Identificação, `Tipo de atendimento` de Atendimento & convênio e o cartão
**Consentimentos** inteiro (216px). Os dois fatos continuam na tela — o stat `CONSENTIMENTO LGPD` e o
selo `Contato autorizado` já os diziam. O que o cartão acrescentava era a **cobertura** de cada
consentimento ("Prontuário, documentos e assistência"), texto estático igual em toda ficha: virou
`title`.

### M3 · Duas listas, e não uma

`list_patient_history/3` virou [`list_patient_sessions/3`](../api/lib/api/scheduling.ex) e devolve
dois recortes numa transação só, com a fronteira em `scope.now` (o relógio injetável, nunca
`DateTime.utc_now/0`):

| | filtro | ordem | teto |
| --- | --- | --- | --- |
| `sessions` | `session_starts_at <= now` | `desc` | `limit`/`offset`, 8 na abertura da ficha |
| `upcoming` | `session_starts_at > now` | `asc` | 5 (`@proximas_na_ficha`) |

Decisões que o desenho fixou:

- **A sessão que já começou é passado**, mesmo com a presença ainda `:prevista` — quem marca presença
  o faz depois da hora, e a linha não pode saltar de cartão a cada F5 durante o atendimento. Por isso
  o `<=` fica com o histórico e o futuro é estritamente `>`.
- **As próximas param em 5.** É um cartão de resposta, não uma listagem: um pacote de 20 sessões
  desenharia 20 linhas e recriaria, do outro lado, o problema que este doc veio resolver. Acima
  disso, "Ver na agenda" (`/agenda?paciente=`).
- **As próximas só vêm na primeira página** (`offset == 0`). Recalculá-las para desenhar a segunda
  página do histórico é trabalho de banco para um cartão que não mudou.
- **Uma rota, não duas.** A ficha quer as duas listas na mesma abertura e o domínio as lê na mesma
  transação — separar em dois endpoints trocaria uma query barata por um round-trip.
- **O histórico abre com 8 linhas**; o resto é `?historico=200`, um link que sobe o teto pela URL.
  Sem estado no cliente: funciona sem JS e é compartilhável.
- **Sem contagem no link** ("Ver histórico completo", não "ver as outras 29"). O número exigiria um
  `COUNT(*)` na maior tabela do sistema por ficha aberta — que é exatamente o que a trilha de
  auditoria tirou ([doc 55 §6](55-auditoria-ui-ux.md)).

O índice `(clinic_id, patient_id, session_starts_at)` atende os dois recortes sem mudança: o filtro
de data e a ordem são a mesma terceira coluna, nas duas direções.

### M4 · O cadastro recolhido — recortado pela medição

A hipótese original era recolher o cadastro inteiro num acordeão. **A medição do M1 a derrubou:** com
o campo vazio fora, a coluna caiu de ~1.280px para ~350px num paciente típico, e recolher dado que
alguém digitou de propósito passou a custar mais do que rende.

Sobrou o recorte que a medição sustenta — só os dois cartões que ninguém abre com o paciente na
linha, em `<details>` fechado:

| Sempre aberto | Recolhido |
| --- | --- |
| **Contato** (telefone, e-mail, responsável legal, endereço) | **Identificação** (nascimento, gênero, estado civil, RG) |
| **Atendimento & convênio** (convênio, carteirinha, validade, médico, CRM, profissional preferido) | **Perfil** (profissão, empresa, como conheceu) |
| **Contato de emergência** | |

Duas mudanças de lugar que o recorte forçou:

- **"Responsável legal" saiu de Identificação para Contato.** Paciente menor de idade é caso de
  *atendimento* — a lista tem até o segmento "Com responsável" —, e atrás de um clique ele deixaria
  de ser visto na hora em que importa.
- **Profissão/empresa/como conheceu saíram de "Atendimento & convênio"** para o cartão "Perfil". O
  cartão de convênio ficou só com o que se confere ao telefone.

`<details>` nativo, e não um `{#if}` com estado: abre por teclado, o conteúdo continua no DOM e não
há estado para sincronizar. **Custo assumido:** `<details>` fechado não é achado pelo Ctrl+F de todo
navegador — por isso só entram os dois cartões de conferência, nunca telefone, convênio ou
emergência.

## 3. Layout

A coluna do cadastro perdeu a proporção maior (era `flex-[1.5]`, agora `1`) e a da atividade ganhou
(`1.2`). Com o campo vazio fora, o cadastro deixou de ser a coluna alta: quem cresce é a atividade, e
ela cresce com o paciente. A ordem da coluna direita passa a ser **Próximas → Pacotes → Histórico →
Anexos** — a ordem das perguntas.

## 4. Testes

TDD nos dois lados; 5 testes vermelhos primeiro no backend.

- **Backend** (+5 em [`patients_controller_test.exs`](../api/test/api_web/controllers/patients_controller_test.exs)):
  futuro fora do histórico, ordem `asc` das próximas, teto de 5 com aviso, `offset > 0` sem
  `upcoming`, e `offset` pulando o que já foi mostrado.
- **Web** (+22): `PatientUpcoming.svelte.test.ts` novo (6), o link do histórico (2), as duas listas no
  BFF e no load (7), e **`page.svelte.test.ts`, que não existia** (14) — a página da ficha não tinha
  teste de componente nenhum antes desta fatia.

**Um teste passou por motivo errado e foi consertado.** `queryByText(/não preenchidos/i)` ficava
verde com o rodapé na tela, porque faltando **um** campo o texto é singular ("1 campo não
preenchido"). Virou consulta por papel (`queryByRole('link')`), mais um teste que fixa justamente o
caso de um campo. É a mesma classe de armadilha do doc 49: a asserção casava com a prosa, não com o
fato.

Suítes: **backend 1.194 testes, 0 falhas, 90,8%**; **web 1.481 testes, 0 falhas, 90,5%** — acima dos
pisos de [`coveralls.json`](../api/coveralls.json) e [`vite.config.ts`](../web/vite.config.ts).
`mix format --check-formatted` e `svelte-check` (0 erros, 0 avisos) limpos.

## 5. O que fica para você

1. **"Previsto" numa sessão passada continua estranho** — agora legitimamente: significa que ninguém
   deu baixa na presença. Vi duas assim no Volume 173 (24/07 e 23/07, contra hoje 27/07). O rótulo é
   verdadeiro, mas "sem registro" diria melhor o que aconteceu, e a ficha poderia contá-las. Mexe em
   `ATTENDANCE_META`, que é compartilhado com o drawer e a agenda — por isso não entrou aqui.
2. **`?historico=200` recarrega a ficha inteira** (as seis chamadas do load) para crescer um cartão.
   É barato hoje (~300ms, tudo em paralelo) e o ganho de simplicidade é grande — mas se virar
   incômodo, o conserto é buscar a página no cliente contra o mesmo endpoint, que já aceita `offset`.
3. **Dado de dev alterado**: preenchi o cadastro de `Paciente Volume 173` (clínica de seed de
   performance) por SQL para medir a ficha cheia. É seed de dev, mas está registrado aqui.

## 6. O índice: medido pelo caminho da app

O filtro novo por data não ganhou índice próprio — ele anexa no
`(clinic_id, patient_id, session_starts_at)` que a Onda 3 já tinha criado. Isso foi **provado**, não
suposto, pelo procedimento que a [lição do doc 35](35-plano-execucao-backlog.md) fixou (medir pelo
caminho da aplicação, nunca por SQL digitado no `psql`): sessão real por cookie, 10 aberturas da
ficha do `Paciente Volume 173`, `pg_stat_user_indexes` antes e depois.

| Contador | Antes | Depois (10 aberturas) |
| --- | --- | --- |
| `attendances_clinic_id_patient_id_session_starts_at_index` · `idx_scan` | 83 | **107** (+24) |
| `attendances_pkey` · `idx_scan` | 0 | 0 |
| `attendances` · `seq_scan` | 1 | **1** (inalterado) |

Os dois recortes (passadas e próximas) descem pelo mesmo índice, ~2,4 scans por abertura, e nenhuma
varredura sequencial apareceu. O `<=`/`>` sobre a coluna `session_starts_at` não sofre a armadilha do
cast que derrubou o índice de expressão do doc 35: a coluna é `timestamp` e a comparação é com
`timestamp`.
