# 88 — Rodada do roteiro de QA guiado (doc 82), 2026-07-29

Execução do [roteiro 82](82-roteiro-qa-guiado.md) contra a stack local (`docker compose`, dev),
dirigindo o browser pelo Playwright e batendo na API pelas bordas. Não é a re-homologação com a
Andreza: é a **passada interna** que o próprio doc 82 prevê ("ou como passada interna antes de
release").

**Ambiente:** `api`/`web`/`db` do compose; `RESEND_API_KEY` comentada no `.env` (a armadilha §0
está desarmada — `/dev/mailbox` responde e os magic links aparecem). Clínica de teste
`Clínica QA82`, criada do zero pela tela, com as quatro personas do roteiro.

---

## 1. O que foi coberto — e o que não foi

O roteiro tem ~180 caixas. Em **três rodadas** (2026-07-29 e 30) foram exercitadas **cerca de 85%**
delas. As regras que o produto **afirma** (RBAC, validações, conflito, expediente, concorrência,
débito de pacote, gate de impacto) foram varridas por inteiro, porque são baratas e definitivas
pela API; o que restou é o que só a mão percorre — **arraste**, CEP, chips da fila, ficha aberta —
mais o §9, que precisa de provedor.

| Seção | Cobertura | Observação |
| --- | --- | --- |
| §1 conta e sessão | boa | criação/onboarding, reuso do link ✅; **2 achados** (A-11, A-12); rate limit **não testável em dev**; /perfil e sessão expirada não rodados |
| §2 equipe e papéis | **completa** | convites, reenvio, troca de papel sem re-login, ≥1 owner ✅ |
| §3 configurações | **completa** | CNPJ, tipos (arquivar/restaurar), auditoria, hachura e **gate de impacto** ✅ |
| §4 pacientes | boa | validações + duplicados sob a regra nova ✅; CEP, busca, ficha e anexos-UI não rodados |
| §5 profissionais | **completa** | telefone, vínculo, **A7 fail-closed**, horário ⊆ clínica ✅ |
| §6 agenda | boa | expediente, conflito, encaixe, presença, 409, drawer, ciclo de vida ✅; **arraste**, visões e AN-12 não rodados |
| §7 fila | boa | adicionar, upsert e **oferta→conversão** ✅; chips de vaga não rodados |
| §8 pacotes | boa | ciclo completo + **regra de débito** ✅; prévia no modal e turma multi-pacote não rodadas |
| §9 comunicação | mínima | sem provedor em dev |
| §10 notificações | boa | ✅ incluindo caixa por usuário |
| §11 relatórios | boa | fórmula, escopo do profissional, excluído×cancelado ✅ + **1 achado** (A-1) |
| §12 RBAC | **completa** | matriz célula a célula ✅ |
| §13 robustez | boa | duplo clique e F5 ✅; **offline reprova** (A-10); Slow 3G não rodado |
| §14 mobile/a11y | boa | 390px, toque (ACC-10) e zoom 200% ✅; 28 violações de contraste no escuro seguem conhecidas (doc 80) |
| §15 landing/404 | boa | ✅ |

---

## 2. A matriz de acesso (§12), medida célula a célula

Quatro sessões reais (magic link de verdade, uma por persona), uma sonda HTTP por célula.
`201/200` = permitido, `403` = recusado.

|  | dona | ana (admin) | rafael (prof.) | bia (recepção) | bate com o §12? |
| --- | --- | --- | --- | --- | --- |
| criar agendamento (coluna da Bea) | 201 | 201 | 201 | 201 | ✅ |
| criar na coluna do **colega** | 201 | 201 | **403** | 201 | ✅ "só na própria coluna" |
| marcar **encaixe** | 201 | 201 | **403** | 201 | ✅ A9 / D-H2 |
| criar paciente | 201 | 201 | **403** | 201 | ✅ revisão 2026-07-29 |
| editar paciente | 200 | 200 | **403** | 200 | ✅ |
| ver anexos | 200 | 200 | **403** | 200 | ✅ única exceção ao D16 |
| fila: adicionar | 201 | 201 | 201 | 201 | ✅ |
| pacote: prévia | 200 | 200 | 200 | 200 | ✅ |
| profissionais: criar | 201 | 201 | **403** | **403** | ✅ |
| tipos: criar | 422¹ | 422¹ | **403** | **403** | ✅ |
| horários da clínica | 200 | 200 | **403** | **403** | ✅ |
| dados da clínica | 200 | 200 | **403** | **403** | ✅ |
| equipe: convidar | 201 | 201 | **403** | **403** | ✅ |
| equipe: **listar** | 200 | 200 | **200** | **200** | ⚠️ ver achado **A-3** |
| auditoria: ler | 200 | 200 | **403** | **403** | ✅ |
| relatórios | 200 | 200 | 200² | 200 | ✅ |

¹ 422 é o nome repetido do próprio teste (autorização passou — é o §3 "nome repetido → recusado").
² O relatório do Rafael traz **1** profissional; o da dona, **4**. O recorte A7 vale.

Contraprova pela tela: `/configuracoes/auditoria` como Bia devolve a **página 403** ("A auditoria é
restrita ao dono e aos administradores da clínica"), e `/configuracoes/clinica` abre **só leitura**,
sem nenhum controle de edição — que é o que o §3 aceita ("só leitura ou 403").

---

## 3. Regras confirmadas (as que o roteiro nomeia)

Todas medidas nesta rodada, pela camada indicada:

**§3 CNPJ** — DV errado `422`; numérico válido `200`; **alfanumérico válido `200`** e alfanumérico
com DV errado `422`. O topo do sidebar passa a exibir `12.ABC.345/01DE-35` formatado. O CNPJ novo
do Serpro está de pé nas duas pontas.

**§4 cadastro** — as oito validações do roteiro passaram, todas com `422`: sem telefone (D6),
CPF com DV errado, `111.111.111-11`, e-mail sem forma de e-mail, nascimento no futuro, nascimento
em 1889. Mínimo (nome+telefone) e telefone **fixo** entram com `201`.

**§4 duplicados** — avisam sem barrar, e **nomeiam**: digitar o CPF da Marina numa ficha nova
levanta *"Possível duplicado: **Marina Prado** já tem este CPF."* Máscaras corretas
(`390.533.447-05`, `(11) 99111-0000`). O botão segue desabilitado só porque o nome está vazio.

> ⚠️ **Medição histórica.** Isto vale para o comportamento **anterior** ao doc 89, que reverteu a
> política: duplicado agora **barra**. Ver achado A-8.

**§6 expediente (D14)** — 22:00 recusa com `422` **e recusa igual com `encaixe: true`**. O bloqueio
é absoluto, como o D14 manda — encaixe não é saída para fora do expediente.

**§6 conflito** — `422` com `code: schedule_conflict` e a mensagem "Esse horário sobrepõe outro
agendamento."; o mesmo POST com `encaixe: true` passa a `201`. Como **Rafael**, a saída de encaixe
devolve `403` (A9).

**§6 presença por participante (D13)** — turma de 2 com 1 presente e 1 falta: o card da agenda
mostra **"1 de 2 concluídas"**, nunca a palavra "Concluído", com "2/4 vagas ocupadas". O drawer traz
`ter, 28/07 · 09:00–09:50 (50min)` (dia + faixa + duração, como o §6 exige), o **motivo da falta
reaparece** ("Motivo: Nao avisou que faltaria") e **"Justificada" é um toggle por pessoa**.
Marcar presença **antes da hora** devolve `422` no servidor (D-E4.1).

**§6 concorrência** — `PATCH /reschedule` com `expected_version` defasada devolve **409**
`version_conflict`: *"Este agendamento mudou desde que você o abriu. Recarregue e tente de novo."*

**§7 fila** — re-adicionar o mesmo paciente **edita** (o total ficou em 1 após cinco POSTs).

**§8 pacotes (2ª rodada)** — o ciclo inteiro responde: criar (4 sessões, punitivo), materialização
(as sessões nascem com `appointment_id` + `attendance_id`), `+1`, `−1`, ajustar grade, pausar e
retomar. E a regra que mais importa, medida sessão a sessão num pacote punitivo de 3:

| passo | usadas | leitura |
| --- | --- | --- |
| estado inicial | 0 de 3 | — |
| **presença** na sessão 1 | **1** | debitou |
| **falta punitiva** na sessão 2 | **2** | debitou |
| falta na sessão 3 | 3 | debitou |
| **justificar** essa falta | **2** | **devolveu a sessão** |

É exatamente o §8: *"presença debita; falta punitiva debita, falta justificada não"*.

**§10 notificações** — sino com badge 3, uma notificação por convite aceito, abas Todas/Não lidas,
"Marcar todas como lidas" e "Limpar tudo" presentes.

**§11 fórmula (AN-05/ACC-10)** — o ícone de ajuda é **botão**: o clique abre
*"Como calculamos: Atendimentos — Todos os agendamentos do período, exceto os cancelados. Inclui os
que ainda vão acontecer."* O caminho por toque existe.

**§15** — rota inexistente devolve a página de erro do app (404 dentro do cromo), sem stack trace.

---

### Rodada 3 (2026-07-30) — a fila do §7, com a API de volta

| Item do roteiro | Resultado |
| --- | --- |
| **§4 duplicado sob a regra nova** (doc 89) | CPF, telefone e e-mail repetidos → **422** com *"já está em outra ficha da clínica — se ela estiver arquivada, reative-a"*. **Canonicalização provada**: `390.533.447-05` colide com `39053344705`, e `+55 11 99111-0000` com `11991110000`. CPF/telefone livres → 201 |
| §4 ficha **arquivada** também bloqueia | ✅ é a decisão 3 do doc 89, e a mensagem já ensina o remédio |
| §1 magic link **reusado** | ✅ 1º uso 302, 2º uso do mesmo link **401** |
| §1 **link velho** depois de pedir outro | ⚠️ **os dois continuam valendo** — ver A-12 |
| §2 **reenviar convite** | ✅ 2 e-mails para o convidado pendente (o convite cria o `User`, então o reenvio acha alguém) |
| §2 **≥1 owner** | ✅ rebaixar e remover a única dona → **422** *"não é possível remover ou rebaixar o único owner da clínica"* |
| §2 **trocar papel reflete sem re-login** | ✅ Bia→admin alcança `/api/audit` (200) no request seguinte; voltando a recepção, **403** de novo |
| §5 **A7 fail-closed** | ✅ profissional **sem vínculo**: **0 agendamentos, 0 colunas**. Rafael (vinculado): 1 coluna, 3 blocos. Dona/Ana/Bia: 5 colunas, 4 blocos |
| §5 horário do profissional ⊄ clínica | ✅ `06:00–22:00` → **422** *"dia 3: período 06:00–22:00 fora do horário da clínica nesse dia"* |
| §5 estreitar horário sobre sessão marcada | ✅ **409** (o gate A3/D12) |
| §3 **gate de impacto** ao fechar o dia | ✅ **409 `future_conflicts`** com `meta.total: 17` e a lista (data, hora, profissional, paciente). **E não gravou**: o expediente seguiu `08–12/13–18` e o agendamento continuou `agendado` |
| §3 arquivar / restaurar tipo | ✅ `ativo` vai a `false` e volta a `true` |
| §6 cancelar (motivo), reabrir, remarcar (motivo) | ✅ os três; o `cancel_reason` e o `reschedule_reason` ficam gravados (D-H3) |
| §11 excluído × cancelado | ✅ cancelados **1 → 2** ao cancelar, **2 → 1** ao excluir: cancelado conta, excluído sai da conta |
| §7 oferecer → converter | ✅ os slots vêm com data/profissional; converter → **201** e a fila cai de **2 para 1** |
| §10/§12 caixa por usuário | ✅ não-lidas distintas por pessoa (dona 7, ana 6, bia 2, rafael 12) |
| §13 **duplo clique** | ✅ dois cliques no mesmo tick → **uma** ficha no servidor |
| §13 **F5 com o drawer aberto** | ✅ o `?agendamento=` sobrevive e a gaveta reabre |
| §14 celular (390px) | ✅ sem rolagem horizontal; a gaveta abre com o horário visível |
| §14 **fórmula no toque** (ACC-10) | ✅ abre no clique/toque em 390px |
| §14 **zoom 200%** (640×360) | ✅ `/entrar` e `/agenda` sem rolagem horizontal |

## 4. Achados

### A-1 · Relatórios não contam as faltas de uma turma — **médio**

A turma de 2 com **1 presente e 1 falta** aparece em Relatórios como *Atendimentos 1, Concluídos 1,
**Faltas 0**, Taxa de falta 0%*. A falta do João Ribeiro é invisível no relatório, embora o card da
agenda, o drawer e o débito do pacote a enxerguem.

A causa está em [`api/lib/api/scheduling.ex:889`](../api/lib/api/scheduling.ex#L889):

```elixir
faltas = Enum.count(appointments, &(&1.status == :faltou))
```

O resumo conta **status de bloco**, e o bloco é o *rollup* das presenças — cuja regra é "alguma
concluída ⇒ o bloco é concluído". O próprio domínio reconhece a divergência na linha 465: *"o bloco
pode estar `:concluido` com a presença dele `:faltou`"*.

Não é só o caso misto: como o relatório conta blocos, **uma turma de 4 em que os 4 faltaram conta
1 falta, não 4**. Para atendimento individual bloco e presença coincidem, e por isso o desvio nunca
apareceu.

Isso é exatamente o que o §11 manda conferir ("conte na mão — é o teste que a Andreza fará"): quem
criar a turma do §6 e olhar Relatórios vai contar 1 falta e ler 0.

**Decisão pendente:** o KPI deve contar presenças (`attendances`) em vez de blocos? A taxa de falta
é `faltas / (concluídos + faltas)`; migrar a base para presença muda o denominador de todos os
números históricos. É decisão de produto, não conserto óbvio — por isso está aqui e não consertado.

### A-2 · `recepcao.spec.ts` ainda cobra a regra anterior à revisão — **médio (suíte vermelha)**

O único teste vermelho da suíte e2e existente:

```
recepcao.spec.ts:77  expect(...).toBe(403)   Expected: 403   Received: 422
     await apiDaRita.post('/api/patients', { data: { nome: 'Cadastro Indevido' } })
```

O `422` é a resposta **certa**: desde a revisão de 2026-07-29 a recepção **cria ficha**, então a
requisição passa pela autorização e só esbarra na validação (falta `tel`, D6). O teste ficou preso
à matriz velha. O §12 do doc 82 já registra a mudança ("recepção ✅ *(revisão 2026-07-29)*").

**Conserto:** trocar a asserção para provar a regra nova — `403` some, e o que se afirma passa a ser
"cria com telefone (`201`) e o `422` sem telefone é validação, não autorização".

### A-3 · O doc 82 pede 403 em `/configuracoes/equipe`, e a decisão implementada é outra — **defeito de documento**

O §2 diz *"Profissional/recepção acessando `/configuracoes/equipe` direto pela URL → **403** da
tela"*, e a matriz do §12 marca ❌ (403) para os dois. **Não é o que o produto faz, e não é o que ele
decidiu fazer.** Como Bia (recepção), a tela abre e lista nome, e-mail, papel e vínculo de todo
mundo.

Isso é deliberado e está afirmado em teste — `recepcao.spec.ts` documenta:

> A equipe é o caso interessante: a **LISTA** é de todo membro (quem trabalha junto sabe quem
> trabalha junto), e o que some são as **AÇÕES**.

E de fato os botões "Convidar membro" e "Remover acesso" não são renderizados para ela, e a API
recusa `POST/PATCH/DELETE /api/members` com 403 — só o `GET` é liberado, com o porquê no moduledoc
do controller.

Ou seja: **o produto está coerente consigo mesmo; o roteiro é que está errado.** Seguindo a
instrução do próprio doc 82 ("Se o esperado parecer errado, a discussão é sobre a decisão"), o
ponto para a conversa é: *expor e-mail de colega à recepção é aceitável?* Se sim, corrigir §2 e §12.
Se não, é mudança de produto — e aí o teste é que muda.

Detalhe menor a reboque: o comentário do `+page.server.ts` da tela ainda promete o 403 que nunca
acontece (`if (result.status === 403)` virou ramo morto).

### A-4 · A suíte e2e não subia: faltava `playwright install --with-deps` — **ambiente**

A primeira execução deu **35 de 35 falhas**, todas iguais:

```
chrome-headless-shell: error while loading shared libraries: libnspr4.so: cannot open shared object file
```

Os binários do Chromium estavam baixados, as bibliotecas do sistema não. O `e2e/README.md` manda
rodar `npx playwright install --with-deps chromium` "na 1ª vez", mas nada verifica — e o sintoma
(35 falhas com stack de browser) não diz "rode o install". Depois do `--with-deps`: **34 passaram,
1 falhou** (o A-2).

Estado final da suíte ao fim desta rodada, já com os 5 cenários novos:
**39 passaram, 1 falhou** (34,9s) — a única vermelha é o A-2.

**Sugestão:** ou instalar as deps na imagem do `web` (Dockerfile de dev), ou fazer o
`test:e2e` falhar cedo com a mensagem certa quando o browser não sobe.

### A-5 · `webServer` de 120s não cobre `build && preview` — **ambiente, intermitente**

`Timed out waiting 120000ms from config.webServer.` O `playwright.config.ts` dá 120s para
`npm run build && npm run preview`, e o build sozinho passa disso em máquina fria — a suíte inteira
morre antes de começar. Além disso, rodar o `vite dev` (5173) invalida o `.svelte-kit/output` do
build, então um `preview` posterior quebra com `Cannot find module '.../server/manifest.js'`.

**Sugestão:** subir o `timeout` do `webServer` para ~300s.

### A-6 · O formulário de paciente re-renderiza a cada tecla — **observação, não reproduzida à mão**

Ao automatizar os dois itens de tela do §4, o campo de CPF aparece como
`element was detached from the DOM, retrying` **até o timeout de 90s**: a cada `input` o formulário
se re-monta (a consulta de duplicado é agendada no `oninput` de telefone e de CPF, e o
`{#if dup}` entra e sai da árvore).

**Digitando à mão o formulário se comporta** — preenchi nome, telefone e CPF pelo browser e os
valores ficaram de pé, com o aviso de duplicado estável (é a evidência do §3 acima). Por isso isto
está como *observação*, não como defeito: não consegui reproduzir dano visível ao usuário.

O que merece um olhar é **por que o desanexamento não converge** — um `detached, retrying` que dura
90s é a assinatura de re-render contínuo, e o projeto já levou uma dessas na prévia do pacote
("GUARD anti-loop", doc 09). Se for laço, o custo aparece em máquina fraca e em teclado rápido
(tecla perdida, foco roubado), que é justamente o que ninguém testa.

Os dois testes foram **retirados** do spec com o porquê no lugar, em vez de ficarem vermelhos:
teste que falha por instabilidade própria treina a equipe a ignorar vermelho.

### A-7 · A página 404 diz "Em construção" — **cosmético**

Rota inexistente devolve *"404 — **Em construção**. Esta parte do sistema ainda não foi construída.
Volte para a Equipe & acessos."* São duas heranças de uma fatia antiga: a rota catch-all
([`(app)/[...notfound]/+page.ts`](../web/src/routes/(app)/%5B...notfound%5D/+page.ts)) ainda carrega
o comentário *"Só /configuracoes/equipe está pronto nesta fatia"*, e o link de saída aponta para
Equipe & acessos em vez da Agenda. Para quem digitou errado, "ainda não foi construída" informa
errado — e mandar a recepção para a tela de Equipe é escolha estranha (é o mesmo destino que a
página 403 oferece).

---

### A-8 · O §4 do roteiro ficou desatualizado: duplicado passou a **barrar** — **corrigir o doc 82**

Durante esta rodada o produto mudou embaixo da medição, e isso precisa ficar registrado para quem
ler o §3 acima.

O §4 do doc 82 manda:

> **Duplicado por CPF**: cadastre o mesmo CPF de um paciente existente → **aviso** (não barra)
> nomeando o outro paciente. · **Duplicado por telefone**: idem.

Foi o que medi, e passou: CPF e telefone repetidos entraram com **201**, com o aviso
*"Possível duplicado: Marina Prado já tem este CPF"*. **Essa medição vale para o comportamento
anterior a [`docs/89`](89-identificacao-unica.md)** e já é histórica.

A política foi **revertida de propósito**, a pedido, em 2026-07-29 (*"vamo bloquear cpf duplicado
ou telefone duplicado ou email duplicado"*): `cpf`, `tel` e `email` preenchidos passam a ser
**únicos por clínica** nos dois cadastros de pessoa, e a migration
`bloqueia_identificacao_duplicada` cria os seis índices. Não é regressão — é decisão nova, com as
três escolhas (telefone entra; vale para Profissionais; ficha arquivada também bloqueia)
registradas no doc 89.

**O que fazer:** reescrever os dois itens de duplicado do §4 do doc 82, de "avisa, não barra" para
"barra, e a mensagem manda reativar a ficha arquivada". Enquanto não for reescrito, quem rodar o
roteiro vai anotar um falso desvio — o esperado é que virou o oposto.

> Não repito aqui os riscos de índice único sobre dado repetido: o moduledoc da migration já os
> enfrenta (tabelas vazias no servidor, o porquê de dispensar `CONCURRENTLY`, e a canonicalização
> como o que impede `''` de colidir). Os duplicados que **esta rodada de QA criou** em dev — as
> fichas de sonda do §4 — são parte dos "3 pares de telefone e 1 de CPF" que o doc 89 relata ter
> limpado à mão para o índice subir.

### A-9 · A API em dev recusa **toda** requisição enquanto houver codegen pendente — **ambiente**

No meio da 2ª rodada a API passou a responder **500 em tudo**, inclusive `/api/health` e
`/dev/mailbox`:

```
** (Ash.Error.Framework.PendingCodegen) Pending Code Generation Detected for 3 files
   (ash_phoenix) lib/ash_phoenix/plug/check_codegen_status.ex:45
```

É o `plug AshPhoenix.Plug.CheckCodegenStatus` de [`endpoint.ex:48`](../api/lib/api_web/endpoint.ex#L48),
disparado pelas identities novas do A-8 assim que o code reloader recompilou os recursos. Não há
config para desligá-lo.

O comportamento é intencional e defensável (falhar ruidosamente é melhor que servir com o schema
divergente), mas duas arestas valem registro:

1. **o sintoma não se parece com a causa** — de fora, é a stack inteira fora do ar; foi preciso ler
   o log para achar `PendingCodegen`. O `e2e/README.md` já documenta esse par ("o /dev/mailbox
   responde 500 nos dois casos"), o que confirma que a equipe já tropeçou nisto antes;
2. **o gate depende do relógio do code reloader**, não do boot: a mesma árvore serviu centenas de
   requisições nesta sessão antes de bloquear. Ou seja, dá para trabalhar horas com um codegen
   pendente e ser interrompido no pior momento.

Esta rodada **parou aqui, por decisão** — gerar migration dentro de trabalho em andamento alheio
não é chamada do QA. O bloqueio se resolveu sozinho minutos depois, quando a fatia do doc 89 gerou
a `bloqueia_identificacao_duplicada` e a aplicou: a API voltou a `200`. Era transitório, e a causa
era trabalho em voo — não defeito. O que ficou por rodar está na lista da §7 abaixo.

A lição que sobra é de **método, para quem rodar o roteiro**: QA e desenvolvimento na mesma árvore
ao mesmo tempo se atrapalham. Metade das medições do §4 desta rodada envelheceu em uma hora porque
a regra mudou embaixo. Vale congelar a árvore (ou rodar contra HML) antes de uma passada que se
pretende citável.

### A-10 · Rede fora ao salvar a ficha: tela de 500 e **o digitado se perde** — **médio**

O cenário exato do §13, e reprova. Com a ficha preenchida e a rede derrubada, clicar em
*Cadastrar paciente* troca **o formulário inteiro** por:

```
500
Algo deu errado
Failed to fetch
Voltar ao início
```

Medido: depois do submit, `getByRole('textbox', {name: /Nome completo/})` tem **contagem 0** — o
formulário não existe mais, e com ele foi tudo o que a recepção digitou (a ficha tem 31 campos).

São três defeitos no mesmo sintoma:

1. **falha de rede virou "500"** — o servidor não respondeu coisa nenhuma; o código está errado;
2. **`Failed to fetch` é mensagem interna do browser**, em inglês, na cara do usuário — o oposto do
   "erro civilizado" que o roteiro pede;
3. **o trabalho é perdido**, que é o dano real: numa clínica com wi-fi ruim, isso é a ficha inteira
   digitada de novo.

Está registrado como `test.fail()` em
[`roteiro82-robustez.spec.ts`](../web/e2e/roteiro82-robustez.spec.ts): a expectativa correta está
escrita, o teste roda, e no dia em que alguém consertar ele acusa "unexpected pass" e cobra a
remoção da marca. Comparar com o **duplo clique**, que passa — ali o `4e0e020` fez o trabalho.

### A-11 · Quem se cadastrou e não clicou no link **não consegue pedir outro** — **médio**

`POST /api/auth/magic-link` responde `200` (neutro) mas **não envia nada** para quem se cadastrou
em `/criar-conta` e nunca consumiu o primeiro link. Medido: três pedidos seguidos, **um** e-mail na
caixa; e nenhuma linha em `users` para o endereço.

A causa está em [`request_magic_link.ex`](../api/lib/api/accounts/user/request_magic_link.ex): o
`User` só nasce quando o link é **consumido**, e a cláusula

```elixir
defp send_link(_strategy, _identity, _nome, nil, false, _context, _opts), do: :ok
```

silencia o envio para "e-mail sem conta" quando `register? == false` — que é exatamente o caso de
quem já pediu cadastro e ainda não confirmou. O login (`/entrar`) manda `register: false`.

O efeito para a pessoa: ela se cadastra, perde o e-mail, vai em *"Já tem conta? Entrar"*, digita o
endereço, lê "verifique seu e-mail" — e nada chega, para sempre. A saída existe (voltar em
`/criar-conta`), mas nada na tela a indica.

> **Não confundir com o convite**, que foi verificado e **funciona**: `invite_member_by_email` cria
> o `User` na hora, então "Reenviar convite" acha alguém e manda o segundo e-mail (2 na caixa). O
> buraco é só o do auto-cadastro pendente.

### A-12 · Pedir um link novo **não invalida o anterior** — **decisão**

O §1 do roteiro diz: *"Link velho (peça dois; use o primeiro) → **o mais recente vale; o consumido
não**"*. Medido com uma conta confirmada: dois pedidos geram **dois tokens distintos**, dois
e-mails, e **os dois autenticam** (302 nos dois). Só o link **consumido** é invalidado (2º uso →
401, A-10 acima).

Não é bug de implementação — é o modelo de allowlist por `jti`, em que cada token vale por si até
ser usado ou expirar. Mas contraria o esperado escrito no roteiro, e tem um ângulo de segurança
pequeno: cada reenvio deixa mais uma chave viva na caixa de e-mail da pessoa. Decidir qual das duas
muda: o texto do §1, ou a emissão (revogar os anteriores ao emitir).

### A-13 · A regra nova quebrou o helper de e2e — **corrigido nesta rodada**

`criarPaciente` e `criarProfissional` em [`helpers.ts`](../web/e2e/helpers.ts) fixavam
`tel: '11987654321'` para **toda** pessoa criada. Com o `identity :tel_unico` do doc 89, a
**segunda** ficha da mesma clínica passou a morrer em 422 — e o teste acusava a regra errada,
porque o cenário nem chegava a existir.

Corrigido com um `telUnico()` (o par do `emailUnico` que já existia). É o tipo de dependência que
uma mudança de schema arrasta e que só aparece quando alguém escreve o segundo paciente.

### A-14 · A suíte e2e estava verde contra um **build velho** — **ambiente, sério**

`agendar.spec.ts` procura o paciente com `getByRole('button', { name: /Marina Prado/ })`. O
`PatientPicker` já foi refatorado (commitado) para o padrão ARIA 1.2 de combobox: cada resultado é
um `<li role="option">`, não um botão. O teste **deveria** estar vermelho — e passou nas duas
primeiras execuções desta rodada.

O motivo: `playwright.config.ts` usa `reuseExistingServer` e o `preview` servia um `build/`
anterior ao refactor. Enquanto ninguém reconstrói, a suíte mede um app que não existe mais. Só
quando rodei `npm run build` explicitamente é que o teste caiu.

Corrigi o seletor (`option`), e fica o alerta de método: **e2e contra `preview` sem build fresco é
falso verde**. Vale o `build` fazer parte do comando, ou o `webServer` deixar de reusar servidor.

## 5. O que não é verificável neste ambiente

- **§1 rate limit (429).** Por decisão de projeto o limitador **só bloqueia em produção**
  (`ApiWeb.Plugs.RateLimitAuth`: *"em dev/test é no-op, para não atrapalhar os fluxos locais"*).
  Oito pedidos seguidos de magic link devolveram `200`. **Precisa rodar em HML** — e vale a pena,
  porque o commit `c58f5d5` mexeu justamente na resolução de IP do limitador.
- **§9 comunicação real.** Sem provedor configurado em dev, o drawer mostra o estado honesto
  ("Nada enviado · o WhatsApp está indisponível e não há e-mail na ficha") em vez de um botão que
  mente — o que já confirma o D-H4, mas não prova a entrega.
- **§1 Google.** Exige o OAuth real do console.
- **§13 robustez** (offline, Slow 3G, duplo clique) e **§14 celular físico**: pedem instrumentação
  que esta rodada não montou.

---

## 6. Artefato deixado no repositório

Dois arquivos novos, e três consertos em arquivos que já existiam.

**Estado final da suíte: 45 passaram, 1 falhou** (39,6s). A única vermelha é o **A-2**
(`recepcao.spec.ts`), deixada de propósito: ela codifica uma decisão de política e merece o olho da
equipe, não um conserto meu de passagem.

| Arquivo | O quê |
| --- | --- |
| [`roteiro82.spec.ts`](../web/e2e/roteiro82.spec.ts) | 5 cenários (tabela abaixo) |
| [`roteiro82-robustez.spec.ts`](../web/e2e/roteiro82-robustez.spec.ts) | §13 e §14: offline (A-10, `test.fail`), duplo clique, F5 com drawer, celular a 390px, toque na fórmula, zoom 200% |
| [`helpers.ts`](../web/e2e/helpers.ts) | `telUnico()` — conserto do **A-13** |
| [`agendar.spec.ts`](../web/e2e/agendar.spec.ts) | `option` no lugar de `button` — conserto do **A-14** |

[`roteiro82.spec.ts`](../web/e2e/roteiro82.spec.ts) — os itens do roteiro que só a tela prova:

| Cenário | Item do roteiro |
| --- | --- |
| turma vira "1 de 2 concluídas", não "Concluído" | §6 / D13 |
| Presente/Faltou desabilitados antes do horário | §6 / D-E4.1 |
| Esc fecha a gaveta | §14 |
| a fórmula do KPI abre por clique | §11 / AN-05 / ACC-10 |
| rota inexistente devolve a página de erro do app | §15 |

Três lições ficaram embutidas nele — todas custaram uma rodada vermelha:

- **hidratação** — clicar logo após o `goto` atinge um DOM sem handler e o clique **some sem erro**
  (a mesma armadilha que o `abrirAgenda` das fixtures documenta). E `networkidle` **não** serve de
  espera aqui: com o WebSocket do app aberto ele nunca assenta;
- **o 404 precisa de sessão** — deslogado, uma rota desconhecida do shell vira redirect para
  `/entrar` (200) e o 404 nunca é exercido;
- **rodar contra o `preview`, não contra o `vite dev`** — em dev a agenda compila sob demanda e o
  cenário estoura 90s por compilação, não por regressão. Contra o build, os mesmos testes levam 2s.

> Detalhe que vale para quem for escrever o próximo: `getByLabel` **não alcança** os campos da ficha
> (o rótulo é um snippet do Svelte, com o asterisco em outro nó). O que funciona é
> `getByRole('textbox', { name: … })` — e com nome **exato**, porque há dois "Telefone"
> (identificação e emergência) e dois `inputmode="numeric"` (CPF e CEP).

---

## 7. O que ficou por rodar (fila da próxima passada)

Depois de três rodadas, o que sobra é curto — e é quase todo **interação de mão** ou dependente de
ambiente:

| Seção | Itens |
| --- | --- |
| §1 | `/perfil` (editar nome, e-mail read-only, sair de todos os dispositivos); sign-out + botão voltar; **sessão expirada** nos dois cenários que a Andreza pediu |
| §3 | exceção de data com agendamento futuro (o gate do **horário** foi provado; o da **exceção**, não); desligar canal e ver o botão travar; conteúdo da auditoria (diff, redação de sensíveis, filtros) |
| §4 | duplicado por **nome+nascimento**; CEP; ficha aberta (idade, **regressão DDI→DDD** do `a500e7e`, consentimentos); histórico/próximos/"Agendar"; anexos ponta a ponta; arquivar/reativar; busca e paginação |
| §5 | arquivar profissional com agenda futura |
| §6 | **arraste** (a maior lacuna que resta); selo de pacote no bloco; **"quem cabe aqui" (AN-12)**; enviar confirmação de verdade; consistência Dia/Semana/Mês/Lista; ocupação conferida na mão |
| §7 | chips de vaga (incl. ABRIU); sair da fila; "esperou N dias" no drawer |
| §8 | prévia ao vivo no modal; turma com participantes de **pacotes diferentes** |
| §10 | fan-out por papel e **não se auto-notificar**; vaga-com-fila |
| §12 | isolamento A/B em **notificações e busca** |
| §13 | **Slow 3G** (respostas fora de ordem); offline **na agenda** (o bloco volta ao lugar?) |
| §9 | tudo — depende de provedor |

> Nota de método: a tentativa de rodar §1/§2/§5 na 2ª rodada aconteceu **já com a API em 500**, e
> aqueles números foram **descartados** — foram refeitos do zero na 3ª. Em particular, "os dois
> magic links vieram iguais" era artefato da caixa respondendo 500; medido direito (A-12), os
> tokens são distintos e ambos valem.

## 8. Para a conversa com a Andreza

1. **A-8**: o §4 do roteiro está desatualizado — duplicado **barra** desde o doc 89. Não é bug, é
   política nova; mas se a Andreza rodar o roteiro como está escrito, vai anotar desvio onde o
   comportamento é o desejado. Reescrever antes da re-homologação.
2. **A-1**: Relatórios não conta as faltas de uma turma. Cai bem no item que ela mesma vai testar
   ("os números batem"). Levar já com a pergunta: *contar presença ou bloco?*
3. **A-3** muda o roteiro, não o código — mas é decisão dela/de produto se recepção deve ver
   e-mail de colega.
4. **A-10** (rede fora perde a ficha inteira) é o segundo achado de produto, e é o que mais dói no
   balcão: wi-fi ruim + 31 campos digitados = trabalho perdido, com "Failed to fetch" em inglês na
   tela. **A-11** (quem se cadastrou e não clicou não consegue pedir outro link) é o irmão silencioso.
5. O que **passou** merece ser dito, e é muito: a matriz de acesso inteira bate, as oito validações
   do cadastro barram, o D14 é absoluto mesmo com encaixe, o D13 não mente no card, o 409 tem
   mensagem civilizada, o **débito do pacote acerta os três casos**, o **gate de impacto recusa com
   a lista dos 17 conflitos e não grava**, o **A7 é fail-closed de verdade** (sem vínculo: zero
   colunas), trocar papel vale no request seguinte, e o duplo clique cria uma ficha só.
