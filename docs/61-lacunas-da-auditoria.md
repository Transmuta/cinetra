# 61 — O que falta na auditoria

> Análise de lacuna, 2026-07-28. Não é plano de execução nem fatia: é o inventário do que a
> trilha **não** responde hoje, com o custo de fechar cada buraco e as decisões que precisam
> ser tomadas antes de codar.
>
> Ponto de partida: a pergunta "falta paciente e profissional, as mudanças neles?".
> **Resposta curta: sim — e está registrado como decisão consciente, não como esquecimento**
> ([`25 §11.4`](25-agenda.md), A-D14). Mas a lista é maior do que dois recursos, e há duas
> lacunas de **natureza diferente** que a pergunta não alcança (trilha de *leitura* e de
> *autorização negada*).

---

## 1. O que a trilha cobre hoje — medido, não suposto

Dois recursos, e mais nada:

| Recurso | Extensão | Onde |
|---|---|---|
| `Api.Scheduling.Appointment` | `AshPaperTrail.Resource` + `mixin TrailMixin` | [`appointment.ex`](../api/lib/api/scheduling/appointment.ex) |
| `Api.Scheduling.Attendance` | idem | [`attendance.ex`](../api/lib/api/scheduling/attendance.ex) |

Confirmado por três lugares independentes que teriam de concordar e concordam:
`grep AshPaperTrail lib/` acha só esses dois, o `@tabelas` de
[`PruneTrail`](../api/lib/api/housekeeping/prune_trail.ex) lista
`appointments_versions attendances_versions`, e `parseResource` em
[`web/src/lib/audit.ts`](../web/src/lib/audit.ts) devolve `'appointment' | 'attendance'` e nada
mais.

Duas ausências que **são decisão e estão documentadas no próprio recurso**, e por isso não
entram na lista de lacunas abaixo: `Api.Messaging.Message` e `Api.Messaging.OptOut` não têm
trilha porque *o registro já é o histórico* (uma mensagem é imutável depois de enviada; um
opt-out é uma linha por evento).

---

## 2. A lacuna que a pergunta acerta — as escritas não versionadas

O A-D14 fechou em "só a agenda por ora" e nomeou quatro candidatos. Passados sete dias de
construção, a lista real é **sete**. Em ordem de risco, não de esforço:

### (a) `Membership` — quem deu e quem tirou acesso

O mais sensível dos sete, e o próprio doc 25 já dizia isso: *"quando `Membership` entrar (a
mais sensível das quatro — 'quem promoveu Fulano a admin?')"*. Hoje, `update :update`
(troca de `papel`) e `destroy :revoke_access` ([`membership.ex`](../api/lib/api/accounts/membership.ex))
não deixam rastro nenhum. Um owner que rebaixa outro owner, ou uma revogação de acesso na
véspera de uma demissão, é **invisível** — e é justamente o evento que uma auditoria de
verdade existe para responder.

Agravante próprio: `revoke_access` é um `destroy`. Sem trilha, o registro some inteiro — não
há nem o "estado final" para inferir o que houve, ao contrário de um `update`.

### (b) `Patient` — a ficha e o consentimento

[`patient.ex`](../api/lib/api/records/patient.ex): `create`, `update`, `deactivate`,
`reactivate`. Nenhuma versionada. O que se perde:

- **A ficha inteira** — 38 colunas, incluindo `cpf`, `rg`, `convenio`/`carteirinha`,
  `medico`/`crm` (que o D17 tratou como o campo de acesso restrito) e `emergencia_*`;
- **O consentimento** — `lgpd` e `comunicacao` são booleanos no próprio `Patient`. O
  [`06 §4`](06-seguranca-e-lgpd.md) lista *"consentimento: concessão e revogação"* como evento
  auditável **por nome**. Hoje um `false → true` no `lgpd` é indistinguível de nunca ter sido
  tocado: existe só o valor atual. Isso não é conveniência de UI, é o que se apresenta à ANPD
  para provar a base legal;
- **O arquivamento** — `deactivate` some da lista sem dizer quem.

### (c) `Professional` — os dados bancários, citados nominalmente

