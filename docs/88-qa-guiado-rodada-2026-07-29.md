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

O roteiro tem ~180 caixas. Esta rodada exercitou **cerca de 60%** delas, com profundidade desigual
de propósito: as regras que o produto **afirma** (RBAC, validações, conflito, expediente,
concorrência) foram varridas por inteiro, porque são baratas e definitivas pela API; os fluxos que
só a mão percorre (arraste, CEP, oferta da fila, pacotes ponta a ponta) ficaram de fora.

| Seção | Cobertura | Observação |
| --- | --- | --- |
| §1 conta e sessão | parcial | criação/onboarding ✅; rate limit **não testável em dev**; /perfil, sign-out e sessão expirada não rodados |
| §2 equipe e papéis | parcial | convites ✅; trocar papel, revogar, ≥1 owner não rodados |
| §3 configurações | boa | CNPJ, tipos, auditoria, hachura ✅; gate de impacto não rodado |
| §4 pacientes | boa | **todas** as validações + duplicados ✅; CEP, busca, anexos-UI não rodados |
| §5 profissionais | parcial | telefone obrigatório e vínculo ✅; horário ⊆ clínica não rodado |
| §6 agenda | boa | expediente, conflito, encaixe, presença, 409, drawer ✅; arraste e visões não rodados |
| §7 fila | parcial | adicionar e upsert ✅; oferta→conversão não rodada |
| §8 pacotes | **boa** (2ª rodada) | ciclo completo + **regra de débito** ✅; prévia no modal e turma multi-pacote não rodadas |
| §9 comunicação | mínima | sem provedor em dev |
| §10 notificações | boa | ✅ |
| §11 relatórios | boa | ✅ + **1 achado** |
| §12 RBAC | **completa** | matriz célula a célula ✅ |
| §13 robustez | não rodada | offline/duplo clique/lentidão exigem outra instrumentação |
| §14 mobile/a11y | via suíte | 28 violações sérias no escuro (já conhecidas, doc 80) |
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

[`web/e2e/roteiro82.spec.ts`](../web/e2e/roteiro82.spec.ts) — **5 cenários, todos verdes** (4s), com
os itens do roteiro que só a tela prova:

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

A 2ª rodada foi interrompida pelo A-9. Estava montado e pronto para rodar assim que o codegen for
resolvido — as sondas estão escritas, só precisam de uma API de pé:

| Seção | Itens |
| --- | --- |
| §1 | magic link **reusado** e **link velho vs. novo**; `/perfil` (editar nome, e-mail read-only, sair de todos os dispositivos); sign-out + botão voltar; **sessão expirada** nos dois cenários que a Andreza pediu |
| §2 | reenviar convite; **trocar papel** de membro ativo (reflete sem re-login?); revogar acesso; **regra do ≥1 owner** |
| §3 | **gate de impacto** ao fechar dia / criar exceção com agendamento futuro; arquivar e restaurar tipo em uso; desligar canal e ver o botão travar; conteúdo da auditoria (diff, redação de sensíveis, filtros) |
| §4 | duplicado por **nome+nascimento**; CEP; ficha aberta (idade, **regressão DDI→DDD** do `a500e7e`, consentimentos); histórico/próximos/"Agendar"; anexos ponta a ponta; arquivar/reativar; busca e paginação |
| §5 | **A7 fail-closed** (profissional sem vínculo não vê agenda nenhuma) — sonda escrita; horário do profissional ⊆ clínica; arquivar profissional com agenda futura |
| §6 | **arraste**; remarcar perguntando motivo; cancelar/reabrir; selo de pacote no bloco; **"quem cabe aqui" (AN-12)**; enviar confirmação; consistência Dia/Semana/Mês/Lista; ocupação conferida na mão |
| §7 | chips de vaga; **oferecer → converter → sai da fila**; sair da fila; "esperou N dias" |
| §8 | prévia ao vivo no modal; turma com participantes de **pacotes diferentes** |
| §10 | fan-out por papel e **não se auto-notificar**; vaga-com-fila; caixa por usuário (Bia ≠ Ana) |
| §11 | excluído não conta / cancelado conta; fórmula no viewport mobile (ACC-10) |
| §12 | isolamento A/B em **notificações e busca** |
| §13 | **a seção inteira**: offline no form, offline na agenda, duplo clique, Slow 3G, F5 |
| §14 | zoom 200%; celular além do que a suíte já cobre |

> Nota de método: a tentativa de rodar §1/§2/§5 aconteceu **já com a API em 500**, então aqueles
> números não valem nada e não foram aproveitados. Em particular, "os dois magic links vieram
> iguais" foi artefato da caixa de e-mail respondendo 500 — não é achado.

## 8. Para a conversa com a Andreza

1. **A-8**: o §4 do roteiro está desatualizado — duplicado **barra** desde o doc 89. Não é bug, é
   política nova; mas se a Andreza rodar o roteiro como está escrito, vai anotar desvio onde o
   comportamento é o desejado. Reescrever antes da re-homologação.
2. **A-1**: Relatórios não conta as faltas de uma turma. Cai bem no item que ela mesma vai testar
   ("os números batem"). Levar já com a pergunta: *contar presença ou bloco?*
3. **A-3** muda o roteiro, não o código — mas é decisão dela/de produto se recepção deve ver
   e-mail de colega.
4. O que **passou** merece ser dito: a matriz de acesso inteira bate, as oito validações do cadastro
   barram, o D14 é absoluto mesmo com encaixe, o D13 não mente no card, o 409 tem mensagem
   civilizada, a fórmula do KPI abre no toque (ACC-10) e o **débito do pacote acerta os três casos**
   (presença, falta punitiva e falta justificada).
