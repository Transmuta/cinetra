# 108 — Central de ajuda: o produto explicado, com print, para quem usa

> **Estado em 2026-08-06: construída e no ar em `/ajuda`.** Este documento nasceu como plano; o que
> foi executado está na §10, no fim, com o que mudou em relação ao plano e o que ficou pendente.

Plano da **página de suporte/onboarding**: todos os fluxos do Cinetra explicados passo a passo,
com imagem da tela, para (a) treinar quem chega e (b) responder a dúvida de quem já usa sem
depender de alguém do outro lado.

Não confundir com o que já existe:

| Já temos | Para quem | Por que não serve aqui |
| --- | --- | --- |
| `docs/*.md` | nós | fala de RLS, GUC, Ash, débito técnico — é documentação de construção |
| [`docs/82-roteiro-qa-guiado.md`](82-roteiro-qa-guiado.md) | quem homologa | é **checklist de teste**, escrito na ordem de quebrar o sistema, não na de usá-lo |
| `/termos`, `/privacidade` | público/jurídico | contrato, não instrução |

O 82 é, ainda assim, o **melhor esqueleto que existe**: ele já percorreu a aplicação inteira,
fluxo a fluxo, com os papéis certos. A central de ajuda é o 82 virado do avesso — o mesmo
inventário, reescrito do ponto de vista de quem quer **fazer**, e não de quem quer **conferir**.
Todo tópico abaixo aponta para a seção do 82 que o cobre, e esse par tem de ser mantido: se um
fluxo existe no 82 e não tem tópico aqui, ele está sem manual.

---

## 1. Princípios