[`professional.ex`](../api/lib/api/directory/professional.ex) tem `banco`, `agencia`, `conta`,
`conta_tipo`, `pix`, `cnpj`, `razao_social`. O [`06 §4`](06-seguranca-e-lgpd.md) cita
*"alterar dados bancários do profissional"* na mesma frase em que cita editar paciente — é um
dos exemplos originais do que a trilha deveria pegar. É também o único campo do sistema onde a
alteração tem **efeito financeiro direto** (o repasse cai em outra conta) e onde a fraude é
trivialmente lucrativa. Hoje, quem trocou o PIX é impossível de responder.

### (d) `ClinicHours` / `ScheduleException` — o expediente

Mudar o horário de funcionamento ou lançar um feriado **reescreve o que é conflito e o que é
fora de expediente** para a clínica inteira, e o motor de pacotes (D14: fora de expediente é
bloqueio absoluto) lê essas tabelas. Uma materialização que "deu errado" quase sempre é uma
mudança de expediente que ninguém lembra de ter feito. Sem trilha, a conversa não tem prova.

### (e) `AppointmentType` — duração e preço

Arquivar um tipo, mudar a duração, mudar o preço. O efeito é sobre agendamentos futuros e
sobre o que a recepção cobra. Menor risco que os anteriores, mas mesma classe.

### (f) `Clinic` — CNPJ, razão social, endereço

`update_info`. Baixo volume, alto impacto (é o que sai em documento). Barato de ligar.

### (g) `Package` / `WaitlistEntry`

Pausar, cancelar e retomar pacote muda o que o paciente tem direito a receber; a fila tem
`obs` operacional e prioridade. Ambos são "escrita de negócio sem rastro", mas com dano
contido — e o `Package` é parcialmente reconstituível pelas `Attendance` que ele materializa,
que **são** versionadas.

---

## 3. As duas lacunas de outra natureza — e a pergunta não as alcança

### (a) A trilha de **leitura** existe, é gravada, e ninguém consegue lê-la

O [`06 §4`](06-seguranca-e-lgpd.md) é explícito: *"acesso a dado de saúde é auditável — **não
só a escrita, a leitura também**"*, e nomeia três eventos: abrir a ficha completa, gerar o
dossiê, **baixar um anexo**.

Um dos três foi construído. [`Api.Records.AttachmentEvent`](../api/lib/api/records/attachment_event.ex)
grava `:visualizou` no instante em que a URL assinada é emitida — o desenho está certo, é
tabela própria (PaperTrail não registra leitura) e sobrevive à remoção do anexo.

**Só que não há como consultá-la.** `Api.Records.list_clinic_attachment_events/2` existe no
domínio; nenhum controller a chama, e `grep attachment_event` em `api/lib/api_web` e em
`web/src` não devolve **uma linha**. O router tem `GET /audit` e mais nada. Ou seja: a
clínica paga o `INSERT` a cada download e a resposta a *"quem leu o laudo da Maria?"* só sai
por `psql`.

Isso é a lacuna mais barata de fechar da lista inteira (o dado já está lá) e a de maior
retorno em conformidade.

Os outros dois eventos do §4 — **abrir a ficha** e o **dossiê** — não gravam nada. O dossiê
nem existe (é a fatia F8 / D-1, adiada por bloqueio jurídico).

### (b) Autorização negada não deixa rastro

Quarto bullet do [`06 §4`](06-seguranca-e-lgpd.md): *"toda vez que uma policy bloqueia acesso a
dado sensível […] isso alimenta detecção de abuso"*. Hoje um `Ash.Error.Forbidden` vira 403 na
resposta e some. Não há como detectar alguém varrendo a clínica vizinha por IDOR — e o projeto
já **achou** um IDOR real desse tipo (`/api/availability`, T-P1). O achado veio de auditoria
manual; nada no sistema o teria acusado sozinho.

---

## 4. A lacuna estrutural: o feed é **por recurso**, não da clínica

Esta não aparece em nenhuma lista de pendências e é a que mais atrapalha ligar os sete
recursos da §2.

`Api.Scheduling.list_audit_log/2` recebe `resource: :appointment | :attendance` e pagina **uma**
tabela de versão ([`scheduling.ex`](../api/lib/api/scheduling.ex), `page_versions/5`). A tela
espelha isso: o filtro de recurso é um eixo que **troca** qual tabela é lida.

Com dois recursos irmãos isso passa. Com nove, quebra em três frentes:

