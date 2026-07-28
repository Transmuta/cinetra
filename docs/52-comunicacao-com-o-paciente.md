# 52 — Comunicação com o paciente: histórico por sessão, e-mail primeiro, WhatsApp depois

Este doc fecha o que o **D-H4** deixou em aberto ([doc 37 §D-H4](37-homologacao-andreza.md),
[doc 50 §D4](50-leva-andreza-plano.md)): a confirmação de sessão deixa de ser um toast e vira
comunicação de verdade, com **histórico legível por agendamento** — que é o que a recepção
precisa para entender o que rolou sem ligar para o paciente.

A estratégia é a acordada: **construir a espinha inteira no e-mail, levá-la a 100%, e depois
trocar o transporte** para WhatsApp (Gupshup). Este doc concorda com ela e faz **uma emenda**:
entre e-mail e WhatsApp não muda só "quem envia" — mudam quatro coisas (§2). Se as quatro
estiverem no modelo desde a fase 1, a fase 2 é adapter. Se não estiverem, é reescrita.

### Decidido em 2026-07-27

As sete estão detalhadas no §12; aqui é o resumo executável:

1. **Provider da fase 1: Resend** — adapter já instalado, webhook de eventos como ensaio do
   webhook da fase 2 (§2.1);
2. **A fase 1 envia só a quem tem e-mail**, e o campo **não** vira obrigatório (§8);
3. **O WhatsApp entra antes de produção**, junto com **telefone obrigatório** — é esse par que
   fecha a lacuna de cobertura da fase 1 (§9);
4. **WhatsApp é o canal padrão**, e-mail é reserva — com a ressalva de que opt-out explícito não
   cai para a reserva (§10.4);
5. **Um número único da Cinetra**, com o nome da clínica no template. Número próprio da clínica
   fica como **funcionalidade futura**, oferecida a quem pedir — não é alvo de migração (§9.1);
6. **O consentimento de comunicação passa a nascer autorizado** — não há produção, e a base legal
   do operacional é execução de contrato, não consentimento (§11.1);
7. **O histórico da comunicação é por participante**, e é ele o entregável que a recepção usa
   (§3 e §6).

