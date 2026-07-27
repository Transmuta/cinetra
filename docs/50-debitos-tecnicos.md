# 50 — Débitos técnicos aceitos

O que o projeto **decidiu não fazer agora**, com o custo de cada escolha escrito. Não é backlog de
features (isso é o [`08`](08-roadmap.md)) nem decisão de agenda em aberto (isso é o
[`30`](30-decisoes-pendentes-agenda.md)): é a lista do que está torto **de propósito**, para que a
próxima pessoa saiba que é escolha e não descuido.

Cada item responde quatro perguntas: **o que é**, **por que virou débito**, **o que custa hoje** e
**o que o paga**.

---

## D-1 · Eliminação de dados do titular (F8) — só soft-delete por ora

**O que é.** O direito de eliminação da LGPD (Art. 18) — "apaguem meus dados". Desenhado em
[`30 §F8`](30-decisoes-pendentes-agenda.md) e [`06 §2.5`](06-seguranca-e-lgpd.md), ancorado no
**Paciente**, que é onde mora o dado pessoal.

**Por que virou débito.** Não é limitação técnica: **falta a resposta jurídica**, e ela é o coração
da feature. Fisioterapia é regulada pelo **COFFITO, não pelo CFM** — os "20 anos" que todo mundo
cita não se aplicam automaticamente ([`06 §2.4`](06-seguranca-e-lgpd.md)). Sem o prazo de guarda, o
sistema não consegue responder a única pergunta que a eliminação faz: *este dado é eliminável ou
está sob guarda legal?* E o erro é assimétrico — não apagar rende multa da ANPD; apagar prontuário
dentro do prazo rende problema com o conselho.

Há ainda uma divergência **entre os próprios docs**, a resolver antes de qualquer linha: o
[`30`](30-decisoes-pendentes-agenda.md) fechou em *hard delete*; o [`06 §2.5`](06-seguranca-e-lgpd.md)
descreve `:request_erasure` — uma **solicitação** com revisão humana, "nunca um `DELETE` cego". São
duas features diferentes.

**O que custa hoje.** Nada operacional: **o projeto inteiro é soft-delete/arquivamento** e continua
assim. `Patient`, `Professional`, `AppointmentType` e `Package` arquivam (`ativo`/status); o
agendamento tem `excluded_at` ([`40`](40-exclusao-de-agendamento.md)). A única deleção real do
sistema é a de `Attendance` (sair da turma). O custo é de **conformidade**, e só aparece no dia em
que a primeira clínica receber um pedido de exclusão.

**O que o paga.** Uma pergunta ao jurídico: *qual resolução do COFFITO rege a guarda de prontuário
de fisioterapia e qual o prazo?* Com ela respondida, o F8 vira fatia normal. Parte do caminho já
está pago: a Onda 5 trocou 4 FKs para `SET NULL` porque, do jeito antigo, **nenhum `User` que já
tivesse criado um agendamento seria apagável** ([`46 §H64`](46-onda-5-producao.md)), e
`on_delete_test.exs` já vigia a semântica de cada FK.

---

## D-2 · Quatro FKs sem índice liderando

**O que é.** `attendances.appointment_id`, `attendances.patient_id`, `packages.patient_id` e
`package_schedules.package_id` não têm índice em que a coluna da FK **lidere** — que é o que a
checagem do `DELETE` do pai usa (`WHERE fk = $1`). Medido em [`48 §2f`](48-onda-6-soltas-e-limpeza.md).

**Por que virou débito.** O caminho que os usaria **não existe**: os pais não têm ação `destroy`.
Criar um índice que ninguém lê é peso a cada `INSERT` numa tabela quente — é a lição do **D-A**
([`35`](35-plano-execucao-backlog.md)), que o projeto já pagou uma vez.

**O que custa hoje.** Zero — nenhuma dessas checagens dispara. Medido: `attendances.appointment_id`
é **Seq Scan de 345 buffers** por agendamento apagado; os outros três são baratos ou irrelevantes
no volume atual.

**O que o paga.** O **D-1 (F8)**: é ele que torna a deleção real, e é junto dele que o índice entra
— medindo o caminho inteiro, não em antecipação. `index [:coluna], all_tenants?: true` + migration
`CONCURRENTLY`. A lista está declarada em `@sem_indice_liderando_conhecidas`, no
`on_delete_test.exs`: sair dela é trabalho declarado, entrar nela sem querer é impossível.

---

## D-3 · A paleta de cores vive em duas linguagens

**O que é.** O `one_of` de `Api.Directory.AppointmentType` é a autoridade; `TYPE_COLORS`/`TYPE_ICONS`
em `web/src/lib/appointment-types.ts` repetem a lista para a tela só *oferecer* o que a API aceita.

**Por que virou débito.** Nenhum compilador liga os dois lados (linguagens diferentes, e um
container **não enxerga** o diretório do outro — `./api:/app` e `./web:/app`).

**O que custa hoje.** Quase nada, e é deliberado: acrescentar uma cor é **acrescentar nos dois
lados**, e há uma *tripwire* em cada um (um teste que fixa a lista e manda mudar o irmão junto).
Pior caso se alguém ignorar as duas: a pessoa escolhe uma cor que a API recusa e recebe um 422 em
inglês.

**O que o paga.** Se um dia incomodar: a API **servir** a paleta no `GET /api/appointment-types` e o
modal consumi-la. É mudança de contrato para um risco cujo pior caso é cosmético — por isso não foi
feita.

---

## D-4 · O e2e fora do CI

**O que é.** `e2e/switch-clinic.spec.ts` percorre criar conta → magic link → onboarding → segunda
clínica → trocar tenant. Roda **local**, contra o `docker compose`; o job do CI foi **removido**.

**Por que virou débito.** O e2e precisa da stack inteira (API, banco, caixa de e-mail de dev) e o
workflow sobe só o `web`. Um job que pula com aviso é ruído com cara de cobertura.

**O que custa hoje.** A jornada de troca de tenant só é verificada por quem rodar o e2e à mão. As
peças isoladas continuam cobertas pela suíte de unidade; o que não é coberto automaticamente é a
**costura** entre elas.

**O que o paga.** Um estudo de e2e (previsto) que decida a forma — inclusive como autenticar contra
um ambiente sem `dev_routes`. O alvo já é configurável por `E2E_BASE_URL`/`E2E_API_ORIGIN`
(`web/e2e/README.md`), então apontar para hml/produção é mudar variável, não código.

---

## D-5 · A janela entre analisar e escrever, no A3

**O que é.** O gate de conflitos futuros (A3/D12) faz o recheck **dentro** da transação que grava
([`48 §5`](48-onda-6-soltas-e-limpeza.md)), como o `CheckAvailability` faz ao agendar. Sob
`READ COMMITTED`, ainda cabe uma janela: um agendamento que **committa** entre o `SELECT` da
análise e o `COMMIT` da escrita não é visto.

**Por que virou débito.** Fechá-la de verdade exige `SERIALIZABLE` ou lock explícito sobre a agenda
futura da clínica — trocar uma corrida rara por contenção em tabela quente.

**O que custa hoje.** Um agendamento fora do expediente que nunca apareceu em lista nenhuma.
Visível na agenda, remarcável, sem perda de dado. Precisa das duas ações na mesma fração de segundo.

**O que o paga.** Se aparecer no uso real: `SELECT ... FOR SHARE` na janela analisada, ou o nível de
isolamento mais forte só nessa transação.