1. **Não existe "o que aconteceu na clínica hoje"** — a pergunta que um admin de fato faz. Ele
   teria que visitar nove abas, cada uma com sua própria paginação, e reordenar de cabeça;
2. **Cada recurso novo é uma `enrich_versions/3` nova** — o enriquecimento (autor, paciente,
   profissional, o diff encadeado) é escrito por recurso, com cláusulas próprias. Sete cópias
   do mesmo formato;
3. **Um feed cronológico unificado sobre nove tabelas é `UNION ALL` + `ORDER BY` + `LIMIT`** — o
   plano lê `offset + limit` de **cada** tabela antes de mesclar. Na tabela que mais cresce do
   sistema, isso é decisão de arquitetura, não detalhe de implementação.

**A alternativa é uma tabela de eventos única** (uma linha por escrita auditável, com
`resource` como coluna), no molde do que `AttachmentEvent` já faz para leitura — e aí o
PaperTrail vira o *mecanismo de captura*, não o modelo de consulta. Isso precisa ser decidido
**antes** do primeiro recurso novo entrar, porque é o tipo de escolha que fica cara depois de
três.

---

## 5. O que custa ligar um recurso — o checklist real, tirado do código

Não é "adicionar a extensão". São sete pontos, todos verificáveis no que já existe:

| # | Ponto | Por quê |
|---|---|---|
| 1 | `extensions: [AshPaperTrail.Resource]` + bloco `paper_trail` + `mixin TrailMixin` | O mixin traz as policies owner·admin e o `read :audit_log` paginado |
| 2 | `clinic_id` em `attributes_as_attributes` | Sem coluna real, o RLS não tem o que filtrar — armadilha (1) do [`25 §11.2`](25-agenda.md) |
| 3 | Migration da tabela **+ política de RLS própria**, no molde de [`20260719200000_agenda_constraint_and_rls.exs`](../api/priv/repo/migrations/20260719200000_agenda_constraint_and_rls.exs) | `mix test` conecta como `postgres` (BYPASSRLS): furo aqui passa **verde** |
| 4 | Índice `(clinic_id, version_inserted_at DESC)` e `(clinic_id, version_source_id)` | Feed e histórico de um registro |
| 5 | `@tabelas` de [`PruneTrail`](../api/lib/api/housekeeping/prune_trail.ex) | Lista explícita por decisão; esquecer = trilha que nunca poda |
| 6 | `enrich_versions/3` no domínio + `@audit_actions` do [`audit_controller.ex`](../api/lib/api_web/controllers/audit_controller.ex) | A whitelist precisa ser **completa**: nome de fora vira filtro `nil` e o feed inteiro volta sem 422. Há teste que a segura contra `Ash.Resource.Info.actions/1` — estendê-lo ao recurso novo |
| 7 | `ACTION_LABELS` + `HEADLINES` + `parseResource` + o filtro na tela | Sem tradução, a recepção vê nome de coluna e átomo cru |

Mais os dois débitos já abertos que **um recurso novo agrava**:
[`D-Aud1`](30-decisoes-pendentes-agenda.md) (o feed não tem total) e **`D-Aud2`** — o filtro por
autor faz Seq Scan por falta de índice, e ele só não dói hoje porque *a UI não o expõe*. Um
feed unificado da clínica torna "por autor" o filtro mais usado da tela.

---

## 6. As três armadilhas específicas de `Patient` e `Professional`

Ligar a trilha nesses dois não é o mesmo trabalho que ligar em `Clinic`. Três coisas mudam:

**(a) A trilha passa a guardar CPF, RG e conta bancária em claro.** O `:changes_only` grava só
o que mudou, mas quem corrigiu um CPF gravou o CPF. O [`06 §4`](06-seguranca-e-lgpd.md) tem um
aviso escrito para exatamente isso: *"o diff sobre um campo cifrado não pode guardar o valor em
claro, senão a trilha vira a maior fuga de dado do sistema"*. Hoje o aviso é teórico — não há cifra de campo hoje (o D18 reverteu o
[`06 §3.1`](06-seguranca-e-lgpd.md)) — mas o efeito colateral é real: dado
sensível passa a existir em **duas** tabelas, e a segunda é append-only e retida por 365 dias.