1. **Tarefa, não tela.** O título do tópico é o que a pessoa quer fazer ("Remarcar um
   atendimento"), não o nome do componente. Quem procura ajuda não sabe que o que ela quer se
   chama `RescheduleModal`.
2. **Print de dado semeado, nunca de clínica real.** Toda imagem sai de uma clínica de teste
   gerada na hora. Print de produção com nome e CPF de paciente numa página de ajuda é vazamento
   de dado de saúde — e a página é, por desenho, a mais compartilhável do sistema.
3. **A imagem é gerada, não capturada à mão.** Print tirado à mão envelhece em silêncio e ninguém
   descobre até um usuário reclamar que "a tela é diferente". Ver §4.
4. **Acessível deslogado.** Metade das dúvidas de suporte é *não consigo entrar*. Uma ajuda que
   exige sessão não atende exatamente quem mais precisa dela.
5. **Conteúdo é dado, não markup** — mesma escolha de `$lib/legal.ts`, pela mesma razão: sumário,
   busca e corpo saem do mesmo array, então não existe índice que liste tópico inexistente nem
   tópico órfão do índice.
6. **O que o papel não vê, o texto avisa.** A dúvida mais comum de RBAC não é "como faço", é "por
   que não vejo esse menu". Cada tópico declara quem alcança aquilo.

---

## 2. Onde a página mora

**Recomendado: rota própria no `web/`, fora do grupo `(app)`** — `/ajuda` e `/ajuda/[topico]`.

- Fora de `(app)` porque o shell autenticado (rail + sidebar) não pode ser pré-requisito
  (princípio 4). A casca é a das páginas públicas (`SiteHeader`/`SiteFooter`, como
  `/termos`), com um "voltar ao sistema" quando há sessão.
- Mesmo deploy, mesma CSP, mesmo tema, zero infraestrutura nova. As imagens ficam em
  `web/static/ajuda/` — servidas da mesma origem, sem esbarrar na CSP.
- Ganha deep-link: `/ajuda/remarcar-atendimento` é o que se cola no WhatsApp de quem perguntou.

Alternativas descartadas: **site separado** (Docusaurus e afins) custa deploy, domínio, tema e
CSP próprios para uma dúzia de páginas, e desliga o link contextual dentro do produto; **PDF /
Notion** sai do controle de versão e não tem como quebrar o build quando a tela muda.

---

## 3. Inventário — tudo que precisa ser escrito

19 seções, ~90 tópicos. A coluna **Prints** é a estimativa de imagens do tópico (uma por passo
que muda a tela); **Papel** é quem alcança o fluxo (`O` owner, `A` admin, `P` profissional,
`R` recepção). "§" remete à seção do doc 82.

### A. Primeiros passos (§0, §1)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| A1 | O que é o Cinetra e como ele se organiza (clínica → equipe → agenda) | — | 1 | todos |
| A2 | Criar sua conta | `/criar-conta` | 3 | todos |
| A3 | Entrar sem senha: o link mágico e o Google | `/entrar`, `/confirmar/[token]` | 3 | todos |
| A4 | Criar a clínica (primeiro acesso) | `/comecar` | 3 | O |
| A5 | Conhecendo a tela: rail, sidebar, topbar, sino | shell | 2 | todos |
| A6 | Trocar de clínica | `UserMenu` | 2 | todos |
| A7 | Seu perfil, tema claro/escuro e sair | `/perfil` | 3 | todos |
| A8 | Sair de todos os dispositivos (e quando usar) | `/perfil` | 2 | todos |
| A9 | **Roteiro do primeiro dia** — a ordem certa de configurar tudo | — | 1 | O/A |

> A9 é o tópico de onboarding propriamente dito: uma lista encadeada (clínica → tipos → horário
> → profissionais → equipe → primeiro paciente → primeiro agendamento) que só linka os outros.
> É o que se manda para a clínica nova, e provavelmente o mais lido da central.

### B. Equipe e acessos (§2, §12)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| B1 | Convidar alguém para a equipe | `/configuracoes/equipe` | 4 | O/A |
| B2 | **Os quatro papéis e o que cada um vê** (a matriz) | `AccessMatrixTable` | 2 | todos |
| B3 | Aceitar um convite (visão de quem foi convidado) | e-mail → `/confirmar` | 3 | todos |
| B4 | Reenviar, cancelar convite, remover membro | `/configuracoes/equipe` | 3 | O/A |
| B5 | Trocar o papel de um membro | `MemberModal` | 2 | O |
| B6 | "Por que não vejo o menu Auditoria / Profissionais?" | — | 1 | todos |

### C. Configurações da clínica (§3)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| C1 | Dados da clínica (nome, CNPJ, contato) | `/configuracoes/clinica` | 2 | O/A |
| C2 | Tipos de atendimento: duração, cor, sigla | `/configuracoes/tipos` | 4 | O/A |
| C3 | Tipo individual × turma (e o que muda na agenda) | `TypeModal` | 3 | O/A |
| C4 | Horário de funcionamento da clínica | `/configuracoes/horario` | 3 | O/A |
| C5 | Exceções: feriado, recesso, dia atípico | `/configuracoes/excecoes` | 4 | O/A |
| C6 | Exceção do profissional × da clínica | `/configuracoes/excecoes` | 2 | O/A |

### D. Profissionais (§5)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| D1 | Cadastrar um profissional | `/profissionais/novo` | 3 | O/A/R |
| D2 | Horário de atendimento do profissional | `ProfessionalHoursEditor` | 3 | O/A |
| D3 | Editar, inativar profissional (e o que acontece com a agenda dele) | `/profissionais/[id]` | 3 | O/A |
| D4 | Vincular o profissional ao acesso dele no sistema | equipe + profissionais | 2 | O/A |
| D5 | **O que o profissional vê** (agenda só-leitura — doc 103) | — | 2 | P |

### E. Pacientes (§4)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| E1 | Cadastrar paciente | `/pacientes/novo` | 4 | O/A/R |
| E2 | CPF, CEP e os campos que o sistema completa sozinho | `PatientForm` | 3 | O/A/R |
| E3 | "Esse paciente já existe" — o aviso de duplicado | `PatientForm` | 2 | O/A/R |
| E4 | Buscar paciente | `/pacientes` | 2 | todos |
| E5 | A ficha: histórico, próximos atendimentos, dados | `/pacientes/[id]` | 3 | todos |
| E6 | Anexos: enviar, ver, remover arquivo | `PatientAttachments` | 4 | O/A/R |
| E7 | Editar e excluir paciente (e o que fica na trilha) | `/pacientes/[id]/editar` | 3 | O/A |

### F. Agenda — o coração (§6)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| F1 | As visões: dia, semana, mês, lista | `AgendaNav` | 5 | todos |
| F2 | Filtrar por profissional | `ProfessionalChips` | 2 | todos |
| F3 | **Marcar um atendimento** | `NewAppointmentModal` | 5 | O/A/R |
| F4 | Remarcar: arrastando e pelo modal | `RescheduleModal` | 4 | O/A/R |
| F5 | "Esse horário já está ocupado" — conflitos | `ConflictErrorBox` | 2 | O/A/R |
| F6 | Encaixe: marcar fora do horário, e quando isso é permitido | `EncaixeCheckbox` | 3 | O/A/R |
| F7 | O drawer do agendamento: tudo que dá para fazer ali | `AppointmentDrawer` | 3 | todos |
| F8 | Status: confirmar, atender, falta, cancelar | `AppointmentDrawer` | 5 | O/A/R |
| F9 | Turma: presença por participante | `AppointmentDrawer` | 4 | O/A/R |
| F10 | Excluir agendamento (× cancelar: qual usar quando) | `ConfirmDialog` | 3 | O/A |
| F11 | Excluir uma série inteira e a análise de impacto | — | 3 | O/A |
| F12 | O link do agendamento (mandar para o paciente) | drawer | 2 | O/A/R |
| F13 | Legenda de cores e a barra de ocupação | `AgendaLegend`, `OccupancyBar` | 2 | todos |
| F14 | Duas pessoas na mesma agenda: o que atualiza sozinho | `DayViewers` | 2 | todos |

### G. Pacotes de sessões (§8)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| G1 | O que é um pacote e quando usar | `PackageList` | 1 | O/A/R |
| G2 | Criar pacote de N sessões (com prévia antes de gravar) | `PackageCreateModal` | 5 | O/A/R |
| G3 | Ajustar a grade do pacote | `PackageGradeModal` | 3 | O/A/R |
| G4 | Ver e mexer nas sessões de um pacote | `PackageSessionsModal` | 3 | O/A/R |
| G5 | Ações em massa: remarcar/cancelar o pacote todo | — | 3 | O/A |

### H. Fila de espera (§7)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| H1 | Colocar um paciente na fila | `AddToWaitlistModal` | 4 | O/A/R |
| H2 | Prioridade e disponibilidade do paciente | `PriorityBadge` | 2 | O/A/R |
| H3 | Vagou um horário: quem cabe ali | `OfferSlotModal` | 4 | O/A/R |
| H4 | Oferecer, receber a resposta, converter em agendamento | `/fila` | 4 | O/A/R |
| H5 | Sair da fila / expirar oferta | `/fila` | 2 | O/A/R |

### I. Comunicação com o paciente (§9)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| I1 | O que o paciente recebe, e quando (o mapa dos gatilhos) | `/configuracoes/comunicacao` | 2 | O/A |
| I2 | Ligar/desligar cada aviso | `/configuracoes/comunicacao` | 3 | O/A |
| I3 | Editar os textos das mensagens | `/configuracoes/comunicacao` | 3 | O/A |
| I4 | O lembrete automático (quantas horas antes) | `/configuracoes/comunicacao` | 2 | O/A |
| I5 | Ver o que foi enviado a um paciente | `MessageTimeline` | 2 | todos |
| I6 | "Não enviou" — entregue, falhou, opt-out | `MessageTimeline` | 3 | O/A |
| I7 | O paciente pediu para não receber mais (descadastro) | `/descadastrar/[token]` | 2 | O/A |

### J. Notificações internas (§10)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| J1 | O sino: o que gera notificação | rail | 2 | todos |
| J2 | Não lidas, marcar como lida, limpar | `/notificacoes` | 3 | todos |

### K. Relatórios (§11)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| K1 | O que cada número quer dizer | `/relatorios` | 3 | O/A |
| K2 | O calendário de volume por dia | `/relatorios` | 2 | O/A |
| K3 | Filtrar por período e profissional | `/relatorios` | 2 | O/A |

### L. Auditoria (§2, §12)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| L1 | Quem mexeu no quê | `/auditoria` | 3 | O/A |
| L2 | Filtros e leitura de uma entrada (o antes/depois) | `AuditEntry`, `FieldDiff` | 3 | O/A |
| L3 | Por que alguns valores aparecem escondidos, e a retenção de 90 dias | — | 1 | O/A |

### M. Celular (§14)

| # | Tópico | Telas | Prints | Papel |
| --- | --- | --- | --- | --- |
| M1 | Usando no celular: o que muda | várias | 4 | todos |
| M2 | Instalar como aplicativo (PWA) | — | 3 | todos |

### N. Quando algo dá errado (§1, §13 + o que o suporte de fato recebe)

Sem print na maioria — é texto curto de sintoma → causa → saída.

| # | Tópico |
| --- | --- |
| N1 | Não recebi o e-mail com o link |
| N2 | "Este link não vale mais" |
| N3 | "Muitas tentativas, tente daqui a pouco" (limite de envios) |
| N4 | Fui deslogado no meio do trabalho |
| N5 | Não vejo um menu / botão que outra pessoa vê |
| N6 | A agenda não mostra o horário que eu esperava |
| N7 | O paciente diz que não recebeu a mensagem |
| N8 | Erro ao enviar anexo |
| N9 | Como falar com o suporte (e o que mandar junto) |

### O. Privacidade e dados (§15)

| # | Tópico |
| --- | --- |
| O1 | Quem enxerga os dados da minha clínica |
| O2 | Pedidos do paciente sobre os dados dele (LGPD) |
| O3 | Termos e política de privacidade |

**Totais:** ~90 tópicos, **~215 prints**.

---

## 4. As prints: geradas pela suíte e2e

O maior risco de uma página assim não é escrevê-la — é ela apodrecer. Print tirado à mão de uma
tela que mudou é pior que nenhum print: ensina errado e destrói a confiança no resto da página.

A saída existe e já está montada: **a fixture `clinica` do `web/e2e/`**. Ela cria uma clínica
inteira por teste, com dono autenticado por magic link de verdade e cenário semeado por HTTP —
que é exatamente o que uma print precisa: **dado falso, realista e reproduzível**.

O plano é um alvo novo ao lado da suíte (não dentro dela — objetivos diferentes):

```
web/e2e/prints/           # specs que só navegam e fotografam
  agenda.prints.ts
  pacientes.prints.ts
  ...
web/static/ajuda/         # saída versionada, servida pela própria origem
  f3-marcar-01-botao.png
  f3-marcar-02-modal.png
```

Regras do gerador:

- **Cada print tem um id** (`f3-marcar-02-modal`) que é a chave usada no conteúdo. Nome de arquivo
  solto vira link quebrado silencioso.
- **Viewport fixo** (1440×900 desktop, 390×844 celular) e **tema claro** por padrão. Prints em dois
  temas dobram a manutenção para ganhar quase nada; o tópico A7 mostra o escuro e só.
- **Máscara de tudo que varia** — data de hoje, hora, id — senão todo `git diff` de print vira ruído
  e ninguém revisa mais.
- **Recorte, não tela cheia**, quando o assunto é um modal ou um campo. Print de 1440px para
  explicar um checkbox é ilegível no celular.
- **Um comando**: `npm run prints`. E um **gate**: um teste unitário que percorre o conteúdo e falha
  se algum print citado não existe em `static/ajuda/` — e vice-versa, se algum arquivo virou órfão.

Custo honesto: o gerador é ~1 dia de encanamento + ~15–20 min por tópico de navegação escrita. Não
é barato. É mais barato que 215 prints à mão *uma vez*, e incomparavelmente mais barato na segunda
vez, que é quando a página normalmente morre.

---

## 5. Forma técnica

```
web/src/lib/ajuda/
  index.ts          # tipos + registro dos tópicos (o índice sai daqui)
  tipos.ts          # Topico, Passo, Print, Secao — dado, não markup
  conteudo/
    agenda.ts
    pacientes.ts
    ...
  ajuda.test.ts     # gate: id único, print existente, tópico do 82 coberto, link interno válido
web/src/lib/components/ajuda/
  AjudaShell.svelte   # casca (irmã de LegalPage)
  Passo.svelte        # número + texto + print + legenda
  Print.svelte        # <img> com dimensão fixa, lazy, alt obrigatório
  Aviso.svelte        # "só o dono faz isso" / "cuidado"
  Busca.svelte        # filtro client-side sobre título+corpo
web/src/routes/ajuda/
  +page.svelte              # índice por seção
  [topico]/+page.svelte     # o tópico
```

O modelo de dado, mínimo e suficiente:

```ts
type Passo = { texto: string; print?: string; legenda?: string };
type Topico = {
  id: string;              // 'marcar-atendimento' — é a URL
  secao: SecaoId;
  titulo: string;          // a tarefa, no infinitivo
  resumo: string;          // uma linha; alimenta índice e busca
  papeis: readonly Papel[];// quem alcança
  passos: readonly Passo[];
  veja_tambem?: readonly string[]; // ids
  roteiro82?: string;      // '§6' — a rastreabilidade da §1
};
```

A busca é client-side sobre título + resumo + texto dos passos. Nada de índice remoto: são 90
tópicos, cabem em memória e funcionam offline no PWA.

---

## 6. Costura dentro do produto

A central só cumpre o papel de suporte se ela aparecer **onde a dúvida nasce**:

1. **"?" na topbar**, que abre a ajuda **da tela atual** — um mapa `rota → tópico`, colado ao
   `sectionOf()` que já existe em `nav.ts`.
2. **Link no `UserMenu`** ("Ajuda e suporte").
3. **Estados vazios apontando para o tópico**: `AgendaEmptyState` sem agendamento nenhum é o
   melhor lugar do sistema para o link de F3; a lista de pacientes vazia, para E1.
4. **E-mail de convite** com link para B3 — a pessoa convidada é, por definição, quem menos
   conhece o sistema.
5. **Rodapé da landing** e das páginas legais.

---

## 7. Caminho — as fases

**Fase 0 — decisões (§9), meia hora.** Sem elas o resto anda torto.

**Fase 1 — o esqueleto, sem conteúdo (~1 dia).** Rota `/ajuda` e `/ajuda/[topico]`, tipos,
componentes, casca, busca, índice, testes do gate. Entregável: **dois tópicos de ponta a ponta**
(A9 e F3), com print, para validar a forma antes de escrever 90.

**Fase 2 — o gerador de prints (~1 dia).** `web/e2e/prints/`, `npm run prints`, máscara de dado
volátil, gate de print órfão/faltante. Entregável: as prints de F3 saindo do comando.

**Fase 3 — conteúdo, em ondas na ordem do uso real.** Cada onda é fechada (texto + prints +
gate verde) e pode ir ao ar sozinha:

| Onda | Seções | Por quê primeiro |
| --- | --- | --- |
| 1 | A, F | Onboarding e agenda: 80% do uso e 80% das dúvidas |
| 2 | E, D | Cadastro é o que se faz no primeiro dia |
| 3 | C, B | Configuração e papéis — a fonte do "não vejo o menu" |
| 4 | H, G | Fila e pacotes: potentes e não-óbvios |
| 5 | I, J, K, L | Comunicação, sino, relatórios, auditoria |
| 6 | M, N, O | Celular, problemas, privacidade |

**Fase 4 — costura (§6), ~meio dia.** Só depois da onda 1: link para tópico que não existe é
pior que link nenhum.

**Fase 5 — manutenção.** Vira regra do projeto, não boa intenção:

- Mexeu em tela → `npm run prints` e revisar o tópico correspondente, no **mesmo commit**.
- Item novo no roteiro 82 → tópico correspondente na central (o gate cobra).
- Entra no checklist de bate-volta de qualquer fatia com interface.

---

## 8. Riscos

| Risco | Mitigação |
| --- | --- |
| Print envelhece | Geração automatizada + gate; §4 |
| Dado real vazando na imagem | Só fixture; nunca produção. É o princípio 2 e não tem exceção |
| Peso da página | ~215 PNGs: converter para WebP, `loading="lazy"`, print por tópico e não tudo numa página só |
| Texto duplicando `docs/` e divergindo | `docs/` fala de construção, `/ajuda` de uso. Onde há regra de negócio compartilhada (retenção, papéis), a central **cita o número** e não repete a explicação |
| Escrever 90 tópicos e cansar na metade | Ondas fechadas: cada onda vai ao ar sozinha e é útil sozinha |
| Página ficar linda e ninguém achar | Fase 4 é parte do escopo, não enfeite |

---

## 9. Decisões abertas

1. **Público:** só a clínica (equipe), ou também o paciente que recebe o link do agendamento? O
   inventário acima é **só equipe**. Ajuda ao paciente é outra página, menor, e pode esperar.
2. **Vídeo:** GIF/vídeo curto em F3, F4 e H4 (os fluxos de arrastar) ensina muito melhor que print
   parada, e custa a mesma infraestrutura (Playwright grava vídeo). Fica para uma fase 7, ou entra
   já na onda 1?
3. **Ajuda deslogada:** confirmar que `/ajuda` é pública. Ela expõe a **forma** do produto (nomes
   de tela, fluxos) a qualquer visitante — o que, para um SaaS, costuma ser desejável (vira
   material de venda), mas é decisão de negócio, não técnica.
4. **Tom:** "você" (direto, curto) ou impessoal. Recomendo "você", e frase curta — o leitor está
   com o problema na tela ao lado.

---

## 10. O que foi construído (2026-08-06)

Escopo confirmado com o humano antes de começar: **só a equipe da clínica** — ajuda ao paciente
fica para outra fatia.

### 10.1 O que está no ar

| Peça | Onde |
| --- | --- |
| Índice, busca e 44 tópicos | [`web/src/routes/ajuda/`](../web/src/routes/ajuda/) — `/ajuda` e `/ajuda/[topico]` |
| Conteúdo como dado, por seção | [`web/src/lib/ajuda/conteudo/`](../web/src/lib/ajuda/conteudo/) — 15 arquivos |
| Modelo e funções (índice, busca, vizinhos, rota→tópico) | [`web/src/lib/ajuda/`](../web/src/lib/ajuda/) |
| Gate de integridade | [`ajuda.test.ts`](../web/src/lib/ajuda/ajuda.test.ts) — 26 asserções |
| Componentes | [`web/src/lib/components/ajuda/`](../web/src/lib/components/ajuda/) |
| Gerador de prints | [`web/e2e/prints/`](../web/e2e/prints/) + [`playwright.prints.config.ts`](../web/playwright.prints.config.ts) |
| Manifesto de imagens | [`scripts/manifesto-prints.mjs`](../web/scripts/manifesto-prints.mjs) → `src/lib/ajuda/prints.json` |
| Comando | `npm run prints` (captura + manifesto) |

**As 73 prints citadas estão capturadas** e `PENDENTES` está vazia (o débito **D-27** do
[doc 50](50-debitos-tecnicos.md) foi pago no mesmo dia, com as quatro armadilhas de seletor que ele
custou registradas lá).

### 10.2 O que mudou em relação ao plano

- **44 tópicos, não ~90.** O inventário da §3 listava a granularidade máxima; escrevendo, vários
  itens eram o mesmo tópico visto de dois ângulos (por exemplo "prioridade" e "disponibilidade" da
  fila, que ninguém consulta separado). O que o inventário cobria continua coberto.
- **F11 ("excluir uma série e a análise de impacto") não existe** como tela. `impact_analysis` mora
  no backend e não tem superfície no `web/` — medido com busca no `web/src`. O que existe de
  verdade, o cancelamento do pacote inteiro, virou parte de "Pacotes: pausar, ajustar e cancelar".
- **A comunicação com o paciente não tem disparo por relógio.** O plano previa tópicos de "lembrete
  automático" e "editar os textos"; a tela de Comunicação tem dois controles (canal e janela de
  silêncio), e o lembrete por cron saiu em 2026-08-01 (doc 98). O tópico foi escrito sobre o que o
  sistema faz: mensagem nasce de ação da equipe.
