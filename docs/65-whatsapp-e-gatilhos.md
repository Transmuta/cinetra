# 65 — Fase 2 da comunicação: WhatsApp (Zernio), gatilhos do C7(b) e a resposta no sino

Fecha o que o [doc 52](52-comunicacao-com-o-paciente.md) deixou explicitamente para "fora da fase
1": o **canal de WhatsApp**, o **telefone obrigatório**, os **gatilhos de remarcação/cancelamento**
e — do outro lado — a única notificação in-app cujo autor não tem login: o paciente que responde
*"preciso remarcar"*.

Entregue em 2026-07-28. Escrito depois de medir o que já existia: metade do que parecia faltar
estava construído e desligado.

---

## 1. O que faltava, e o que só parecia faltar

O levantamento antes de escrever qualquer linha:

| Peça | Estado antes |
| --- | --- |
| Ordem de canal WhatsApp → e-mail (C8) | **já existia** — `Api.Messaging.Dispatch.escolher_canal/2`, inclusive com o §10.4 (opt-out não cai para a reserva) |
| Normalização E.164 do telefone | **já existia** — `Dispatch.normalizar(:whatsapp, _)` |
| Templates de remarcação e cancelamento | **já existiam** — `remarcacao_v1` e `cancelamento_v1`, renderizando e-mail |
| `:lido` na máquina de entrega | **já existia**, sem nunca ser alcançado (o e-mail não tem leitura, C4) |
| Webhook: assinatura, idempotência, descoberta de tenant | **já existia** para o Resend, e foi reusado inteiro |
| Transporte de WhatsApp | não existia |
| Gatilhos de remarcação/cancelamento | não existiam (o `Notifier` só ouvia `:schedule`/`:add_participant`) |
| Telefone obrigatório | não existia |
| Resposta do paciente chegando a alguém | **não existia** — ficava só na timeline daquele bloco |

A aposta do doc 52 §2 — *"exercitar o webhook já na fase 1 paga a fase 2"* — se confirmou: o que
não se descobre sem escrever (rota pública, assinatura, resolução de tenant sem `clinic_id`,
exceção estreita da RLS) já estava de pé. O que a fase 2 acrescentou foi um mapa de nomes de
evento e um cliente HTTP.

---

## 2. Decisões

Tomadas em 2026-07-28, com as opções que estavam na mesa.

| # | Decisão | Opções | Resultado |
| --- | --- | --- | --- |
| **W1** | Provider de WhatsApp | (a) Gupshup (o que o doc 52 §9 supunha); (b) Zernio; (c) Meta Cloud API direto | ✅ **(b) Zernio** — decisão do dono do produto. O doc 52 §9 falava em Gupshup; a troca não mexeu em nada além do adapter, que é exatamente o que o §2 previa ao isolar o transporte |
| **W2** | Construir com ou sem conta | (a) às cegas, atrás da flag; (b) com credencial, validando ao vivo | ✅ **(a)** — não há conta ainda. As três incertezas que só a primeira chamada real fecha estão no §6 |
| **W3** | Domínio do botão do template | (a) só `cinetra.com.br`; (b) um template por ambiente; (c) link no corpo, sem botão | ✅ **(a)** — o HML não manda WhatsApp (testa por e-mail e pelo sandbox). Duas aprovações seriam duas filas na Meta, e o que se testaria no HML não seria o que roda em produção |
| **W4** | Telefone obrigatório: aceitar fixo? | (a) qualquer número válido; (b) exigir celular; (c) aceitar avisando | ✅ **(a) com o aviso de (c)** — exigir celular empurraria a recepção a inventar número para salvar a ficha de quem só tem fixo: dado pior para regra mais bonita. O fixo entra, não é candidato a WhatsApp, e o formulário diz isso na hora |
| **W5** | Resposta do paciente no sino | (a) só "quer remarcar"; (b) as duas respostas; (c) (a) + resumo diário de não-confirmados | ✅ **(a)** → recepção/admin/owner. "Confirmou" já aparece no status do bloco e na timeline; uma linha por confirmação afogaria a caixa numa clínica com ~2.200 presenças/mês |
| **W6** | Gatilhos do C7(b) | remarcação · cancelamento · exclusão · falta | ✅ **remarcação e cancelamento**. Falta ficou de fora: "você faltou ontem" põe cobrança no canal, e é o tipo de mensagem que faz bloquear o número |
| **W7** | Excluir avisa igual a cancelar? | (a) não avisar; (b) avisar com a copy do cancelamento | ✅ **(a)**. Chegou a ser ligado como (b) e foi **removido no mesmo dia**, antes de qualquer uso real — ver §8 |