A mitigação óbvia (`ignore_attributes [:cpf, :rg, :conta, :pix]`) **destrói justamente o caso
de uso**: a mudança do PIX é o evento que se quer auditar. O caminho provável é uma terceira
opção — registrar *que* o campo mudou sem os valores — e isso **o AshPaperTrail não faz
sozinho**.

**(b) A exclusão LGPD fica maior.** O D-1 / F8 (hard delete ancorado no paciente, adiado por
bloqueio jurídico) hoje tem que podar 2 tabelas de versão. Com `Patient` versionado, passa a
ter que podar a trilha do próprio titular — que é onde o dado dele vai estar em cópia. Não
inviabiliza, mas **muda o desenho da fatia adiada**, e ela ficará mais cara quanto mais tarde
essa decisão for tomada.

**(c) O recorte de leitura do `Professional` não vale para a versão.** `OwnProfessionalOnly`
filtra a `:read` do `Professional` para o papel `profissional` (T-P1). O recurso de versão é
outro recurso: essa preparation **não** o alcança. O `TrailMixin` cobre isso por acidente feliz
(a trilha inteira é owner·admin), mas é a mesma classe da armadilha (3) do §11.2 e precisa de
teste explícito, não de confiança.

---

## 7. O custo do adiamento — o que já se perdeu

O A-D14 registrou a frase certa: *"a lacuna é **assimétrica no tempo**: ligar cedo custa uma
migration; ligar tarde custa o passado."*

Aplicada a hoje: as fichas de paciente e profissional cadastradas até agora, os papéis
concedidos, os PIX preenchidos e os consentimentos marcados **não têm histórico e nunca
terão**. Qualquer trilha que se ligue amanhã começa do zero, e a tela mostrará "sem atividade"
para tudo o que aconteceu até a data da migration — que é a leitura mais perigosa possível de
uma auditoria (silêncio lido como ausência de evento).

Isso não é argumento para ligar tudo às pressas. É argumento para **decidir a ordem agora** e
para ligar primeiro o que é irrecuperável e sensível (`Membership`, `Professional`), mesmo que
a tela só ganhe a aba depois — exatamente como o próprio projeto separou "gravar" de "exibir"
na Entrega 1.

---

## 8. Recomendação de recorte

Se isso virar fatia, sugiro esta ordem — cada item é entregável sozinho:

| Ordem | O quê | Por quê primeiro |
|---|---|---|
| 0 | **Decidir o §4** (feed por recurso × tabela de eventos única) | É a escolha que fica cara depois de três recursos |
| 1 | **Expor `AttachmentEvent`** (`GET /api/audit/attachments` + aba na tela) | O dado já é gravado; é a única lacuna que não custa migration nem schema |
| 2 | **`Membership`** | Irrecuperável, o mais sensível, e o `destroy` some inteiro |
| 3 | **`Professional`** | Dados bancários; resolver antes a armadilha (a) do §6 |
| 4 | **`Patient`** + consentimento | O maior volume e o que interage com o D-1 |
| 5 | `ClinicHours`/`ScheduleException`, `AppointmentType`, `Clinic` | Baratos, mesma receita |
| — | `Package`, `WaitlistEntry` | Dano contido; entram quando o resto estiver de pé |
| — | **Autorização negada** (§3b) | Fatia própria: não é PaperTrail, é log de segurança + onde ele mora |

---

## 9. O que precisa de decisão humana antes de qualquer código

1. **§4** — feed por recurso (nove abas) ou tabela de eventos única (um feed cronológico da
   clínica)? Custo e forma da tela mudam por completo.
2. **§6a** — a trilha de `Patient`/`Professional` guarda o valor dos campos sensíveis, ignora
   esses campos, ou registra "mudou" sem valor? As três têm preço, e nenhuma é neutra.
3. **Retenção** — o P2 fechou em "guardar para sempre, com poda de 365 dias". Vale igual para
   uma trilha que passa a conter CPF e conta bancária?
4. **Leitura de ficha** (`06 §4`) — auditar abrir a ficha do paciente é **um `INSERT` por
   abertura de tela**, na operação mais frequente da recepção. É requisito escrito; é também o
   maior custo de escrita que o sistema ganharia. Precisa de decisão explícita, não de
   implementação silenciosa.