- **A casca virou a das páginas públicas** (decisão do humano no meio da execução). A central abria
  com os tokens do app; passou a usar `SiteHeader`/`SiteFooter`, herói navy e a paleta papel/navy —
  ela é pública e compartilhável por link, e com o design interno destoava no meio do site.
  Consequência: **não tem tema escuro**, como `/termos` e `/privacidade`, e a família
  `lib/components/ajuda/` entrou na isenção do tripwire de cor crua
  ([`cor-crua.test.ts`](../web/src/lib/styles/cor-crua.test.ts)), pelo mesmo motivo da família
  `cinetra/` — está comentado lá.
- **Navegação lateral no tópico** (mesmo pedido): a coluna da esquerda lista os tópicos irmãos da
  seção com o atual marcado, mais as outras seções. Quem entra num tópico quase sempre precisa do
  vizinho em seguida — "marcar" → "remarcar" → "cancelar".
- **Imagem grande e ampliável** (mesmo pedido): a print ocupa a largura da coluna e abre em tamanho
  real ao clique, com Esc e clique-fora para sair. A tela fotografada tem 1440px e a coluna de
  leitura tem ~760: sem ampliar, o botão que o texto cita fica com 8px.

### 10.3 O bug do tema escuro, e o tripwire que ele deixou