**Método.** Li [`AppointmentDrawer.svelte`](../web/src/lib/components/agenda/AppointmentDrawer.svelte),
[`Api.Accounts.Emails`](../api/lib/api/accounts/emails.ex),
[`Api.Notifications.Reminders`](../api/lib/api/notifications/reminders.ex),
[`Attendance`](../api/lib/api/scheduling/attendance.ex), [`Patient`](../api/lib/api/records/patient.ex)
e o `Oban` de [`config.exs:87-120`](../api/config/config.exs#L87). O que digo que existe, existe
no código citado.

---

## 1. O quarto plano

O [doc 31 §1](31-notificacoes.md) separou três planos que um "sino" confunde: **sync ao vivo**,
**toast** e **notificação por usuário**. Comunicação com o paciente é o **quarto**, e é diferente
dos três em tudo que importa:

| | Sync / toast / sino | Comunicação com o paciente |
| --- | --- | --- |
| Destinatário | usuário **logado** da clínica | **paciente**, que não tem login |
| Transporte | WebSocket / banco | **fora do sistema** (SMTP, Meta) |
| Entrega | instantânea ou não-evento | **assíncrona e falível** (bounce, número errado, opt-out) |
| Volta | nenhuma | **o paciente responde** — e a resposta muda o agendamento |
| Custo | zero | **por mensagem** |

Por isso ela **não** entra em [`Api.Notifications`](../api/lib/api/notifications/) — aquilo é
caixa por-usuário, por-tenant, sem transporte externo. É domínio novo (`Api.Messaging`).

O que existe hoje é um botão que mente: o rodapé do drawer dispara
`onToast('Confirmação enviada por WhatsApp')` sem enviar nada
([`AppointmentDrawer.svelte:172`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L172)).

---

## 2. A emenda: "só muda quem envia" vale em um dos quatro eixos

| Eixo | E-mail | WhatsApp (Gupshup) | É só adapter? |
| --- | --- | --- | --- |
| **Transporte** | Swoosh | HTTP na API do BSP | ✅ **sim** — é o eixo em que a intuição está certa |
| **Conteúdo** | corpo livre, sempre | **template HSM aprovado pela Meta** fora da janela de 24h | ❌ o corpo precisa nascer como **template + variáveis**, não string montada |
| **Entrega** | `enviado` e, com provider bom, `entregue`/`bounce` por webhook | `enviado`/`entregue`/**`lido`** por webhook | ⚠️ só se a máquina de estados existir na fase 1 |
| **Resposta** | ninguém responde e-mail de `nao-responda@` | o paciente responde na conversa | ❌ precisa de caminho de entrada |
| **Opt-out** | link de descadastro | palavra-chave ("SAIR"), obrigatória | ⚠️ tem de ser **por canal**, não um booleano só |

Consequência prática, e é a decisão de engenharia mais importante deste doc:

> **A fase 1 usa um provider de e-mail com webhook de eventos** — decidido: **Resend**.
> Não por causa do e-mail — por causa do WhatsApp. É o webhook que exercita, já na fase 1, a
> parte cara e cheia de armadilha da fase 2: rota pública sem sessão, verificação de assinatura,
> idempotência e — a pior — **resolver o tenant de um evento que chega sem `clinic_id`**.

Com adapter `Local`/`Test` (o que está configurado hoje,
[`config.exs:157`](../api/config/config.exs#L157)) a fase 1 fica bonita e a fase 2 descobre tudo
isso de uma vez.

### 2.1 O que o Resend custa em código: quase nada

Levantado no `deps/`, não estimado:

- **`Swoosh.Adapters.Resend` já está instalado** (swoosh `1.26.3`), e `finch`/`req` já são deps —
  **zero dependência nova**;
- falta ligar o api_client: hoje é `config :swoosh, :api_client, false`
  ([`config.exs:158`](../api/config/config.exs#L158)), porque o adapter `Local` não fala HTTP. Em
  produção vira Finch (ou Req) **com o pool supervisionado**;
- o `from` precisa de **domínio verificado** (SPF/DKIM/DMARC no DNS). O atual é
  `nao-responda@movimento.local` — placeholder de dev assumido como tal no
  [`Emails`](../api/lib/api/accounts/emails.ex). Verificar o domínio tem passo manual e propagação
  de DNS: é o item de lead time da fase 1, como o template HSM é o da fase 2;
- **webhook**: o Resend assina via Svix (`svix-id` / `svix-timestamp` / `svix-signature`) e manda
  `email.sent`, `email.delivered`, `email.bounced` e `email.complained` — que são exatamente os
  quatro estados do §4. `email.opened`/`email.clicked` existem e **não vamos ligar** (C4).

Ganho de tabela: verificar o domínio também conserta o remetente dos e-mails de **acesso**
(magic link e acesso removido), que hoje sairiam de um domínio que não existe.

---

## 3. O histórico ancora na **presença**, não no bloco

Este é o erro que o projeto já cometeu uma vez e corrigiu na A2: falta e motivo eram do bloco, e
numa turma de 4 isso **mente** ([doc 50 §D5](50-leva-andreza-plano.md), doc 41).

Comunicação é com **uma pessoa**. Numa turma de 4, "confirmação enviada" no bloco é falso para
os outros 3. Então a mensagem aponta para
[`Attendance`](../api/lib/api/scheduling/attendance.ex) — que já é *o participante* e já carrega
`patient_id`, `appointment_id` e `session_starts_at`. Em atendimento individual há 1 presença, e
o resultado é visualmente idêntico ao que se esperaria do bloco; numa turma, ele é o único
coerente.

O histórico **do agendamento** que a recepção lê é, portanto, a união das mensagens das presenças
vivas dele — a mesma agregação que o rollup do desfecho já faz.

---

## 4. O modelo

Recurso novo, `Api.Messaging.Message`, RLS + tenant como todo o resto (ADR-017/018):

| Campo | Por quê |
| --- | --- |
| `clinic_id`, `attendance_id`, `patient_id` | tenant + âncora (§3) |
| `canal` (`:email` \| `:whatsapp`) | o eixo que troca na fase 2 |
| `kind` (`:confirmacao` \| `:lembrete` \| `:remarcacao` \| `:cancelamento`) | o motivo, não o texto |
| `template` + `vars` (map) | conteúdo como **template + variáveis** desde a fase 1 (§2) |
| `destino` | e-mail/telefone **congelado no envio** — a ficha muda depois e o histórico não pode mudar junto |
| `status` | máquina abaixo |
| `provider`, `provider_message_id` | o que casa o webhook de volta com a linha |
| `enfileirado_em`, `enviado_em`, `entregue_em`, `lido_em`, `falhou_em`, `erro` | a linha do tempo que a recepção lê |
| `respondido_em`, `resposta` (`:confirmou` \| `:quer_remarcar`) | §5 |
| `disparado_por_id` (nulo = automático) | "quem mandou" — metade do HOM-025 |

**Máquina de estados** (única para os dois canais):

```
:pendente → :enviado → :entregue → :lido
     ↓          ↓           ↓
  :falhou   :falhou    (:respondido é campo, não estado — a resposta pode vir a qualquer momento)
```

`:lido` simplesmente nunca acontece no e-mail sem pixel de rastreio — e **não vamos usar pixel**
(é rastreio de leitura de paciente; desproporcional). O estado existe vazio na fase 1 e ganha
valor na fase 2. Isso é o oposto de dívida: é o encaixe que faz a troca ser adapter.

**Envio**: job Oban na fila `notifications` (já existe, [`config.exs:99`](../api/config/config.exs#L99)),
com retry — o padrão do [`AccessRevokedEmailJob`](../api/lib/api/accounts/access_revoked_email_job.ex).
**Lembrete por relógio**: cron no molde de [`Api.Notifications.Reminders`](../api/lib/api/notifications/reminders.ex),
que já resolve as duas coisas difíceis — "N horas antes" em **fuso da clínica** (ADR-009) e a
varredura por clínica **sob a GUC**, que é onde o RLS silenciosamente devolve vazio.

---

## 5. A resposta do paciente é um **link assinado**, não um "responda esta mensagem"

Canal-agnóstico de propósito: o mesmo link vai no corpo do e-mail (fase 1) e no botão do template
(fase 2). O paciente clica em **Confirmar** ou **Preciso remarcar**, e isso grava `resposta` na
mensagem.

O molde existe: é o magic link — token **selado**, apontando para o **web** e não para a API
(ADR-005), como em [`Emails.send_magic_link_email/2`](../api/lib/api/accounts/emails.ex). Aqui o
token é de propósito único (uma presença, uma ação), curto, e não abre sessão nenhuma.

E é isto que **fecha a F7** ([doc 30 §2](30-decisoes-pendentes-agenda.md)), aberta há meses porque
*"o que `confirmado` significa sem WhatsApp"* era indefinido: `confirmado` passa a significar **o
paciente respondeu que vem**. Com isso, `:patient_unconfirmed` deixa de estar bloqueada no
[doc 31 §4](31-notificacoes.md) — mas **não** entra nesta fatia (§13).

---

## 6. O que a recepção vê

**Uma linha do tempo no drawer**, sob os dados da sessão — em turma, agrupada por participante:

```
Ana Souza
  ✓ Confirmação enviada por e-mail · ter 14:02 · automático
  ✓ Entregue · ter 14:02
  ★ Confirmou presença · ter 18:41
João Lima
  ✓ Lembrete enviado por e-mail · qua 08:00 · automático
  ⚠ Falhou · e-mail inválido            [Reenviar]
Marta Reis
  — Nada enviado · sem e-mail cadastrado   [Adicionar e-mail]
```

A terceira linha é **obrigatória**, não decoração. Como a fase 1 só envia a quem tem e-mail
(C6), o caso "não foi enviado" é comum — e **silêncio é pior do que não ter a funcionalidade**:
a recepção passa a supor que saiu. O estado `:sem_canal` existe no modelo por isso, e é o único
que não gera linha em `Message` (não há mensagem; há a **ausência** dela, derivada do contato da
ficha na hora da leitura).

E o botão do rodapé **não some**: vira **"Reenviar agora"**, com o estado ao lado. Sem ele a
recepção fica sem saída em três casos comuns do balcão — agendamento criado 3h antes (a janela do
lembrete já passou), contato corrigido depois da falha, e "não recebi nada".

No **card** da agenda não entra nada: o `AN-01` está em dieta de sinais
([doc 50 §D12](50-leva-andreza-plano.md)) e texto novo lá desfaz o que aquela fatia acabou de
fazer.

**Esta tela é fase 1 e não muda na fase 2** — é ela o entregável que a recepção usa.

---

## 7. Configuração: por clínica, não por profissional

Em `/configuracoes`: canais ligados, gatilhos (**na criação** · **lembrete N horas antes**),
janela de silêncio (nada às 22h) e o texto do template. Por profissional vira matriz que ninguém
mantém.

Automático é o **padrão ligado**; o manual continua existindo como reenvio (§6).

---

## 8. Fase 1 — e-mail 100%, só para quem tem e-mail

Entra: domínio `Api.Messaging` + máquina de estados, job de envio, cron do lembrete, **Resend**
com webhook, link assinado de resposta, timeline no drawer (incluindo o `:sem_canal` do §6), tela
de configuração, trilha.

**E-mail não vira obrigatório** (C6). O campo segue opcional
([`patient.ex:208`](../api/lib/api/records/patient.ex#L208)): obrigar e-mail no balcão é atrito
por um canal que aqui é ponte, não destino. Quem tem, recebe; quem não tem, aparece como
"sem e-mail cadastrado" na timeline, com atalho para completar a ficha.

**A consequência que fica registrada:** numa clínica de balcão a cobertura de e-mail tende a ser
baixa e a de WhatsApp, quase total. Então **a fase 1 está certa como engenharia e é parcial como
operação** — ao fim dela o que está pronto é a espinha, provada ponta a ponta num canal barato,
não "a confirmação". Não anunciar à clínica como funcionalidade fechada.

Medir a cobertura real de e-mail na base é meia hora e vale antes de começar — não para mudar a
decisão, mas para saber de antemão quanto da timeline vai nascer com a linha "sem e-mail" e
calibrar o discurso.

## 9. Fase 2 — Gupshup, **antes de produção**

Decidido: a fase 2 não é "depois, quando der" — é **pré-requisito do go-live**, junto com
**telefone obrigatório** (D-H5, com o D6 na opção (b): obrigar na criação **e** no update, para o
legado se corrigir no fluxo natural, sem migração de dado).

É esse par que fecha a lacuna do §8: com telefone obrigatório e WhatsApp ligado, todo paciente
tem pelo menos um canal, e a timeline deixa de nascer com buracos. Em produção, portanto, o
`:sem_canal` do §6 vira **exceção**, não regra — mas continua existindo, porque paciente criado
antes da obrigatoriedade existe.

Troca-se o adapter de transporte e acrescenta-se o que o §2 listou: template HSM aprovado (**lead
time de dias na Meta** — submeter durante a fase 1, não depois dela), opt-out por palavra-chave,
telefone em E.164 (ninguém normaliza hoje) e webhook de entrada — que na fase 1 já terá rota,
assinatura, idempotência e resolução de tenant prontas.

**Ordem de canal quando o paciente tem os dois:** WhatsApp é o padrão, e-mail é a reserva (C8).

### 9.1 Um número da Cinetra ou um por clínica?

**Decidido: a v1 vai com um número único da Cinetra**, com o nome da clínica no template. Número
próprio da clínica é **funcionalidade futura** — algo que se oferece a quem pedir, *muito* depois,
e não um alvo para o qual estejamos migrando. O que 9.1.1 lista contra o compartilhado é real, mas
**9.1.5 mostra que a maior parte se dissolve** no nosso caso concreto: o risco depende de texto
livre, que a clínica não tem.

O 9.1.4 continua valendo — não porque a migração esteja no horizonte, mas porque são quatro coisas
baratas hoje e caras depois, e são elas que fazem a versão futura ser uma feature em vez de uma
refatoração.

> Detalhes de programa da Meta (nomes, faixas de limite, exigências de verificação) mudam de ano
> para ano. O raciocínio abaixo é estrutural e não depende deles; os números, confirmar com a
> Gupshup antes de fechar o contrato.

#### 9.1.1 O que pesa a favor de um número por clínica

1. **O paciente não conhece a Cinetra.** Ele tem relação com a *Clínica da Andreza*. Mensagem de
   remetente desconhecido é o gatilho nº 1 de "bloquear" e "denunciar spam" — e são exatamente as
   duas ações que a Meta pune. Dá para pôr o nome da clínica no **corpo** (e vamos pôr, §9.1.4),
   mas o nome do **remetente** é o que aparece na lista de conversas antes de abrir.
2. 🔴 **Qualidade e limite são por número, e o estrago é coletivo.** Se os pacientes de uma clínica
   bloquearem demais, a qualidade cai para **todas** que dividem o número — no limite, a
   confirmação de todo mundo para junto. É ponto único de falha **social**: não se conserta com
   código, nem com deploy.
3. **O opt-out fica global à força** (§10.1). Com um número, "SAIR" só resolve o telefone, não a
   clínica — o paciente que pediu para parar numa para de receber de todas. É defensável (ele vê
   um remetente só), mas é uma decisão tomada pela infra, não pelo produto.
4. **A janela de 24h é do par (número, pessoa).** Num número compartilhado, um paciente que
   escreveu para a clínica A abre a janela de texto livre para a clínica B. Nada vaza, mas o
   comportamento do sistema para B passa a depender do que aconteceu em A.
5. **A conversa é uma só.** Mensagens de duas clínicas diferentes na mesma thread do paciente.
   Não é vazamento (ele é paciente das duas), mas é confuso.

#### 9.1.2 O que pesa a favor de um número só

1. 🔴 **Onboarding.** Número próprio exige verificação de negócio na Meta e aprovação do nome de
   exibição, com a clínica no papel de titular. Muita clínica pequena de fisioterapia é MEI, não
   tem Business Manager e não vai querer atravessar isso para começar a usar o sistema. Isso
   transforma "criar conta e usar" em "espere alguns dias" — **é a objeção mais forte dos dois
   lados**, e é de produto, não de engenharia.
2. **Custo e operação.** Um número, um contrato, um lugar para configurar, um lugar para vigiar
   qualidade.
3. **Volume.** Faixas de envio são por número; poucas clínicas pequenas somadas cabem folgado.
4. **A clínica que não tem número.** Nem toda clínica quer dedicar uma linha só a isso.

#### 9.1.3 Onde isso morde de verdade

**Na clínica nº 2.** Com uma só (o piloto), o número "compartilhado" **é** o número dela: nada do
§9.1.1 acontece, porque não há com quem compartilhar. Todo o custo do número por clínica é real
hoje; todo o benefício só aparece depois.

E mesmo na clínica nº 2 ele morde menos do que parece, pelo motivo do §9.1.5. Por isso: **um
número da Cinetra na v1**, com nome de exibição que faça sentido para o paciente. Número próprio
entra **muito depois**, como funcionalidade a oferecer — quem quiser, e tiver Business Manager,
usa o seu.

#### 9.1.4 O que precisa ser verdade desde o primeiro dia

Quatro coisas baratas agora que, se ficarem para depois, transformam a versão "número da clínica"
de funcionalidade em refatoração:

- **o número é configuração por clínica**, desde já — um campo em `Clinic` apontando para o número,
  preenchido com o mesmo valor para todas. Assim "centralizar" vira **dado**, não arquitetura, e a
  clínica nº 2 é um `UPDATE`, não uma refatoração;
- **o nome da clínica vai em `vars` do template, sempre** — a primeira linha da mensagem diz de
  quem é. Num número compartilhado isso é o que evita o "quem é você?";
- **`OptOut.clinic_id` anulável** (C10): nulo = número compartilhado, preenchido = número próprio.
  A regra de resolução muda com a infra, o modelo não;
- **a resposta viaja no token do link** (§5), não na inferência pelo telefone. Texto livre é
  ambíguo num número compartilhado; o link carrega a presença, a clínica e a ação.

**A volta não é de graça:** trocar de compartilhado para próprio depois faz o paciente ver um
remetente novo, perder o histórico da conversa antiga e exige reinterpretar os opt-outs globais.
É reversível, não indolor — mais um motivo para o §9.1.4 valer desde o começo.

#### 9.1.5 Por que o template com o nome da clínica resolve a maior parte

O 9.1.1 está escrito como se o risco do número compartilhado fosse dado. Não é: ele depende de
**o que sai por aquele número**, e no nosso caso isso é estreito de propósito.

**A clínica não escreve.** Só saem os `kind` operacionais do §4, montados por nós, disparados por
um agendamento que existe. A clínica **não compõe texto livre** e não tem lista de transmissão.
Então o cenário que de fato derruba a qualidade de um número compartilhado — *uma clínica usar o
canal para promoção, ou disparar para quem nunca pediu* — **não está disponível para ela**. O
risco que sobra é o de uma mensagem esperada chegar a quem a espera, que é o perfil de menor
bloqueio que existe no WhatsApp.

Somando com o resto do desenho, cada item do 9.1.1 encolhe:

| Objeção (9.1.1) | O que sobra dela aqui |
| --- | --- |
| "Não conheço esse remetente" | O nome da clínica é a **primeira linha** do template, e a mensagem é sobre uma sessão que o paciente **acabou de marcar**. Sobra o instante entre ver a notificação e abri-la — mitigado pelo nome de exibição (9.1.6) e pelo aviso no balcão (§11.1) |
| Qualidade coletiva | Sobra só o risco de bloqueio individual, que é baixo em utility esperado. O cenário grave depende de texto livre, que a clínica não tem |
| Opt-out global | Continua global — e, com um remetente só, **é o que o paciente quer dizer** ao mandar SAIR. Deixa de ser efeito colateral e vira leitura correta |
| Janela de 24h cruzada | Só importa se usarmos texto livre dentro dela. Não usamos |
| Conversa única | Fica. É confusão leve, não vazamento |

**A condição que sustenta tudo isso é uma só, e vale escrever como regra:**

> Enquanto a clínica **não** puder compor mensagem livre por este canal, o número compartilhado é
> seguro. No dia em que "mandar mensagem para o paciente" virar funcionalidade, a conta muda —
> e a migração para número próprio deixa de ser opção e vira requisito.

#### 9.1.6 Nome de exibição

É a única parte do remetente que o paciente lê antes de abrir, então não é detalhe de marca: algo
como **"Cinetra Agendamentos"** diz o assunto para quem não conhece a marca. E o aviso no balcão
("vamos confirmar sua sessão pelo WhatsApp") — que o §11.1 já exige por causa da política da Meta —
é o que faz a primeira mensagem chegar esperada. Depois da primeira, o contato já é conhecido.

---

## 10. Opt-out: como não mandar para quem rejeitou

A pergunta parece de fase 2, mas **não é**: os três sinais de rejeição do e-mail chegam pelo
mesmo webhook do Resend que a fase 1 já monta (§2.1). Dá para projetar, construir e **provar** o
mecanismo inteiro em e-mail, e a fase 2 só acrescenta gatilhos à mesma tabela.

### 10.1 Três regras

**(1) O opt-out é nosso, não do provider.** A Gupshup tem gestão própria de opt-out, e ela não
basta por dois motivos: (i) a recepção precisa **ver na timeline** por que nada saiu — uma lista
que mora no provider é invisível na tela; (ii) somos multi-tenant, e uma lista no nível da conta
do provider vale para todas as clínicas de uma vez. Consultar a nossa antes de enfileirar é o
único jeito de a resposta ser legível e auditável.

**(2) A chave é o destino, não o paciente.** Opt-out é propriedade do **telefone/e-mail**, por
duas razões concretas:

- o webhook de entrada sabe o **número que respondeu**, não quem é o paciente — é o mesmo
  problema de "evento sem `clinic_id`" do §2, resolvido no mesmo lugar;
- um número serve **mais de uma ficha** no balcão (mãe e filho, casal). Se o "SAIR" ficasse
  preso à ficha que disparou, o outro paciente continuaria recebendo no mesmo aparelho — e é o
  aparelho que pediu para parar.

Recurso `Api.Messaging.OptOut`: `canal`, `destino` (normalizado — E.164 no WhatsApp,
*lowercase* no e-mail), `origem`, `motivo`, `criado_em`, `revogado_em`, `revogado_por_id`.

**Alcance por clínica ou global?** Depende de um fato de infra que a fase 2 vai fixar: se todas
as clínicas compartilham **um número** de WhatsApp, o paciente vê "Cinetra" e o "SAIR" só pode
ser entendido como global — não temos como perguntar de qual clínica ele fala. Com número por
clínica, o opt-out é por clínica naturalmente. Escrever a coluna `clinic_id` como **anulável**
(nulo = global) resolve os dois sem migração no meio do caminho.

**(3) Reverter é legítimo, mas com registro.** A política da Meta aceita opt-in obtido por
**qualquer canal** — inclusive "pode mandar no meu WhatsApp, sim" dito no balcão. Então a
recepção pode reativar, e é por isso que existem `revogado_em`/`revogado_por_id`: reativação sem
nome e hora é o tipo de coisa que ninguém consegue explicar depois.

### 10.2 De onde vem o sinal

| Canal | Sinal | Vira |
| --- | --- | --- |
| E-mail | link de descadastro (assinado, sem login — o molde do §5) | opt-out |
| E-mail | `email.complained` — marcou como spam | opt-out **imediato**, sem perguntar |
| E-mail | `email.bounced` **hard** | não é opt-out: é destino **inválido** → `:sem_canal` |
| WhatsApp | resposta com palavra-chave (`SAIR`, `PARE`, `STOP`, `CANCELAR`) | opt-out |
| WhatsApp | botão de opt-out no template, se o template tiver | opt-out |
| WhatsApp | erro de envio indicando que o usuário bloqueou/não é alcançável | opt-out **técnico** |

Sobre a última linha: os códigos exatos e o formato do evento de bloqueio **variam entre BSP e
versão da Cloud API**, e é o tipo de detalhe que envelhece — confirmar na documentação da Gupshup
na hora de implementar, não copiar daqui. O desenho não depende disso: qualquer erro da classe
"não entregável por decisão do usuário" grava a mesma linha.

Nota de escopo: o opt-out de **marketing** da Meta ("parar promoções") não cobre template de
categoria **utility**, que é a nossa (confirmação de sessão que o próprio paciente marcou). Ainda
assim honramos o "SAIR" para tudo — a política pede, e discutir com quem pediu para parar é uma
péssima ideia mesmo quando é permitido.

### 10.3 Onde a checagem mora

**Um lugar só**, no ponto que monta a lista de destinos antes de enfileirar — o mesmo que decide
o `:sem_canal` do §6. Ele resolve, em ordem: consentimento na ficha → destino existe? → opt-out?
→ canal. Espalhar essa checagem por gatilho é como se manda mensagem para quem pediu para parar.

Na timeline, os três casos são **linhas distintas**, nunca silêncio:

```
— Não enviado · paciente pediu para não receber WhatsApp (14/07)   [Reativar]
— Não enviado · sem consentimento de comunicação na ficha          [Abrir ficha]
— Não enviado · sem e-mail nem telefone cadastrado                 [Abrir ficha]
```

### 10.4 A reserva não pode virar contorno

Com WhatsApp como padrão e e-mail como reserva (C8), a regra "opt-out é por canal" cria uma saída
feia: o paciente responde **SAIR** no WhatsApp e a mesma mensagem chega por e-mail dez segundos
depois. Tecnicamente correto, e do lado de lá parece deboche.

Então a reserva distingue **por que** o canal preferido caiu:

| Motivo de o WhatsApp não servir | Cai para e-mail? |
| --- | --- |
| Não tem telefone cadastrado | ✅ sim |
| Falha técnica de entrega (número inválido, erro do BSP) | ✅ sim |
| **Opt-out explícito** — palavra-chave ou botão | ❌ **não.** Ele não disse "prefiro e-mail", disse **pare** |
| Bloqueou o número | ❌ não — é opt-out por gesto |

Quem pediu para parar só volta a receber se **pedir** (§10.1, regra 3), e por qualquer canal —
inclusive dizendo no balcão.

### 10.5 Granularidade: um opt-out por canal, não por tipo

Nada de "quero cancelamento mas não lembrete". Preferência fina é configuração que ninguém
mantém e que a recepção não consegue explicar ao telefone. O risco assumido: quem só queria
menos lembrete sai de tudo.

---

## 11. LGPD

- **Consentimento governa o envio.** Hoje são dois booleanos sem versionamento (D16/D19):
  `lgpd` e `comunicacao` ([`patient.ex:250-252`](../api/lib/api/records/patient.ex#L250)). Para a
  fase 1 eles bastam **se** o envio automático os respeitar de verdade; o histórico versionado é
  o D-H6 e continua fora.
- **`comunicacao` nasce `false` hoje** ([`patient.ex:252`](../api/lib/api/records/patient.ex#L252)),
  e com isso a fase 1 subiria sem mandar nada para ninguém. **Decidido (2026-07-27): o padrão
  passa a ser autorizado** — ainda não há produção, então não há base para corrigir nem migração
  de dado a fazer. O que sustenta a mudança está em 11.1; onde ela mora, em 11.2.
- **Opt-out por canal**, não global: "não quero WhatsApp" não é "não quero nada". O mecanismo
  inteiro está no §10.
- **Consentimento (ficha) e opt-out (canal) são coisas diferentes** e não se confundem: o
  primeiro é a clínica declarando que pode falar; o segundo é o paciente mandando parar. O
  segundo **sempre** vence, e não é apagável editando a ficha.
- **Retenção**: o corpo renderizado contém dado de paciente. Guardar `template` + `vars` e
  renderizar na leitura mantém o histórico legível sem duplicar dado sensível.
- A trilha (`TrailMixin`) cobre a mensagem como qualquer recurso.

### 11.1 Por que o padrão pode ser "autorizado" — e não é só porque não há produção

Não ter produção resolve o problema **operacional** (não há base para corrigir, nem marcação em
massa a construir — o C9 morre aí). Não é o que sustenta a decisão, porque o default vale para
**todo paciente novo, para sempre**. O que sustenta é o **tipo de mensagem**:

> Confirmar e lembrar de uma sessão que o próprio paciente marcou é **execução do serviço
> contratado** (LGPD, Art. 7º, V) — não é marketing, e não depende de consentimento. Exigir uma
> caixinha marcada para dizer "sua sessão é amanhã às 14h" é rigor no lugar errado: protege
> ninguém e quebra a funcionalidade.

Duas condições fazem essa leitura se sustentar, e as duas já estão no doc:

1. **o escopo não escorrega.** O que sai por este canal é operacional e ligado a um agendamento
   existente (`kind` do §4). Marketing, campanha, aniversário e "faz tempo que você não vem"
   **não entram** (§13) — e, se um dia entrarem, pedem **flag própria**, não o reúso desta.
   Reusar `comunicacao` para marketing é exatamente como se transforma uma decisão defensável em
   indefensável;
2. **opt-out sempre vence** (§10), e não é apagável editando a ficha.

**O WhatsApp acrescenta uma exigência que não é da LGPD, é da Meta:** a política de mensagens
pede opt-in para o canal. Ela aceita opt-in obtido por **qualquer meio**, inclusive o paciente
dando o número no balcão — desde que **avisado** de que será usado para confirmar as sessões.
Isso é **copy**, não código: uma linha na ficha e no agendamento. Sem essa linha, o default
autorizado fica de pé na LGPD e frágil na Meta (e o preço lá é qualidade do número, não multa).

### 11.2 Onde a mudança mora (o default do Ash não basta)

O formulário inicializa o campo em `false` e **sempre manda o valor** —
[`PatientForm.svelte:82`](../web/src/lib/components/patients/PatientForm.svelte#L82) e
[`:217`](../web/src/lib/components/patients/PatientForm.svelte#L217). Como todo paciente nasce
por essa tela, mudar só o `default:` do recurso não mudaria **nada** na prática.

São três lugares, e os três precisam concordar:

| Onde | Mudança |
| --- | --- |
| [`patient.ex:252`](../api/lib/api/records/patient.ex#L252) | `default: true` (+ migration; sem dado, é instantânea) |
| [`PatientForm.svelte:82`](../web/src/lib/components/patients/PatientForm.svelte#L82) | `patient?.comunicacao ?? true` — o `??` só vale na **criação**; na edição segue o que está salvo |
| A ficha e o rótulo | a caixa deixa de ser "autorizar" e passa a ser **"não quero receber"** na leitura da recepção — o texto ao lado precisa dizer o que sai por ali (confirmação e lembrete da sessão), senão desmarcar vira adivinhação |

O `lgpd` **não muda**: aquele é o termo de tratamento de dado, outro assunto, e continua `false`.

---

## 12. Decisões

Duas marcas diferentes na coluna de estado, e a diferença importa na hora de reabrir: **✅
decidido** é escolha humana tomada em 2026-07-27; sem marca é **recomendação deste doc**, aceita
por ausência de objeção — mexer nessas é barato, mexer nas primeiras é reabrir conversa.

| # | Decisão | Opções | Estado |
| --- | --- | --- | --- |
| **C1** | Onde ancora a mensagem | (a) presença; (b) agendamento | **(a)** — §3, mesmo raciocínio do D5/D13 |
| **C2** | Provider de e-mail | (a) Resend; (b) outro com webhook; (c) SMTP simples | ✅ **(a) decidido (2026-07-27)** — adapter já instalado, webhook Svix, §2.1 |
| **C3** | Resposta do paciente | (a) link assinado; (b) responder a mensagem; (c) sem resposta na fase 1 | **(a)** — canal-agnóstico e reusa o selado do magic link |
| **C4** | Rastreio de leitura no e-mail | (a) sem pixel; (b) com pixel | **(a)** — desproporcional; `opened`/`clicked` do Resend ficam desligados |
| **C5** | Reenvio manual | (a) botão vira "Reenviar agora"; (b) só automático | **(a)** — §6 |
| **C6** | E-mail obrigatório no paciente? | (a) não — envia só a quem tem; (b) sim | ✅ **(a) decidido (2026-07-27)** — com o `:sem_canal` visível na timeline (§6) |
| **C7** | Gatilhos da fase 1 | (a) criação + lembrete; (b) + remarcação/cancelamento | **(a)** — (b) é copy nova, não estrutura nova; entra fácil depois |
| **C8** | Paciente com e-mail **e** WhatsApp: qual canal? | (a) WhatsApp, com e-mail de reserva; (b) os dois sempre; (c) preferência na ficha | ✅ **(a) decidido (2026-07-27)** — **WhatsApp é o padrão**; e-mail é reserva, com a ressalva do §10.4 |
| **C9** | O `comunicacao: false` (§11) | (a) padrão passa a **autorizado**; (b) manter `false` + marcação em massa; (c) manter `false` e marcar uma a uma | ✅ **(a) decidido (2026-07-27)** — não há produção, então não há base a corrigir; e a base legal do operacional é execução de contrato, não consentimento (§11.1). **Depende da copy de aviso** (§11.1) e dos **três lugares** do §11.2 |
| **C10** | Alcance do opt-out (§10.1) | (a) por clínica; (b) global; (c) coluna `clinic_id` anulável | **(c)** — nulo = número compartilhado, preenchido = número próprio; segue o C11 sem migração |
| **C11** | Um número de WhatsApp da Cinetra ou um por clínica? (§9.1) | (a) um compartilhado, com o nome da clínica no template; (b) um por clínica; (c) compartilhado na v1, próprio como funcionalidade futura | ✅ **(a) na v1, com (c) como horizonte — decidido (2026-07-27).** O benefício de (b) só existe da clínica nº 2 em diante, o custo de onboarding (verificação Meta, clínica MEI sem Business Manager) é hoje, e o risco do compartilhado **depende de texto livre, que a clínica não tem** (§9.1.5). Número próprio é feature a oferecer, não migração planejada. Duas condições: os quatro itens do §9.1.4, e a regra do §9.1.5 — **se a clínica ganhar mensagem livre, número próprio deixa de ser opção e vira requisito** |

**Fora da tabela, decidido junto:** WhatsApp + **telefone obrigatório** entram **antes de
produção** (§9), o que fecha a lacuna de cobertura do §8.

---

## 13. O que **não** entra

- `:patient_unconfirmed` no sino (§5) — a F7 fica *destravada*, não *feita*;
- registro de oferta de vaga da fila por canal ([doc 50 §D11](50-leva-andreza-plano.md)) — é o
  mesmo modelo, mas outro fluxo;
- `Consent` versionado (D-H6);
- SMS, e comunicação avulsa fora de agendamento (marketing).

---

## 14. O que foi construído (2026-07-27)

A fase 1 inteira está de pé. **1258 testes no backend (90,2 %)** e **1592 no web (90,6 %)**, os
dois gates verdes. O que segue é o mapa, e as divergências do plano — que existem e estão
marcadas.

### 14.1 Backend (`api/`)

| Peça | Onde |
| --- | --- |
| Domínio + wrappers sob GUC | [`Api.Messaging`](../api/lib/api/messaging.ex) |
| A mensagem, ancorada na presença | [`Message`](../api/lib/api/messaging/message.ex) |
| Opt-out por destino, `clinic_id` anulável | [`OptOut`](../api/lib/api/messaging/opt_out.ex) |
| Máquina de entrega monotônica | [`MessageStatus`](../api/lib/api/messaging/message_status.ex) |
| Template + vars, versionado no nome | [`Templates`](../api/lib/api/messaging/templates.ex) |
| **A regra inteira, num lugar só** | [`Dispatch`](../api/lib/api/messaging/dispatch.ex) |
| Porta de saída por canal | [`Transport`](../api/lib/api/messaging/transport.ex) · [`PatientEmails`](../api/lib/api/messaging/patient_emails.ex) |
| Envio fora do request | [`SendJob`](../api/lib/api/messaging/send_job.ex) |
| Confirmação na criação (pós-commit) | [`Notifier`](../api/lib/api/messaging/notifier.ex) |
| Lembrete por relógio, **calado por padrão** | [`ReminderJob`](../api/lib/api/messaging/reminder_job.ex) |
| Assinatura Svix + eventos | [`Svix`](../api/lib/api/messaging/svix.ex) · [`Webhooks`](../api/lib/api/messaging/webhooks.ex) |
| Link assinado de resposta | [`ReplyToken`](../api/lib/api/messaging/reply_token.ex) |
| Fronteira | [`MessagesController`](../api/lib/api_web/controllers/messages_controller.ex) · [`PatientReplyController`](../api/lib/api_web/controllers/patient_reply_controller.ex) · [`ResendWebhookController`](../api/lib/api_web/controllers/resend_webhook_controller.ex) |

### 14.2 Web

- BFF [`server/messages.ts`](../web/src/lib/server/messages.ts) + o vocabulário em
  [`$lib/messages.ts`](../web/src/lib/messages.ts);
- [`MessageTimeline.svelte`](../web/src/lib/components/agenda/MessageTimeline.svelte) no drawer,
  buscada sob demanda por [`agenda/mensagens/[id]`](<../web/src/routes/(app)/agenda/mensagens/[id]/+server.ts>);
- **o botão parou de mentir**: o `onToast('Confirmação enviada por WhatsApp')` virou a action
  `?/confirmar` ([D-H4 fechado](37-homologacao-andreza.md));
- página pública [`/confirmar/[token]`](<../web/src/routes/confirmar/[token]/+page.svelte>);
- tela [`/configuracoes/comunicacao`](<../web/src/routes/(app)/configuracoes/comunicacao/+page.svelte>);
- `comunicacao` nasce marcado, com o rótulo reescrito (§11.2 — os três lugares).

### 14.3 O bate-volta, e o que ele achou

A auditoria está em [`60-bate-volta-comunicacao.md`](60-bate-volta-comunicacao.md). Nove
causas-raiz; oito corrigidas. **A mais grave só apareceu dirigindo o app**: a rota pública de
resposta do paciente (§5) estava **morta em produção** — lia sem GUC, a RLS não casava linha, e
todo link legítimo respondia "link inválido", com os 7 testes da rota verdes (o sandbox bypassa
RLS). Era o irmão do problema do webhook, que já tinha exceção; o erro foi não ver que eram dois
caminhos, não um.

Também saíram de lá: o I/O do provider que rodava **dentro** da transação da GUC, e o índice que
faltava para o cron de lembrete — 134,8 ms e 16.863 buffers para devolver 15 linhas, agora
0,082 ms.

### 14.4 O que mudou em relação ao plano

**Sem `AshPaperTrail` em `Message`/`OptOut`** (o §11 dizia que a trilha cobriria). O registro
**é** o histórico: `disparado_por_id` diz quem mandou, cada estado tem carimbo próprio e a
revogação grava `revogado_por_id`. A trilha nasceria com ~4× as linhas da tabela que mais vai
crescer (2–4 updates de webhook por mensagem) para gravar o que já está gravado — o doc 43 §5f
mediu esse padrão em 3× a tabela base e ele virou poda diária.

**Uma exceção nova na RLS**, e ela não estava prevista. O evento do provider chega **sem
`clinic_id`**; a busca por `provider_message_id` é a que descobre o tenant, e roda sem GUC — a
policy de `messages` não casaria linha nenhuma. O webhook responderia 200 sem fazer nada, para
sempre, **verde no `mix test`** (o sandbox bypassa RLS). Resolvido com
[`Api.Repo.with_provider_message/2`](../api/lib/api/repo.ex) + a policy da migration
[`MessagesWebhookLookup`](../api/priv/repo/migrations/20260728020000_messages_webhook_lookup.exs):
alcança **uma** linha, já identificada por um payload autenticado. As alternativas descartadas
estão no moduledoc da migration.

Isto é exatamente o que o §2 previa que só apareceria escrevendo o webhook — e é o argumento
para tê-lo feito na fase 1, quando o custo de descobrir é baixo.

**Dois bugs que os testes pegaram** e que valem registro por serem da mesma família:

- o `SendJob` lia a mensagem **sem `tenant:`** e saía calado sem enviar nada. `tenant:` (filtro do
  Ash) e GUC (RLS) são coisas diferentes: faltar o primeiro dá erro alto, faltar o segundo devolve
  vazio em silêncio;
- `set_attribute(:campo, expr(now()))` só é avaliado no caminho **atômico**. Fora dele o Ash tenta
  gravar a expressão como valor e recusa o cast, com um erro que não aponta para a causa
  ("Could not cast input to datetime. Value: now()").

### 14.5 O que falta para ligar de verdade

Nada disto é código:

1. **`RESEND_API_KEY` e `RESEND_WEBHOOK_SECRET`** no `.env` (modelo em `.env.example`). Sem eles o
   sistema sobe normal e o e-mail cai em `/dev/mailbox`;
2. **domínio verificado** no Resend (SPF/DKIM/DMARC) e o `MAIL_FROM` apontando para ele. É o item
   de lead time da fase 1 — e conserta de tabela o remetente dos e-mails de acesso, que hoje sairiam
   de `movimento.local`;
3. **URL pública para o webhook** (túnel em dev; em produção, `<host>/webhooks/resend`);
4. **ligar o lembrete** em `/configuracoes/comunicacao` — nasce desligado de propósito;
5. **submeter o template HSM à Meta** durante a fase 1, não depois (§9).