---

## 3. O transporte, e o que a API da Zernio impõe

`POST /v1/inbox/conversations` — e não o endpoint de mandar mensagem numa conversa. A razão é da
Meta, não da Zernio: **o WhatsApp não permite texto livre para abrir conversa**. Fora da janela de
24 h só sai template HSM aprovado, e é isso que toda mensagem nossa é.

Chamar o mesmo endpoint para um número com quem já existe thread manda o template para dentro
dela. Um caminho só, com ou sem conversa aberta — é o que dispensa guardar `conversationId` e o
que faz a reabertura depois das 24 h não ser caso especial.

### 3.1 A ordem das posicionais é contrato, e não tem erro de retorno

`templateParams` é uma **lista plana, sem nomes**: cabeçalho, corpo, e um valor por botão de URL
dinâmica. Se a ordem daqui divergir da ordem aprovada na Meta, a mensagem sai com a data no lugar
do nome — **e a API aceita**, porque a contagem bate. Não há código de erro para esse defeito; o
sintoma é um paciente confuso, dias depois.

Por isso o corpo aprovado e a ordem moram na **mesma definição**
([`Api.Messaging.Templates`](../api/lib/api/messaging/templates.ex)), e o teste que os protege lê
o corpo do template e confere que cada `{{n}}` recebe o que aquela posição promete — em vez de
comparar com uma lista literal, que seria a mesma ordem copiada, divergindo junto.

### 3.2 O texto do WhatsApp não é o texto do e-mail

A Meta recusa template que comece ou termine com variável, e recusa duas variáveis coladas. O
e-mail é livre disso. Gerar os dois de uma fonte só produziria ou um e-mail torto ou um template
reprovado — e a reprovação leva dias para descobrir. São dois textos, com um teste que verifica as
três regras da Meta antes de alguém gastar a fila de aprovação.

### 3.3 Seis templates

`confirmacao_v1`, `lembrete_v1`, `remarcacao_v1` e `cancelamento_v1` (os quatro que já existiam),
mais `pacote_remarcado_v1` e `pacote_cancelado_v1` — os dois de **lote**, que existem pela mesma
razão que o `:package_bulk_adjusted` do sino (doc 43 §5b) e por uma pior: remarcar um pacote de 40
mandaria 40 mensagens **pagas** para o mesmo telefone em segundos. É assim que se perde um número
por bloqueio (§9.1.1 do doc 52).

Submissão: `mix cinetra.whatsapp.templates` (mostra) / `--enviar` (submete). O padrão é **não
enviar**, e a task recusa enviar sem credencial ou com `WEB_APP_URL` de dev — o domínio fica
congelado no template aprovado, então um botão com `localhost` só se conserta criando `_v2`.

---

## 4. O webhook: o que muda em relação ao Resend

Mesmo módulo (`Api.Messaging.Webhooks`), porque o problema central é o mesmo: **o evento chega sem
tenant**, e quem o descobre é a busca pelo id do provider, sob a exceção estreita da RLS.

O que muda:

| Eixo | Resend (Svix) | Zernio |
| --- | --- | --- |
| Assinatura | HMAC-SHA256 de `id.timestamp.corpo`, base64, header `svix-signature` | HMAC-SHA256 do **corpo cru**, hex minúsculo, header `x-zernio-signature` |
| Janela de tempo | 5 min de tolerância | **não existe** |
| Reentrega | até receber 2xx | 7 tentativas, até 24 h; ack em **5 s** |
| Estados | `delivered`, `bounced`, `complained` | `delivered`, `read`, `failed` — e `read` é o `:lido` que o e-mail nunca alcança |
| Entrada do paciente | não há | `message.received` → opt-out por palavra-chave |

### 4.1 A ausência de timestamp é um buraco de replay, e está nomeada

Sem timestamp no material assinado, **um payload capturado continua válido para sempre**. O que
sobra de proteção é o efeito ser idempotente por construção (avanço monotônico de estado, opt-out
verificado antes de gravar). Replay não muda o banco — o que **não** é o mesmo que dizer que é
seguro.

A regra que fica: **acrescentar um evento da Zernio com efeito não-idempotente exige antes uma
tabela de `id` de evento já visto.** Está escrita no moduledoc de
[`ZernioSignature`](../api/lib/api/messaging/zernio_signature.ex), que é onde alguém vai olhar.

### 4.2 Opt-out por palavra-chave: a mensagem inteira, não a palavra dentro dela

`SAIR`, `PARE`, `STOP`, `CANCELAR`… — e o teste que decidiu a regra é este:

> *"por favor, não pare de mandar os lembretes"*

contém `pare` como palavra inteira e quer dizer o **oposto**. Silenciar quem pediu para continuar é
o pior dos dois erros possíveis, porque é invisível: a pessoa simplesmente para de receber e
ninguém sabe por quê. A comparação é com a mensagem inteira normalizada, que é também a convenção
do canal.

---

## 5. A resposta do paciente chega em alguém

Até aqui, um paciente que clicava em "Preciso remarcar" só era descoberto por quem abrisse o drawer
daquela sessão. O pedido agora vai à caixa do operacional
(`Api.Notifications.Fanout.patient_wants_reschedule/1`).