Achado ao vivo no mesmo dia, logo depois de a casca virar a das páginas públicas: **no tema escuro
o campo de busca ficava preto** no meio da página creme, e o texto das tabelas e dos avisos sumia.

A causa é a mistura de dois sistemas. A casca da marca é papel/navy **fixo** — `/termos` e
`/privacidade` não têm tema escuro —, mas os componentes da central tinham nascido com os
utilitários do app interno (`bg-surface`, `text-ink`, `border-edge`), que seguem o `data-theme` do
aparelho. No tema claro os dois coincidem, e por isso o defeito é invisível para quem revisa.

O conserto foi fixar a paleta da marca em `Busca`, `Aviso` e `Corpo`. O que impede a volta é
[`paleta.test.ts`](../web/src/lib/components/ajuda/paleta.test.ts): ele varre
`lib/components/ajuda/*.svelte` e reprova qualquer utilitário ou `var(--color-…)` do app. É o
**inverso** do `cor-crua.test.ts` — que procura hex escrito à mão e isenta esta família —, e os dois
juntos fecham a pinça: na central, cor tem de ser hex da marca; no app interno, tem de ser token.

Antes do conserto, o teste foi rodado contra o código velho e ficou **vermelho** (a regra da casa:
bug vira teste antes de virar conserto).

