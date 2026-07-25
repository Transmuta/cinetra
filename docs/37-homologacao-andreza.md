# 37 — Homologação funcional e UX (relatório da Andreza): triagem contra o código

Triagem item a item do **Relatório de Homologação Funcional e UX — Plataforma Moving v1.0**
(julho/2026, Andreza Andrade, com apoio de IA), recebido como PDF. O relatório nasceu de um vídeo
de navegação (~12min43s) + do HTML da "Jornada de Aprendizagem" + de observações da usuária.

Este documento **não repete** o relatório: ele registra os 29 achados, confere cada um contra o
que está de fato no repositório (com arquivo e linha) e separa três coisas que o PDF mistura:

1. o que **já existe** e o relatório não viu (falso positivo — é problema de *descoberta*, não de código);
2. o que **falta mesmo** e vira backlog;
3. o que **conflita** com decisão nossa já registrada em ADR/doc — e portanto é decisão humana, não tarefa.

A lista de conflitos está em [§6](#6-divergências-que-exigem-decisão-humana); as **decisões
tomadas sobre cada um** (2026-07-23) estão em [§8](#8-decisões-tomadas-2026-07-23), que é a seção
normativa — e a ordem de execução resultante em [§7](#7-sequenciamento-ordem-de-execução-desta-leva).

Relacionados: [`35-plano-execucao-backlog.md`](35-plano-execucao-backlog.md) (o backlog técnico já
priorizado), [`34-qa-exploratorio-playwright.md`](34-qa-exploratorio-playwright.md) (nosso QA
exploratório), [`30-decisoes-pendentes-agenda.md`](30-decisoes-pendentes-agenda.md),
[`12-divergencias-interface-vs-regras.md`](12-divergencias-interface-vs-regras.md).

---

## 1. Como ler este relatório (e o que ele mediu)

**O que ele é:** homologação de *usabilidade e regra de negócio*, feita por quem vai operar a
clínica, sobre uma navegação gravada. É o tipo de achado que nossos testes automatizados não
produzem — "eu não entendo o que essa cor quer dizer" não quebra build nenhum. Vale muito.

**O que ele não é:** o próprio documento reconhece o limite (p. 3) — não cobre carga, segurança,
integração, banco ou concorrência. Nessas frentes a nossa evidência é melhor que a dele
(`docs/13`, `18`, `21`, `23`, `24`, `26`–`29`, `32`, `35`).

**Três vieses de origem que mudam a leitura de vários itens:**

- **Fonte parcialmente errada.** Boa parte dos achados descreve a *Jornada de Aprendizagem* (HTML)
  e o **protótipo** `interface/Movimento.dc.html`, não o app construído. Isso explica por que
  módulos que **não existem** aparecem como "pontos fortes" (Pacotes) e por que a marca aparece
  como "Movimento" (é o nome do arquivo do protótipo; a UI já é **Cinetra**).
- **Ausência ≠ inexistência.** Vários "não foi observado" são de fato "não foi encontrado na
  navegação": a trilha de auditoria (HOM-016) existe, tem tela e API. O achado permanece válido —
  como problema de **descoberta**, o que é uma correção diferente da que ele recomenda.
- **Numeração.** O PDF anuncia **30 itens**, mas **HOM-007 não existe** no corpo do documento
  (p. 4 salta de HOM-006 para HOM-008). São **29** achados. Vale pedir o item faltante junto com a
  planilha editável citada na p. 5, que não veio.

---

## 2. Placar

| Situação | Qtde | IDs |
| --- | ---: | --- |
| **Já está feito** (falso positivo / problema de descoberta) | 6 | 010, 013, 016, 020¹, 026, 027¹ |
| **Parcial** — existe base, falta a parte que ele pede | 8 | 002, 006, 011, 012, 014, 017, 021, 024 |
| **Falta mesmo** — vira backlog | 9 | 003, 004, 005, 009, 019, 022, 023, 025, 028 |
| **Conflita com decisão nossa** — precisa de decisão humana | 4 | 001, 008, 015, 029 |
| **Não é código** — é processo/rotina de teste | 2 | 030, roteiro §06 |

¹ Feito **onde o módulo existe**; a parte de Pacotes não se aplica (o módulo não foi construído).

**O de maior valor no relatório inteiro:** HOM-002 → HOM-006 (a gramática visual do card da
agenda). É a crítica mais bem fundamentada, atinge a tela onde a operação vive, e nós de fato
herdamos do protótipo uma sobreposição de sinais sem legenda. **Recomendo tratar esse bloco como
uma fatia única**, e não como cinco tickets soltos.

---

## 3. Achados item a item

Formato: **Achado** (dele) · **Recomendação** (dele) · **Estado real** (nosso, com evidência) ·
**Veredito**.

### 3.1 Identidade e consistência

#### HOM-001 — marca "Movimento"
- **Achado:** a interface usa nome e marca fictícia "Movimento".
- **Recomendação:** substituir tudo pela marca oficial **Moving**.
- **Estado real:** a UI **já não diz "Movimento"**. O wordmark é Cinetra
  ([`Logo.svelte:14`](../web/src/lib/components/Logo.svelte#L14)), o título do shell é Cinetra
  ([`Topbar.svelte:16`](../web/src/lib/components/shell/Topbar.svelte#L16)), e `grep Movimento`
  em `web/src/**/*.svelte` não retorna nada visível ao usuário. O nome sobrevive só em
  **comentário de código** apontando o protótipo (`interface/Movimento.dc.html`) e no
  `mailer`/textos de e-mail, que precisam de conferência.
- **Veredito:** ⚠️ **conflito de marca a três vias** — protótipo *Movimento*, produto *Cinetra*,
  relatório pede *Moving*. Ver [D-H1](#d-h1--qual-é-a-marca-moving-cinetra-ou-movimento).

#### HOM-026 — mensagens de sucesso/erro/confirmação padronizadas
- **Estado real:** feito. Toast único (`$lib/toast.svelte.ts`) e `ConfirmDialog` fiel ao protótipo
  desde a fatia de Membros (`docs/19`), usados em todas as ações destrutivas.
- **Falta:** o **"desfazer quando seguro"** que ele sugere não existe em lugar nenhum.
- **Veredito:** ✅ feito · ⬜ *undo* é item novo (baixo valor: quase toda ação nossa já é
  reversível por arquivar/reabrir).

#### HOM-027 — glossário único de termos
- **Estado real:** feito de facto — os rótulos saem de fontes únicas (`STATUS_META` em
  [`agenda.ts`](../web/src/lib/agenda.ts), enums do backend
  [`appointment_status.ex`](../api/lib/api/scheduling/appointment_status.ex),
  [`role.ex`](../api/lib/api/accounts/role.ex)), então a plataforma é internamente consistente.
- **Falta:** o glossário **escrito** para humanos (e a Jornada usa termos próprios).
- **Veredito:** ✅ no código · ⬜ documento de glossário não existe.

#### HOM-028 — responsividade, teclado, contraste, zoom 200%
- **Estado real:** o shell tem versão mobile (o `Sidebar` renderiza duas vezes, desktop e mobile),
  mas **nunca rodamos** auditoria de acessibilidade: nem teclado, nem foco, nem contraste, nem
  zoom. O `docs/34` (QA exploratório) foi só desktop.
- **Veredito:** ⬜ **falta de verdade.** É o achado mais barato de alto retorno depois do bloco da
  agenda — e o único do relatório que nossa suíte automatizada poderia passar a cobrir (axe).

### 3.2 Agenda — o bloco crítico

#### HOM-002 — cor sem legenda, cor representando mais de uma dimensão
- **Estado real:** ele acertou o diagnóstico. Hoje o **mesmo retângulo** é pintado por três regras
  concorrentes, com precedência herdada do protótipo:
  `AÇÃO > conflito > status` ([`AppointmentBlock.svelte:50`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L50)).
  Some-se a isso a **bolinha do profissional** e a **tarja teal do pacote**, e a cor carrega
  quatro dimensões. **Não existe legenda em lugar nenhum** (`grep -i legenda` no `web/` = zero).
- **Veredito:** 🟡 parcial — o mapa de status já é fonte única e coerente (`STATUS_META`), o que
  torna a correção barata: sobra criar a legenda e desempilhar as três regras.

#### HOM-003 — etiqueta "AÇÃO" genérica
- **Estado real:** literal. O badge é a string `AÇÃO`
  ([`AppointmentBlock.svelte:129`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L129)),
  disparado por `action` = *bloco já terminou e ninguém resolveu* (RN-58). É **uma** condição só,
  o que é uma boa notícia: dá para trocar por verbo sem inventar taxonomia.
- **Veredito:** ⬜ falta · conserto pequeno (o verbo correto hoje é **"Registrar status"**).

#### HOM-004 — ícones em excesso, sem rótulo
- **Estado real:** confere. Um bloco pode exibir simultaneamente: bolinha do profissional, ícone de
  conflito, badge AÇÃO, ícone de pacote, ícone do tipo de atendimento, ponto pulsante de
  "em atendimento" e badge ENCAIXE — **sete sinais** na mesma linha de cabeçalho
  ([`AppointmentBlock.svelte:118-160`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L118-L160)).
  Só o de conflito tem `title`.
- **Veredito:** ⬜ falta.

#### HOM-005 — bolinhas/contadores ambíguos
- **Estado real:** o contador de turma **já é explícito na forma** `Tipo · 2/4`
  ([`AppointmentBlock.svelte:66`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L62)),
  mas sem a palavra "vagas". A parte de **sessões de pacote** ("Sessão 2 de 4") não existe porque
  **pacotes não existem** (ver [§5](#5-módulos-que-o-relatório-descreve-e-que-não-existem)).
- **Veredito:** ⬜ falta (parte turma) · ➖ não se aplica (parte pacote).

#### HOM-006 — hierarquia do card carregada
- **Estado real:** a ordem que ele pede (1 horário+status, 2 paciente, 3 serviço, 4 pacote/vagas,
  5 secundárias) é **quase** a que temos; o que quebra a leitura não é a ordem, é a densidade de
  sinais da linha 1 (HOM-004) e o fato de o card degradar por altura (abaixo de 30px some o nome).
- **Veredito:** 🟡 parcial — resolve junto com 002/004.

#### HOM-008 — Encaixe permite ignorar conflito
- **Estado real:** encaixe **já é restrito por perfil** — a policy A9 exige `owner`, `admin` ou
  `recepcao`, e existe justamente porque `encaixe = true` desliga a exclusion constraint
  ([`appointment.ex:400-411`](../api/lib/api/scheduling/appointment.ex#L400-L411)). O evento **é
  auditável** (AshPaperTrail via `TrailMixin`). O que **não** existe é **justificativa obrigatória**.
- **Veredito:** ⚠️ **parcialmente feito, e a recomendação conflita com decisão nossa** — para ele,
  recepção *não* deveria poder encaixar ("perfil comum não autoriza", roteiro §06); para nós,
  recepção é exatamente quem encaixa (A9/A8: "recepção é quem agenda").
  Ver [D-H2](#d-h2--recepção-pode-encaixar).

### 3.3 Sessões, status e turmas

#### HOM-009 — falta/cancelamento/remarcação sem causa estruturada
- **Estado real:** o mais próximo que temos é `cancel_reason`, **texto livre e opcional** (D4)
  ([`appointment.ex:308-318`](../api/lib/api/scheduling/appointment.ex#L308-L318)); falta tem
  apenas o booleano `falta_justificada`, sem categoria nem observação; **remarcação não registra
  motivo algum**. Quem/quando/valor-anterior a trilha já guarda.
- **Veredito:** ⬜ **falta de verdade, e é o achado de negócio mais forte do relatório.** Sem
  categoria não há como responder "por que a clínica perde sessão", que é o KPI que a dona quer.
  Conflita com D4 (justificativa opcional) — ver [D-H3](#d-h3--motivo-categorizado-vira-obrigatório).

#### HOM-010 — status da turma interpretado como único
- **Estado real:** **já é individual.** `Attendance` tem status próprio por participante
  (`:prevista | :concluida | :faltou | :cancelada`,
  [`attendance_status.ex`](../api/lib/api/scheduling/attendance_status.ex)) e o moduledoc registra
  isso como a correção do GAP-07 do protótipo. As ações do bloco (`mark_completed`/`mark_missed`)
  são o "atalho em lote" que ele pede, via `CascadeToAttendances`.
- **Veredito:** ✅ **feito** — falso positivo. Se ficou ambíguo na tela, o ajuste é de UI (deixar
  visível que a presença é por participante), não de modelo.

#### HOM-025 — rastreabilidade da confirmação por WhatsApp
- **Estado real:** ⚠️ **pior do que o relatório supõe.** O botão de WhatsApp no drawer **não envia
  nada**: dispara um toast de mentira
  ([`AppointmentDrawer.svelte:306`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L306)),
  herdado do protótipo. Não há canal, nem registro, nem integração.
- **Veredito:** ⬜ falta · **e é risco de piloto**: a recepção vai clicar, ver "Confirmação enviada"
  e acreditar. Ver [D-H4](#d-h4--o-botão-de-whatsapp-que-mente).

### 3.4 Pacientes e dados

#### HOM-011 — salvar cadastro sem campos mínimos
- **Estado real:** só `nome` é obrigatório
  ([`patient.ex`](../api/lib/api/records/patient.ex), atributos), **por decisão** — o rodapé do
  formulário do protótipo diz "nenhum campo é obrigatório, salve e complete depois". Não existe
  estado de *rascunho*, nem bloqueio de agendamento por ficha incompleta.
- **Veredito:** 🟡 parcial — a recomendação (rascunho + exigir telefone para agendar) é boa e
  **compatível** com nosso `ativo`, mas muda regra de produto. Ver [D-H5](#d-h5--ficha-mínima-para-agendar).

#### HOM-012 — sem validação visível de CPF/telefone/e-mail/nascimento
- **Estado real:** **máscara existe** (`maskCpf`, `maskTel`, `maskCep`, `maskMy` em
  [`masks.ts`](../web/src/lib/masks.ts)); **validação não** — o comentário do arquivo é explícito:
  "a máscara é só UX, a validação real é do backend" — e no backend CPF é `:string` com
  `max_length: 20`, sem dígito verificador. E-mail e nascimento idem.
- **Veredito:** 🟡 parcial — falta o verificador. Nota: **temos** o validador de CNPJ alfanumérico
  ([`cnpj.ts`](../web/src/lib/cnpj.ts)), então o padrão a seguir já existe no repo.

#### HOM-013 — duplicidade sem alerta forte
- **Estado real:** **existe** — o formulário consulta `/api/patients/lookup` quando o CPF fica
  completo e mostra "Possível duplicado"
  ([`PatientForm.svelte.test.ts:68-91`](../web/src/lib/components/patients/PatientForm.svelte.test.ts#L68-L91)).
  Por decisão (docs/24), **avisa e não barra**, e não há `identity` única.
- **Veredito:** ✅ feito para CPF · ⬜ falta a heurística por **telefone** e por
  **nome + nascimento** que ele pede.

#### HOM-029 — consentimento não governa comunicação nem acesso
- **Estado real:** consentimento são **dois booleanos** (`lgpd`, `comunicacao`) por decisão
  explícita (D16/D19) — não o recurso `Consent` versionado, que é v2. Nada consome `comunicacao`
  hoje (não há envio). Campos sensíveis (`medico`, `crm`) **não têm field policy**, também por
  decisão (D17, opção A recusada).
- **Veredito:** ⚠️ **conflita com duas decisões nossas.** Ver [D-H6](#d-h6--lgpd-consentimento-versionado-e-campo-sensível-por-perfil).

### 3.5 Profissionais, equipe e acessos

#### HOM-014 — só o nome é obrigatório no profissional
- **Estado real:** confere — `nome` e pouco mais são `allow_nil?: false`
  ([`professional.ex:169,218`](../api/lib/api/directory/professional.ex#L167)). Não há gate de
  "completo para ativar", e o profissional aparece na agenda de qualquer jeito.
- **Veredito:** 🟡 parcial — mesmo desenho de solução do HOM-011 (usar `ativo` como o gate).

#### HOM-015 — perfil genérico "Membro"
- **Estado real:** ⚠️ **já corrigido, e melhor do que ele pede.** Os papéis são
  `owner · admin · profissional · recepcao`
  ([`role.ex:7`](../api/lib/api/accounts/role.ex#L7)) — o `membro` do protótipo virou `recepcao`
  há muito tempo (ADR-016). O que ele viu foi o protótipo/Jornada.
- **Veredito:** ✅ feito · ⬜ falta a **matriz de acesso documentada** (existe espalhada nas
  policies, não numa tabela para a clínica ler). O nome `owner` em inglês numa UI em português é
  a única aspereza real. Ver [D-H7](#d-h7--nomes-dos-papéis-na-ui).

#### HOM-016 — sem trilha de auditoria visível
- **Estado real:** ⚠️ **falso positivo forte.** Existe tela (`/configuracoes/auditoria`), API
  (`GET /api/audit`), diff campo a campo e AshPaperTrail sobre `Appointment` e `Attendance`
  (`docs/32`, [`trail_mixin.ex`](../api/lib/api/scheduling/trail_mixin.ex)). É restrita a
  owner/admin — provavelmente por isso não apareceu na navegação.
- **Veredito:** ✅ feito. **Mas o achado tem valor invertido:** se quem vai operar não achou a
  trilha, ela está enterrada. E a cobertura **não** inclui cadastros (paciente/profissional),
  só agenda — a parte "e cadastro" da recomendação é real.

### 3.6 Fila de espera e pacotes

#### HOM-017 — ciclo de oferta pobre
- **Estado real:** a fila tem prioridade, janela, profissionais preferidos, regras de
  disponibilidade e o **motor de vagas em lote** (`slots_by_entry`, `GET /waitlist/slots`), e
  **converter já retira da fila** (`POST /:id/convert`,
  [`waitlist.ts:125`](../web/src/lib/server/waitlist.ts#L125)). O que **não existe**: `oferecido_em`,
  canal, resposta, validade da oferta, motivo de recusa.
- **Veredito:** 🟡 parcial — a metade que ele pede primeiro (retirar ao converter) está pronta;
  o registro da oferta é backlog. **Achado extra nosso:** `dequeue` é um `destroy`
  ([`waitlist_entry.ex:95`](../api/lib/api/waitlist/waitlist_entry.ex#L112)) — sair da fila
  **apaga a linha**, então não sobra histórico nem para relatório. Isso contraria nosso próprio
  padrão de "arquivar, não apagar".

#### HOM-018 — vaga cancelada não sugere pacientes da fila
- **Estado real:** o **backend está pronto** (`SlotFinder` + notificação "vaga-com-fila" do
  `docs/31`); a UI de "quem cabe aqui" foi **deliberadamente adiada** (memória da fatia E5).
- **Veredito:** 🟡 parcial — é a fatia mais barata do relatório inteiro, porque só falta tela.

#### HOM-019 / HOM-020 — conflitos de recorrência e progresso do pacote
- **Estado real:** ➖ **o módulo Pacotes não existe.** Não há rota `/pacotes`, não há recurso
  `Package`; o que existe são **ganchos** (`package_id` sem FK, `pkg_hold`) plantados para a
  Fatia 3 ([`appointment.ex:466-468`](../api/lib/api/scheduling/appointment.ex#L466-L468)) e uma
  tarja teal no card. Recorrência idem.
- **Veredito:** ➖ não se aplica ao construído. Ver [§5](#5-módulos-que-o-relatório-descreve-e-que-não-existem).

### 3.7 Relatórios e configurações

#### HOM-021 — KPI sem fórmula na tela
- **Estado real:** os KPIs existem (volume, concluídos, faltas, cancelados, ocupação, desempenho
  por profissional) e a **definição de ocupação é canônica e não-óbvia** — minutos ocupados ÷
  minutos de expediente, e não "9 slots" (`docs/33`). Exatamente o tipo de regra que **precisa**
  estar na tela e não está: `title=` só aparece em dois pontos do gráfico
  ([`relatorios/+page.svelte:154,312`](../web/src/routes/(app)/relatorios/+page.svelte#L154)).
- **Veredito:** 🟡 parcial — conserto barato e de alto valor (a dona vai contestar o número).

#### HOM-022 — sem comparação com período anterior nem meta
- **Veredito:** ⬜ falta. Está no plano dele como "Evolução"; concordo.

#### HOM-023 — indicadores sem drill-down nem exportação
- **Veredito:** ⬜ falta. Idem — evolução.

#### HOM-024 — mudança em horário/duração/exceção impacta toda a agenda
- **Estado real:** **preferir inativar a excluir já é padrão do repo** (tipos, profissionais e
  pacientes arquivam), e a alteração fica na trilha. O que **não** existe é a prévia de impacto:
  `grep futureConflicts` no `web/` e no `api/` = **zero** — o motor de impacto retroativo do
  protótipo (ADR-001 o cita como uma das quatro regras reais) **nunca foi portado**, e foi
  explicitamente adiado na fatia de Profissionais.
- **Veredito:** 🟡 parcial — e este é o item onde **ele e o protótipo concordam contra nós**.
  É o mais caro do relatório.

### 3.8 Operação

#### HOM-030 — faltam testes negativos e de concorrência
- **Estado real:** melhor do que ele supõe. Concorrência tem defesa **de banco** (exclusion
  constraint GiST) e **locking otimista** (`version` + `BumpVersion`); temos ~740 testes no
  backend com gate de cobertura, `docs/34` cobriu caminhos negativos, e as fatias passaram por
  auditoria de segurança (`docs/13/18/21/23/26–29/32`). O que **não** foi feito: teste de
  **sessão expirada** e de **rede instável** pela ótica do usuário, e o roteiro dele de dois
  usuários no mesmo horário nunca foi executado *pela UI*.
- **Veredito:** 🟡 parcial — vale executar o roteiro §06 dele como QA guiado (é barato) e
  registrar o resultado, mesmo já tendo a defesa no banco.

---

## 4. O roteiro de reteste dele × o que já provamos

| Cenário (PDF §06) | Já coberto? | Onde / o que falta |
| --- | --- | --- |
| Cadastro de paciente (rascunho, duplicado, formatos) | 🟡 | duplicado por CPF ✅; rascunho e validação de formato ⬜ |
| Cadastro de profissional (incompleto, ativar/inativar) | 🟡 | arquivar ✅; gate de "completo para ativar" ⬜ |
| Agendamento (conflitos) | ✅ | exclusion constraint no banco; `docs/26` |
| Encaixe (perfil comum × admin) | ⚠️ | policy A9 existe, mas **a regra que ele testa é outra** (D-H2) |
| Status (confirmar/concluir/faltar/cancelar/remarcar) | 🟡 | ciclo completo ✅ (`docs/28`); **motivo categorizado** ⬜ |
| Pilates em grupo (presença por participante) | ✅ | `Attendance` por paciente |
| Fila de espera (oferta → resposta → converte) | 🟡 | converter+sair ✅; registro da oferta ⬜ |
| Pacote (recorrência, conflitos) | ➖ | módulo não existe |
| Acessos (3 perfis) | ✅ | 4 papéis + policies auditadas |
| Relatórios (números batem, definição de cálculo) | 🟡 | números ✅; definição na tela ⬜ |
| Concorrência (dois usuários, mesmo horário) | ✅ no banco · ⬜ pela UI | GiST + `version`; falta o teste guiado |
| Responsividade (desktop/tablet/celular) | ⬜ | nunca medido |

---

## 5. Módulos que o relatório descreve e que não existem

O PDF lista como **ponto forte** (p. 2) "Pacotes e recorrência conectados à agenda e ao histórico
do paciente". **Não existem.** Não há rota, recurso, nem ação — apenas ganchos de coluna
(`package_id`, `pkg_hold`) e uma tarja no card, plantados para uma Fatia 3 ainda não construída.
Pelo mesmo motivo, a ficha do paciente **oculta** as abas Pacotes/Histórico/Anexos.

Consequências práticas:

- **HOM-005 (parte pacote), HOM-019 e HOM-020 não têm alvo** — são requisitos para um módulo
  futuro, e devem entrar como especificação da Fatia 3, não como correção.
- **O parecer executivo está calibrado para um produto maior do que o que existe.** "Boa
  maturidade funcional para piloto" foi dito olhando um escopo que inclui pacotes. Se o piloto
  real da clínica depende de vender pacote de 10 sessões, **isso, e não a cor do card, é o
  bloqueador do piloto** — e o relatório não o menciona porque acreditou que já estava pronto.

O mesmo vale, em menor grau, para **confirmação por WhatsApp** (HOM-025): descrita como "parte da
operação", é hoje um botão decorativo.

---

## 6. Divergências que exigem decisão humana

Estas não são tarefas: são escolhas onde o relatório **contraria** uma decisão já registrada
nossa. Cada uma precisa de "mantém" ou "muda por ADR novo".

> **Todas as doze foram decididas em 2026-07-23** — o que ficou valendo está em
> [§8](#8-decisões-tomadas-2026-07-23), que é a seção normativa. As subseções abaixo ficam como o
> registro do dilema (contexto e alternativas), não como pergunta em aberto.

### D-H1 — Qual é a marca: Moving, Cinetra ou Movimento?
O relatório manda padronizar em **Moving**. O produto foi rebrandeado para **Cinetra** (logo,
wordmark, shell, e-mails de auth). **Movimento** é só o nome do protótipo. São três nomes e o
relatório desconhece o segundo. Decidir o nome oficial **antes** de qualquer varredura de texto —
e depois varrer também os textos de e-mail, que a UI já não cobre.

### D-H2 — Recepção pode encaixar?
Nós decidimos que **sim** (A8/A9: "recepção é quem agenda"; encaixe liberado para
owner/admin/recepcao). O roteiro dele testa o oposto: "perfil comum não autoriza; administrador
informa motivo". Se recepção não puder encaixar, o dia a dia da secretaria trava — a operação real
é ela que encaixa. **Recomendação:** manter recepção com permissão e atender o espírito do achado
por **justificativa obrigatória + trilha**, não por remoção de permissão.

### D-H3 — Motivo categorizado vira obrigatório?
Nossa D4 diz **justificativa opcional**; hoje `cancel_reason` é texto livre e falta só tem um
booleano. Ele quer taxonomia obrigatória (falta justificada × não justificada × cancelamento pela
clínica × pelo paciente) para alimentar relatório. Concordo com o valor gerencial, **mas é uma
mudança de enum em tabela com dado** e obriga a UI a pedir motivo em toda ação crítica. Decidir:
(a) obrigatório em todas; (b) obrigatório só em falta e cancelamento; (c) manter opcional.

### D-H4 — O botão de WhatsApp que mente
Hoje ele mostra "Confirmação enviada por WhatsApp" sem enviar nada. Para o piloto há três saídas:
**(a)** remover o botão; **(b)** trocar o texto para algo honesto ("Abrir conversa"/copiar
mensagem) e registrar quem clicou; **(c)** integrar de verdade (caro, exige provider e
consentimento — casa com D-H6). **Recomendo (b) antes do piloto**; (a) se não houver tempo.
Deixar como está é a única opção que não recomendo.

### D-H5 — Ficha mínima para agendar
Hoje só `nome` é obrigatório, e isso foi escolha (velocidade do balcão: a recepção cadastra com o
paciente na frente). Ele quer nome + telefone para poder agendar, com rascunho antes disso. Vale
para paciente (HOM-011) e profissional (HOM-014). Decidir **qual é o mínimo** — e note que a
clínica pode preferir a velocidade atual.

### D-H6 — LGPD: consentimento versionado e campo sensível por perfil
Ele pede (i) consentimento governando o envio de comunicação, (ii) campos sensíveis por perfil,
(iii) histórico da alteração de consentimento. Nós decidimos o contrário nos três: dois booleanos
em vez de `Consent` versionado (D16/D19), **sem field policy** em médico/CRM (D17 recusado), e
prontuário/Art. 11 adiado para v2. O item (iii) é o mais barato (a trilha já guarda mudança de
campo — falta estender o paper trail a `Patient`); o (i) só existe quando houver envio (D-H4);
o (ii) reabre o D17.

### D-H7 — Nomes dos papéis na UI
Os quatro papéis já são de negócio, mas `owner` é inglês numa interface em português, e ele
sugere rótulos ("Administrador/Gestão", "Recepção/Secretaria", "Fisioterapeuta"). Barato, mas
tocar em `role` mexe em enum, policies e textos. Decidir se muda **o rótulo na UI** (recomendado)
ou **o valor no banco** (não recomendado).

### D-H8 — Prévia de impacto em mudança estrutural (HOM-024)
O motor `futureConflicts` do protótipo nunca foi portado. Ele pede "informar quantos eventos serão
afetados antes de salvar". É o item **mais caro** do relatório: exige recalcular disponibilidade
contra a agenda futura em tempo de formulário. Decidir se entra antes do piloto (ele classifica
como "Antes do piloto") ou depois — dado que a alternativa barata é **avisar sem contar**
("mudanças de horário não alteram agendamentos já marcados; confira a agenda").

### D-H9 — Pacotes: o piloto depende deles?
O relatório acha que existem. Se a clínica vende pacote/recorrência, **o piloto não roda sem a
Fatia 3**, e essa é uma decisão de escopo maior do que todos os outros itens somados.

### D-H10 — Sair da fila apaga a linha
Achado nosso, não dele: `dequeue` é `destroy`. Contraria nosso padrão de arquivar e impede
qualquer relatório de fila ("quantos desistiram?"). Decidir se vira `ativo: false` — barato agora,
caro depois que houver volume.

### D-H11 — O que fazer com os "falsos positivos"
HOM-010, HOM-013, HOM-015 e HOM-016 estão feitos, mas **não foram encontrados por quem vai
operar**. Tratar como bug de descoberta (tornar visível) ou como não-achado? Recomendo tratar:
uma funcionalidade que a recepção não acha é uma funcionalidade que não existe para ela.

### D-H12 — Entregáveis que não vieram
O PDF cita uma **planilha de backlog editável** (p. 5 e p. 10) que não acompanhou o documento, e
o **HOM-007 não existe** no corpo. Pedir os dois antes de fechar a priorização.

---

## 7. Sequenciamento (ordem de execução desta leva)

Ordem por **valor ÷ custo**, já refletindo as decisões da [§8](#8-decisões-tomadas-2026-07-23):

1. **Gramática visual da agenda** (HOM-002/003/004/005/006) — uma fatia só. É a crítica mais forte
   e mais barata: `STATUS_META` já é fonte única; o trabalho é desempilhar as três regras de cor,
   trocar `AÇÃO` por verbo, cortar ícones e escrever a legenda.
2. **Honestidade do botão de confirmação** (D-H4) — minutos, e evita erro operacional no piloto.
3. **Motivo em todas as ações críticas, sempre opcional** (D-H3) — o achado de negócio com maior
   retorno, e o desenho mais barato possível dele.
4. **Telefone obrigatório em paciente e profissional** (D-H5).
5. **Definição de KPI na tela** (HOM-021) — tooltip com a fórmula de ocupação; evita contestação
   do número.
6. **Rótulos dos papéis na UI** (D-H7) — troca de texto.
7. **Lista de conflitos na mudança de expediente** (D-H8) — resolver um a um, sem ação em massa.
8. **`veio_da_fila` + `dias_na_fila` no agendamento** (D-H10) — duas colunas.
9. **Acessibilidade e responsividade** (HOM-028) — pode virar gate automatizado.
10. **Descoberta da auditoria + trilha em cadastros** (HOM-016) e os demais falsos positivos (D-H11).
11. **Registro da oferta na fila + UI "quem cabe aqui"** (HOM-017/018) — backend já pronto.

**Fora desta leva, por decisão:** WhatsApp de verdade (depois dos ajustes), Pacotes (D-H9), LGPD
versionado (D-H6), comparativos/drill-down de relatório (HOM-022/023).

---

## 8. Decisões tomadas (2026-07-23)

Seção normativa: é isto que vale. Cada linha responde uma divergência da [§6](#6-divergências-que-exigem-decisão-humana).

### D-H1 ✅ A marca é **Cinetra** — mantém o que foi desenvolvido
O relatório pede "Moving"; fica **Cinetra**. Nada a mudar na UI. Sobra apenas **conferir os textos
de e-mail** (`Api.Accounts.Emails`), que o `grep` da interface não cobre, e responder ao relatório
que HOM-001 já está atendido por outra marca. Comentários de código que citam
`interface/Movimento.dc.html` **ficam** — são proveniência (ADR-001), não interface.

### D-H2 ✅ Recepção **continua podendo encaixar**
Mantida a policy A9 (`owner`/`admin`/`recepcao`). O espírito de HOM-008 é atendido pela via da
**justificativa + trilha** (D-H3), não pela remoção de permissão. Ao responder o relatório, marcar
o item do roteiro §06 ("perfil comum não autoriza") como **rejeitado com justificativa**: no balcão
real quem encaixa é a recepção.

### D-H3 ✅ Motivo **em todas as ações críticas, mas nunca obrigatório**
Mantida a D4 (opcional). O que muda é a **cobertura**: hoje só `cancel` tem campo de motivo — passa
a ter **falta, cancelamento e remarcação**, cada uma apresentando o campo na UI. Consequências:

- backend: campo de motivo em `mark_missed` e `reschedule` além do `cancel_reason` já existente;
- UI: o campo aparece sempre, com rótulo dizendo que é opcional — apresentar não é exigir;
- relatório: como o preenchimento é voluntário, o filtro por causa nasce **incompleto por
  construção**. Isso é aceito conscientemente; se a gestão quiser o número confiável, aí sim vira
  obrigatório (novo ADR).

Categoria fechada (lista de motivos) **não** entra agora — texto livre, como hoje.

### D-H4 ✅ Botão passa a ser honesto; WhatsApp de verdade fica para depois desta leva
O botão é o **"Enviar confirmação"** do rodapé do drawer do agendamento
([`AppointmentDrawer.svelte:300-311`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L300-L311)),
visível só em bloco aberto. Hoje dispara `onToast('Confirmação enviada por WhatsApp')` — afirma um
envio que não acontece. Correção mínima desta leva: **não afirmar envio** (desabilitar com "em
breve", ou abrir a conversa/copiar a mensagem e registrar quem clicou). A integração real entra
**depois** dos ajustes, e aí retoma HOM-025 (registro de enviado-em/por-quem/canal/retorno) junto
com o consentimento de contato.

### D-H5 ✅ Telefone entra como obrigatório — em paciente **e** profissional
Mínimo passa a ser **nome + telefone** nos dois cadastros (HOM-011 e HOM-014). Pontos a resolver na
implementação:

- **dado legado**: fichas já salvas sem telefone existem. Ou a obrigatoriedade vale só na criação,
  ou é preciso um caminho de correção — decidir na fatia, não aqui;
- **rascunho**: não entra. Obrigatório é obrigatório no salvar; sem estado intermediário;
- o resto do que o relatório pedia para profissional (CREFITO, especialidade, vínculo, e-mail de
  acesso) **não** entra — só telefone.

### D-H6 ❌ LGPD fica como está
Mantidas D16 (dois booleanos, sem `Consent` versionado), D17 (sem field policy em médico/CRM) e o
adiamento do Art. 11 para v2. HOM-029 é registrado como **aceito com risco**: o consentimento hoje
é declaração, não controle — e só passa a governar algo quando existir envio (D-H4).

### D-H7 ✅ Rótulos dos papéis ficam mais claros na UI
Muda **só o texto exibido**; os valores `owner · admin · profissional · recepcao` **não** mudam no
banco (mexer no enum arrastaria policies, migrations e trilha). Rótulos a usar na interface:
**Proprietária · Administração · Fisioterapeuta · Recepção**. Junto vale publicar a **matriz de
acesso** (o que cada papel vê e altera) — hoje ela só existe espalhada nas policies.

### D-H8 ✅ Conflitos são **listados**; o usuário resolve **um a um**
HOM-024 aceito, e **só a metade "mostrar"** — nada de calcular impacto agregado, sugerir
remanejamento ou resolver em lote. Ação em massa é item futuro, explicitamente fora desta leva.

O desenho é o do protótipo, que já resolveu isto e deve ser seguido de perto
([`futureConflicts` :864](../interface/Movimento.dc.html#L864), modal `modalHorarioConflitos`):

- **Quando dispara.** Ao salvar **horário da clínica**, **horário do profissional** ou
  **exceção** — os três caminhos que mudam expediente ([`:889`](../interface/Movimento.dc.html#L889),
  [`:1199`](../interface/Movimento.dc.html#L1199), [`:1221`](../interface/Movimento.dc.html#L1221)).
- **O que conta como conflito.** Só o agendamento **futuro, ainda aberto** (exclui cancelado,
  concluído e faltou) que **cabia** no expediente atual e **deixa de caber** no novo. Essa
  definição por diferença é o que impede a lista de encher com agendamento que já estava fora.
- **O que a lista mostra.** Data · hora · profissional · paciente (ou "grupo (N)") · **o motivo em
  texto** ("Sem atendimento após a mudança" / "Fora do novo expediente (08:00–12:00)"), ordenada
  por data e hora, com um botão **"Ver na agenda"** por linha que leva ao dia e abre o drawer.
  Esse botão é o "resolver um a um": a pessoa remarca ou cancela lá, com as ações que já existem.
- **A mudança não é salva** enquanto houver conflito — é o comportamento do protótipo, e a cópia
  dele já diz isso ("o horário da clínica não foi alterado"). **Consequência a aceitar:** fechar a
  clínica numa sexta com 20 agendamentos exige mexer nos 20 antes de salvar. Se isso travar a
  operação na prática, a alternativa é salvar mesmo assim com a lista como aviso — mas aí o
  expediente e a agenda ficam incoerentes, que é justamente o que HOM-024 quer evitar.
- **Duração do tipo de atendimento não entra.** O relatório cita "duração" junto, mas o
  agendamento guarda `starts_at`/`ends_at` próprios: mudar a duração do tipo **não** altera
  retroativamente nada. Não há conflito a exibir — vale só a cópia dizendo que a mudança vale
  para os próximos.

**Fora do escopo (futuro):** ação em massa (remarcar/cancelar todos), deslocar série, resumo
agrupado por motivo (HOM-019 — depende de Pacotes).

### D-H9 ⏸ Pacotes: reavaliar quando a Fatia 3 for construída
HOM-005 (parte pacote), HOM-019 e HOM-020 **não** viram backlog agora — viram **requisito de
entrada** da Fatia 3. Ao responder o relatório, corrigir a premissa: pacotes e recorrência não
existem no produto, apesar de aparecerem como "ponto forte" na p. 2.

### D-H10 ✅ Duas colunas no agendamento, em vez de arquivar a fila
No `convert` a entry ainda está em mãos antes do `destroy`
([`waitlist_controller.ex:183`](../api/lib/api_web/controllers/waitlist_controller.ex#L183)), então
o agendamento nasce com **`veio_da_fila`** (booleano) e **`dias_na_fila`** (inteiro — o número que
a tela da fila já calcula). Custo: duas colunas, nenhuma migração de dado, `dequeue` continua
`destroy`.

**O que isso não resolve, e foi aceito:** quem sai da fila **sem** agendar continua sendo apagado.
"Quantos desistiram?" e "quanto tempo esperou quem nunca foi atendido?" permanecem sem resposta.
Se o abandono virar pergunta de gestão, aí `dequeue` vira arquivamento (novo ADR) — e quanto mais
tarde, mais caro.

### D-H11 ✅ Os quatro falsos positivos viram tarefa de **descoberta**
Confirmado o diagnóstico: "a recepção não achou" é o próprio achado. O que fazer em cada um:

| ID | Existe | O que falta de verdade |
| --- | --- | --- |
| HOM-010 | status por participante (`Attendance`) | deixar **visível na UI** que a presença é individual |
| HOM-013 | aviso de duplicado por CPF | estender para **telefone** e **nome + nascimento** |
| HOM-015 | 4 papéis de negócio (ADR-016) | rótulos (D-H7) + matriz de acesso publicada |
| HOM-016 | tela + API de auditoria | **descoberta** (está restrita a owner/admin) e **cobrir cadastros** — hoje a trilha só pega agenda |

### D-H12 ✅ Tratado como erro de montagem do PDF
O HOM-007 ausente e a planilha que não veio são erro de edição, não conteúdo perdido. Pedir a
planilha na próxima interação; não bloquear a execução por isso.

---

## 9. A gramática visual da agenda — o gap contra a Figura 2

Detalhamento do item 1 da [§7](#7-sequenciamento-ordem-de-execução-desta-leva), que resolve
HOM-002 a HOM-006 de uma vez. A referência é a **Figura 2** do relatório ("Proposta simples — uma
regra visual para cada informação"): fundo branco, status por ponto+badge+texto, cor do
profissional na coluna e numa faixa lateral, ação escrita como verbo, contador em texto, legenda
fixa. O alvo é **ficar como a imagem**.

Todo o diagnóstico abaixo é contra
[`AppointmentBlock.svelte`](../web/src/lib/components/agenda/AppointmentBlock.svelte) e
[`DayGrid.svelte`](../web/src/lib/components/agenda/DayGrid.svelte) como estão hoje.

### 9.1 O que muda, item a item

| # | Regra da Figura 2 | Hoje | O que fazer |
| --- | --- | --- | --- |
| 1 | **Fundo do card é branco**; status por ponto, badge e texto | o fundo **é** o status: `color-mix(status 12%)`, ou `warning 16%` quando há ação ([`:82-96`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L82)) | fundo vira `--color-surface` sempre; a borda deixa de ser tingida por status |
| 2 | **Ponto colorido + hora na cor do status** | o ponto antes da hora é do **profissional**; a hora é neutra | ponto e hora passam a ser do **status**; o profissional sai daí (linha 4) |
| 3 | **Badge textual de status em todo card** | status **nunca** aparece escrito — só como tinta, opacidade (`dim`) e tachado (`strike`); o texto existe só no `aria-label` | badge com o rótulo do `STATUS_META` no canto direito |
| 4 | **Cor do profissional na faixa lateral + no cabeçalho da coluna** | a faixa lateral esquerda é do **pacote** (teal, [`:110`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L110)); o cabeçalho da coluna tem só o avatar circular, **sem** underline ([`DayGrid:304-330`](../web/src/lib/components/agenda/DayGrid.svelte#L304)) | faixa passa a ser do profissional; cabeçalho ganha o underline na mesma cor. Troca **livre**: a tarja de pacote não significa nada hoje |
| 5 | **Verbo no lugar de "AÇÃO"** | string literal `AÇÃO` ([`:129`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L129)) | "Registrar status" — ver 9.3 sobre o segundo verbo |
| 6 | **No máximo 2 ícones, todos com tooltip** | até **7 sinais** na linha 1: ponto do profissional, ícone de conflito, badge AÇÃO, ícone de pacote, ícone do tipo, pulso de "em atendimento", badge ENCAIXE. Só o de conflito tem `title` | sobram **conflito** e **encaixe**; ícone de tipo sai (o nome do tipo já é a linha 3), ícone de pacote sai (vira texto), pulso sai (vira o badge "Em atendimento") |
| 7 | **Contador em texto** | `Tipo · 2/4` como título ([`:62`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L62)) | linha própria: **"2/4 vagas ocupadas"**. "Sessão 2 de 4" **não** dá para fazer (exige Pacotes, D-H9) |
| 8 | **Legenda fixa da agenda** | não existe (`grep -i legenda` no `web/` = zero) | faixa de chips acima da grade, ou botão "Entenda as cores" — ver 9.4 |
| 9 | **Ocupação por profissional no cabeçalho** | o cabeçalho mostra CREFITO e a **contagem** de atendimentos, não a ocupação; a `OccupancyBar` existe mas é usada em Semana/Mês | levar a ocupação do profissional para o cabeçalho da coluna do Dia |

A boa notícia estrutural: `STATUS_META` já é fonte única de rótulo e tom
([`agenda.ts`](../web/src/lib/agenda.ts)), então quase tudo acima é mudar **onde** o tom é
aplicado — não inventar um mapa novo.

### 9.2 O que a imagem não resolve: o card não cabe

**Este é o ponto que precisa de decisão antes de codar.** A grade usa `PPM = 1.05`
(pixels por minuto, [`DayGrid:76`](../web/src/lib/components/agenda/DayGrid.svelte#L76)). Logo:

| Duração | Altura real do card |
| --- | ---: |
| 15 min | ~16 px |
| 30 min | ~31 px |
| 50 min | ~53 px |
| 60 min | ~63 px |

O card da Figura 2 tem **quatro linhas** (hora+badge, nome, serviço, contador) e ocupa uns 90 px —
ou seja, a proposta **só cabe em sessão de 85 minutos ou mais**. Na sessão de 30 min, que é o caso
comum, há espaço para **duas linhas**. Hoje isso já é tratado por degradação
([`:69-71`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L69)), e a proposta precisa da
mesma escada — senão o resultado real não se parece com a imagem em nenhum card.

Escada sugerida (a decidir):

- **≥ 76 px** (≥ ~72 min): as quatro linhas da imagem, completo;
- **44–75 px**: hora + badge · nome · tipo (contador cai para o tooltip);
- **30–43 px**: hora + badge · nome;
- **< 30 px**: uma linha — ponto de status + hora + nome truncado; o badge vira só o ponto, e o
  resto vai para o `title`/`aria-label`.

Alternativa que evitaria a escada: **aumentar o `PPM`** (grade mais alta, mais rolagem vertical).
O protótipo tinha controle de densidade e ele é código morto lá. Não recomendo mexer nisso agora —
ganhar fidelidade à imagem custando meio dia de rolagem na tela mais usada é mau negócio.

### 9.3 Onde a proposta contradiz a si mesma (e o que fazer)

**A legenda proposta comete o erro que o relatório diagnostica.** Os seis chips da Figura 2 são
*Agendado · Confirmado · Concluído · Ação necessária · Falta · Cancelado*. Só que:

- **"Em atendimento" sumiu** — e é um status real nosso, com semântica própria (a sessão começou),
  hoje sinalizado pelo pulso teal;
- **"Ação necessária" foi promovida a status** — mas ela é **ortogonal**: um bloco *agendado* ou
  *confirmado* pode precisar de ação. Colocar as duas dimensões na mesma fileira de chips é
  exatamente o "cor representando mais de uma dimensão" do HOM-002;
- **Conflito e encaixe não aparecem** na legenda, e os dois pintam o card hoje.

Nosso modelo é mais correto que a proposta: **6 status + 2 marcadores ortogonais**
(`conflito`, `encaixe`) + **1 pendência** (`ação`). A legenda deve ser desenhada assim, em dois
blocos, e não como uma fileira só de sete chips.

**O segundo verbo não existe no nosso modelo.** A imagem mostra dois: "Registrar status" (num
bloco que já passou) e **"Confirmar"** (no bloco das 08:00 de Bruno Carvalho). Hoje a pendência tem
**um** gatilho só: RN-58, *o bloco terminou e ninguém resolveu*. O verbo "Confirmar" implica um
gatilho novo — *agendado, ainda não confirmado, e o horário está chegando*. Decidir:

- **(a)** manter um gatilho, um verbo ("Registrar status") — zero regra nova, e a tela já fica
  muito melhor que hoje; **é o que recomendo para esta leva**;
- **(b)** adicionar "Confirmar" — precisa definir a janela ("faltam N horas") e vira regra de
  negócio nova, com teste e decisão de produto.

### 9.4 Onde a legenda mora

Três opções, em ordem de preferência:

1. **Faixa fixa acima da grade** (é o que a imagem mostra) — sempre visível, custa ~40 px de
   altura na tela mais disputada do produto;
2. **Botão "Entenda as cores e ícones"** abrindo um popover — não custa espaço, mas quem não sabe
   que precisa não clica (foi assim que a auditoria virou HOM-016);
3. **Faixa recolhível, aberta por padrão, com estado lembrado** — a recepção nova vê; quem já sabe
   fecha uma vez. Custo: um `localStorage`.

Recomendo **(3)**, com **(1)** como plano B se o estado lembrado complicar.

### 9.5 O que fica de fora desta fatia

- **"Sessão 2 de 4"** — exige o módulo Pacotes (D-H9);
- **ícones de WhatsApp e observação** que a coluna "Regras de implementação" da imagem cita
  ("aparecem quando relevantes") — WhatsApp está sob D-H4 e não deve ganhar ícone novo enquanto
  não enviar nada;
- **cor própria do profissional configurável** — hoje a cor sai do `cor_indice`
  (`avatarColor`), o que já basta para coluna e faixa;
- **Semana, Mês e Lista** herdam o `STATUS_META` e o badge textual, mas o redesenho do card é da
  visão **Dia**; as outras entram só na parte que for de graça.