É o item que o doc 31 §3d listava como bloqueado pela **F7** (*"o que 'confirmar' significa sem
WhatsApp está indefinido"*). A F7 fechou com o doc 52; este é o evento que ela destravou, e ninguém
tinha voltado para pegá-lo.

Três particularidades:

* **é a única notificação do sistema cujo autor não tem login** — não há autor a suprimir, e a
  lista de destinatários é montada direto em vez de depender de `deliver?/2` comparar com `nil`;
* **vai ao operacional, não ao profissional dono da coluna** — ele não opera a agenda, e para ele
  isto seria aviso sem ação. O aviso dele vem depois, quando a recepção de fato remarcar
  (`:appointment_rescheduled`, que já existia);
* **o fan-out roda fora da transação da resposta** — de dentro, a notificação sairia antes do
  commit (a armadilha que fez o `Api.Notifications.Notifier` existir) e a transação do paciente
  ficaria aberta pelo tempo de escrever a caixa de todo mundo.

---

## 6. As três incertezas que só a primeira chamada real fecha

Construído às cegas (W2), então isto aqui é a lista honesta do que **não** está provado:

1. **A URL base.** A doc diz "Base URL `https://zernio.com/api/v1`" e escreve os caminhos como
   `/v1/inbox/conversations`. Se o `/v1` for duplicado, todo envio responde 404 — e o sintoma
   aparece como "Não conseguimos entregar a mensagem" na timeline. `ZERNIO_BASE_URL` existe no
   ambiente justamente para consertar isso sem deploy.
2. **`data.messageId` casa com `message.id` do webhook?** É a chave que liga o envio ao evento de
   entrega. A doc chama um de "Platform message ID (dm_event_id)" e o outro do id interno da
   Zernio. Se divergirem, **nenhum evento de entrega acha a linha** e toda mensagem fica parada em
   `:enviado` para sempre. Mitigado: o webhook tenta quatro campos plausíveis antes de desistir.
3. **O formato de `message.failed`.** Os códigos da Meta (131021, 131049, 131026…) são repassados,
   mas o caminho exato dentro do payload é suposição — daí a leitura por vários caminhos e a
   tradução casando por número, que é o que menos muda.

Uma quarta, menor: `Idempotency-Key` é documentado em vários endpoints de escrita, mas não neste.
Mandamos assim mesmo; se for honrado, fecha a janela de mensagem duplicada do `SendJob`. **Não
conte com ela.**

---

## 7. O que foi construído

### Backend

| Peça | Onde |
| --- | --- |
| Porta de saída (behaviour + fachada) | [`Transport`](../api/lib/api/messaging/transport.ex) |
| Cliente da Zernio | [`Zernio`](../api/lib/api/messaging/zernio.ex) |
| Assinatura do webhook | [`ZernioSignature`](../api/lib/api/messaging/zernio_signature.ex) |
| Eventos dos **dois** providers | [`Webhooks`](../api/lib/api/messaging/webhooks.ex) |
| Templates HSM + render dos dois canais | [`Templates`](../api/lib/api/messaging/templates.ex) |
| Gatilhos do C7(b) | [`Messaging.Notifier`](../api/lib/api/messaging/notifier.ex) |
| Aviso único da massa por pacote | [`Packages.Bulk`](../api/lib/api/packages/bulk.ex) |
| Resposta do paciente → caixa | [`Notifications.Fanout`](../api/lib/api/notifications/fanout.ex) |
| Telefone obrigatório e canônico | [`TelObrigatorio`](../api/lib/api/records/patient/validations/tel_obrigatorio.ex) · [`NormalizeTel`](../api/lib/api/records/patient/changes/normalize_tel.ex) |
| Fronteira | [`ZernioWebhookController`](../api/lib/api_web/controllers/zernio_webhook_controller.ex) · `POST /webhooks/zernio` |
| Submissão dos templates | [`mix cinetra.whatsapp.templates`](../api/lib/mix/tasks/cinetra.whatsapp.templates.ex) |
| Número por clínica (§9.1.4) | `Clinic.zernio_account_id` (nulo = o compartilhado da Cinetra) |

### Web

* [`$lib/telefone.ts`](../web/src/lib/telefone.ts) — canônico no banco, mascarado na tela (mesma
  divisão de `cnpj.ts`/`cep.ts`), mais `recebeWhatsapp/1` para o formulário avisar sobre o fixo;
* `PatientForm` — telefone marcado obrigatório, com o aviso do fixo abaixo do campo;
* lista e ficha de paciente exibindo o telefone formatado;
* `patient_wants_reschedule` no vocabulário do sino, com deep-link para o dia da sessão.

### Provas

* **Backend:** 1.370 testes, **90,4 %** (gate 80). As duas falhas restantes são as que o
  [doc 60 §5](60-bate-volta-comunicacao.md) já registrou como vermelhas na árvore e desatribuiu —
  `bulk_adjust`/`bulk_cancel` do `RlsSmokeTest`, cujo `targets/3` volta vazio antes de qualquer
  código desta fatia rodar.
* **Web:** 1.645 testes, 90,35 % linhas (gate 80/75). O `svelte-check` acusa 2 erros, os dois em
  `auditoria/` — trabalho de outra sessão em voo, não desta fatia.
* **Gate `:rls`** (role `cinetra_app`, NOBYPASSRLS): dois testes novos, e os dois cobrem escrita
  **depois** do commit, que é onde a GUC costuma faltar sem erro: a caixa da recepção escrita a
  partir de uma rota pública, e o aviso da massa por pacote.
* **Teto de queries da massa:** o aviso ao paciente custa **~8 queries por massa**, constante. A
  primeira versão custava ~20, abrindo quatro transações para fazer o trabalho de uma; o teto do
  `BulkQueriesTest` pegou, e o conserto foi um `in_clinic` só.

---

## 8. Limitações conhecidas, e um risco que foi decidido correr

**Excluir não avisa, e a volta atrás está registrada.** A primeira versão desta fatia ligou
`:exclude` à mesma mensagem do cancelamento — por fora, os dois querem dizer "a sessão não vai
acontecer". Foi removido no mesmo dia, e a razão é a que o doc 40 já dá por dentro: excluir é o
gesto de **corrigir um lançamento errado**, e avisar o paciente daria a esse gesto um efeito fora
do sistema, que não volta. Quem apagou uma duplicata teria acabado de dizer a alguém que a sessão
dele foi desmarcada.

Quem quer desmarcar de verdade **cancela** — e aí a mensagem sai. O teste que guarda isso afirma o
silêncio (`kinds(ctx, appt) == [:confirmacao]`), não a ausência de erro.

**Pacote de turma cancelado inteiro pode não avisar.** A mensagem precisa de uma presença onde se
ancorar (doc 52 §3, FK `ON DELETE CASCADE`), e cancelar a sessão de quem está acompanhado
**destrói** a presença. Se *todas* as sessões do pacote forem de turma, não sobra âncora e a
mensagem não sai — a notificação in-app à recepção continua saindo, e é ela que fecha o buraco na
prática. A saída definitiva é tornar a âncora opcional para os `kind` de lote, o que mexe no
modelo e na timeline; não foi feito agora porque o caso é estreito e a alternativa é pior.

**Massa por pacote não notifica a caixa no cancelamento.** Achado de passagem, e **é anterior a
esta fatia**: `Api.Packages.Bulk.cancel/3` suprime as notificações por sessão (marca `bulk_pacote`)
e nunca teve o `avisa_uma_vez` que o `adjust/3` tem. Ou seja: cancelar um pacote de 40 sessões não
põe nada na caixa do profissional dono da coluna. O paciente agora é avisado; o profissional, não.
Fica registrado como achado, não corrigido aqui.

**`messages` continua sem retenção** (D-11 do [doc 50](50-debitos-tecnicos.md)). O volume não muda
com o WhatsApp — é a mesma linha por mensagem.

---

## 8.1 O bate-volta

A auditoria está em [`66-bate-volta-whatsapp.md`](66-bate-volta-whatsapp.md). Dois achados desta
fatia, os dois corrigidos e re-sondados:

* **a rota pública de resposta virou amplificador** — o fan-out entrou por cima de uma rota que
  sempre foi idempotente, e 5 replays do mesmo token criavam 10 notificações. Consertado comparando
  o antes com o depois: avisa na **transição**, não na chamada;
* **parâmetro de template saía com quebra de linha** — a Meta recusa, e o erro que chegaria à
  recepção mandaria olhar o template, que está certo.

Ficaram para decisão humana o rate limit das rotas públicas (estrutural) e uma corrida estreita de
duas linhas na guarda nova.

## 9. O que falta para ligar de verdade

Nada disto é código.

1. **Conta na Zernio** com número de WhatsApp conectado, e `ZERNIO_API_KEY` / `ZERNIO_ACCOUNT_ID`
   no ambiente;
2. **`ZERNIO_WEBHOOK_SECRET`** e o endpoint cadastrado em `<host>/webhooks/zernio` (em dev, um
   túnel);
3. **submeter os templates à Meta** (`mix cinetra.whatsapp.templates --enviar`) e esperar a
   aprovação — **é o item de lead time**, e é por isso que o doc 52 §9 mandava submeter durante a
   fase 1;
4. **`WHATSAPP_HABILITADO=true`** — o interruptor. Com credencial e sem ele, tudo continua saindo
   por e-mail;
5. os quatro itens da fase 1 que continuam pendentes ([doc 52 §14.5](52-comunicacao-com-o-paciente.md)):
   chave do Resend, domínio verificado, URL pública do webhook e ligar o lembrete na tela.

A ordem importa: **ligar a flag antes de o template estar aprovado** faz toda mensagem falhar com
"Template de WhatsApp não aprovado" na timeline, uma por paciente.