### 10.4 As lições do gerador de prints

Três coisas custaram tempo e valem para quem for mexer:

1. **Fixture do Playwright é preguiçosa.** `test('x', async ({ page }) => …)` que navega para uma
   tela interna roda **deslogado** — a fixture `clinica` só é montada quando o teste a pede nos
   argumentos. Seis prints de configuração saíram assim: arquivo gerado, nome certo, foto da tela de
   login. A saída é [`e2e/prints/autenticado.ts`](../web/e2e/prints/autenticado.ts), uma fixture
   `auto` que depende de `clinica`. Fazer a própria `page` depender dela é impossível (ciclo:
   `clinica` já depende de `page`).
2. **Clique antes da hidratação não levanta erro.** A tela vem pronta do SSR, o botão está visível e
   o clique simplesmente não faz nada. É o mesmo cuidado que `abrirAgenda` já tinha; aqui ele
   precisa estar em todo cenário que clica logo depois do `goto`.
3. **Editar o `package.json` reinstala tudo no container.** O entrypoint do `web` roda `npm install`
   quando ele muda — o Playwright subiu de versão no meio da leva e o browser baixado deixou de
   servir (`npx playwright install chromium` resolve). Vale saber antes de acrescentar um script.

### 10.5 O que falta

- **Vídeo/GIF** nos fluxos de arrastar (§9, item 2) — continua em aberto.
- A **passada de acessibilidade** na central com o axe, no molde de `e2e/a11y-*.spec.ts`.
