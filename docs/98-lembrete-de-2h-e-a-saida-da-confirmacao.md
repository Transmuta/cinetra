# 98 — O lembrete de 2 h, e a saída da confirmação na criação

**2026-07-31.** Três mudanças na comunicação com o paciente (doc 52), pedidas juntas porque são a
mesma decisão vista de três lados: **quando** o sistema fala com o paciente sozinho.

1. **A confirmação na criação do agendamento sai.** Marcar uma sessão volta a ser gesto interno.
2. **O lembrete ganha o tempo configurável de verdade, com padrão de 2 h** — e nasce **ligado**,
   inclusive nas clínicas que já existem.
3. **O lembrete passa a ignorar a janela de silêncio.** Os outros tipos continuam sendo adiados.

O que segue é o porquê de cada uma, o que foi medido, e o que ficou registrado como custo.

---

## 1. Por que a confirmação na criação sai

Ela era o gatilho mais visível da fatia: agendou → o paciente recebe "sua sessão está marcada".
Duas coisas a derrubam.

**A primeira é o balcão.** Numa clínica de recepção, a sessão costuma ser marcada **com o paciente
presente ou ao telefone** — a mensagem chega durante a conversa que a tornou desnecessária. O que
sobra é ruído com custo: no WhatsApp, ruído **pago**.

**A segunda é o que ela empurrava para o resto do sistema.** Um gatilho na criação dispara para o
bloco inteiro, então entrar numa turma reconfirmava quem já estava lá — e foi preciso uma dedupe
por presença (`ja_confirmada?/1`) só para conter isso. Um pacote de 40 sessões disparava 40
confirmações, e foi preciso a marca `bulk_pacote` nos dois notifiers. Cada anteparo desses existia
porque o gatilho falava alto demais.

**O que fica:** a confirmação continua existindo como **clique da recepção** (botão do drawer,
`POST /api/appointments/:id/messages`), que é o caso em que alguém decidiu que aquele paciente
precisa ser procurado. O teto de duas por presença não mudou de número — o que ele protege é o
paciente, não a origem do disparo.

**O que some junto:** a coluna `clinics.msg_confirmacao_auto` e o controle dela na tela. Ela só
governava esse gatilho; mantida, seria um botão que não faz nada.

## 2. O lembrete: 2 h, e ligado por padrão

O campo já existia (`msg_lembrete_horas`, 1–168), mas nascia **`nil` = desligado** — decisão de
2026-07-27, e ela fazia sentido *naquele* mundo: a confirmação da criação já era o disparo
automático da fatia, então o cron podia esperar alguém escolher um número numa tela.

Removida a confirmação, `nil` como padrão deixaria a clínica **muda**. Então o padrão vira **2 h**,
e a migration **preenche 2 h em toda clínica que ainda não tinha escolhido** (`WHERE
msg_lembrete_horas IS NULL`). Quem não quiser desliga na tela.

**Duas horas, e não vinte e quatro**, porque o que este aviso serve é a decisão de sair de casa —
não o planejamento da semana.

**O custo, declarado:** no deploy, toda clínica com sessões passa a mandar lembrete. No WhatsApp,
mensagem paga. Foi decisão humana explícita, tomada com a alternativa ("ligado só para clínica
nova") na mesa.

## 3. A janela de silêncio, e por que o lembrete sai dela

**Como era:** `Dispatch.quando_enviar/2` adiava para o fim da janela **toda** mensagem gerada
dentro dela — lembrete incluído. "Adia, não descarta" era a regra, e com lembrete de 24 h ela é
inofensiva.

**Com 2 h ela produz mensagem errada.** Com a janela padrão 21h→8h:

| Sessão | Lembrete gerado | Sairia | Antecedência real |
| --- | --- | --- | --- |
| 07:30 | 05:30 (dentro do silêncio) | 08:00 | **30 min DEPOIS da sessão** |
| 08:00 | 06:00 | 08:00 | zero |
| 09:00 | 07:00 | 08:00 | 1 h |
| 14:00 | 12:00 | 12:00 | 2 h ✓ |

A primeira linha é o defeito: "sua sessão é hoje às 07:30" chegando às 08:00, anunciando como
futuro algo que já passou. Adiar ali não protege o sono de ninguém — só produz uma mensagem falsa.

**A regra nova:** o lembrete sai na hora, sempre. Confirmação, remarcação e cancelamento continuam
sendo adiados, porque continuam verdadeiros horas depois.

**O outro lado, registrado para não ser redescoberto como bug:** uma sessão bem cedo faz o lembrete
sair de madrugada. É aceito porque a mensagem é sobre algo que o paciente está prestes a fazer —
quem tem sessão às 7h30 já está de pé às 5h30 — e porque a alternativa (descartar) cala justamente
o aviso mais útil do dia.

As duas alternativas descartadas, para quem reabrir:

- **descartar quando o adiamento cairia depois da sessão** — mantém a promessa do "não incomodar",
  mas apaga o lembrete de toda sessão da manhã, que é quando a clínica mais o quer;
- **antecipar em vez de adiar** (sair 20h59 da véspera) — nunca incomoda e nunca chega tarde, mas
  transforma "2 h antes" em "até 11 h antes" sem que ninguém tenha pedido isso.

## 4. O passo do cron: de 1 h para 15 min

Efeito colateral do padrão de 2 h, e ele **é um defeito de precisão**, não enfeite.

O `ReminderJob` serve a janela `[agora + N, agora + N + passo)`, e o passo era 1 h. Isso significa
que "2 horas antes" entregava, na prática, **entre 2h00 e 2h59 antes** — metade do prazo prometido
como erro. Com 24 h ninguém notava; foi o padrão de 2 h que tornou o erro visível.

O passo virou **15 min**, e o crontab acompanhou (`*/15 * * * *`). A largura da janela e o passo do
cron são o **mesmo número** — é isso que faz a janela ladrilhar a linha do tempo (sem buraco, sem
sobreposição), e é o que dispensa uma coluna "lembrete_enviado_em". Mexer em um sem o outro ou
perde lembrete ou manda em dobro; há teste para os dois lados.

Custo: 4× mais varreduras por hora. A consulta é servida por
`attendances_clinic_session_starts_at_index` e cada rodada lê uma janela quatro vezes menor.

---

## 5. O que mudou, arquivo a arquivo

**Backend**

| Arquivo | O quê |
| --- | --- |
| [`messaging/notifier.ex`](../api/lib/api/messaging/notifier.ex) | some a cláusula `:schedule`/`:add_participant`, a dedupe `ja_confirmada?/1` e o gate `msg_confirmacao_auto` |
| [`messaging/dispatch.ex`](../api/lib/api/messaging/dispatch.ex) | `quando_sai/2` — o lembrete não é adiado; o resto passa por `quando_enviar/2` |
| [`messaging/reminder_job.ex`](../api/lib/api/messaging/reminder_job.ex) | `@passo_minutos 15` |
| [`accounts/clinic.ex`](../api/lib/api/accounts/clinic.ex) | `msg_confirmacao_auto` removido; `msg_lembrete_horas` ganha `default: 2` |
| [`api_web/controllers/clinic_controller.ex`](../api/lib/api_web/controllers/clinic_controller.ex) | o campo sai do params e do JSON |
| [`config/config.exs`](../api/config/config.exs) | crontab do `ReminderJob` a cada 15 min |
| [migration](../api/priv/repo/migrations/20260731235302_remover_confirmacao_na_criacao.exs) | drop da coluna, backfill de 2 h, e o **drop/recreate da view `metrics_clinics`** |

**Web:** [`clinics.ts`](../web/src/lib/server/clinics.ts) (tipo),
[`comunicacao/+page.server.ts`](<../web/src/routes/(app)/configuracoes/comunicacao/+page.server.ts>)
(payload) e [`comunicacao/+page.svelte`](<../web/src/routes/(app)/configuracoes/comunicacao/+page.svelte>)
(o toggle sai; a tela fica com dois controles).

### A armadilha que a migration cobrou

`DROP COLUMN msg_confirmacao_auto` **falha**: a view `metrics_clinics` (doc 73) cita a coluna, e o
Postgres recusa por dependência. `CREATE OR REPLACE VIEW` também não resolve — ele acrescenta
coluna, nunca remove. O conserto é `DROP VIEW` → alterar a tabela → recriar a view, **e reconceder
o `GRANT` ao `cinetra_metrics`**, que o `DROP VIEW` leva junto.

O moduledoc da `MetricsViews` já previa esse conserto para *mudança de tipo*; o primeiro caso real
foi uma remoção. Fica o aviso de manutenção: **coluna citada em view não é `ash.codegen` e pronto.**

---

## 6. Como foi verificado

- **Backend:** 1717 testes, 0 falhas. `mix format --check-formatted`, `mix compile
  --warnings-as-errors` e `mix coveralls` (89,8 %, gate verde) limpos.
- **RLS:** `mix test --only rls` rodado **como `cinetra_app`** (`DATABASE_USER=cinetra_app`), não
  como superusuário — sem isso o gate não prova nada (`.claude/rules/migrations.md` §3).
- **Web:** 2414 testes em 205 arquivos, `npm run check` com 0 erros, `npm run coverage` verde.
- **Banco de dev, no `psql`:** a coluna sumiu, `metrics_clinics` responde (413 linhas) e todas as
  clínicas ficaram com `msg_lembrete_horas = 2`.

Os testes que carregam a mudança, cada um na camada onde a regra mora:

- `ReminderJobTest` — "o padrão é 2 horas", "a janela tem o TAMANHO DO PASSO", "o lembrete NÃO é
  adiado pela janela de silêncio" (este atravessa cron → dispatch → linha gravada);
- `DispatchTest` — o lembrete dentro da janela sai com `agendado_para == nil`, e o teste vizinho
  prova que a confirmação **continua** sendo adiada;
- `NotifierTest` — criar não gera mensagem; entrar numa turma também não;
- `page.server.test.ts` — o payload não carrega mais `msg_confirmacao_auto`;
- `page.svelte.test.ts` (novo) — o que o **formulário** manda, que é onde morava o bug do
  silêncio.

### O bug que a verificação ao vivo pegou (e que não era desta mudança)

Ao conferir a tela no browser — mudar o lembrete de 2 h para 3 h e salvar —, a **janela de
silêncio sumiu**: as duas pontas foram para nulo e o controle voltou desligado.

**Causa, e ela é anterior a esta fatia:** a action lê `form.get('silencio') === 'on'` para decidir
se grava a janela ou a apaga, mas o formulário **nunca mandava esse campo**. O `SwitchToggle` é um
`<button role="switch">`, e botão não entra no `FormData`. Então toda gravação — inclusive a que só
mexia no lembrete — apagava o "não incomodar". Na prática, a janela era **impossível de ligar pela
tela**; o que existia no banco era o default da coluna (21h→8h), até o primeiro clique em Salvar.

**Por que os testes estavam verdes:** o `page.server.test.ts` prova o que a action faz com cada
campo, e passa `silencio: 'on'` à mão. O bug mora entre a página e a action — a única camada que
ninguém testava. Entrou agora um `page.svelte.test.ts` que renderiza a tela e inspeciona o
`FormData` real do formulário; ele fica **vermelho** sem o `<input type="hidden" name="silencio">`.

Verificado ao vivo depois do conserto: ligar a janela grava 21h→8h, e salvar mexendo **só** no
lembrete deixa as duas pontas intactas.

### O que a montagem dos testes revelou

Meia dúzia de arquivos montava o cenário "existe uma mensagem para este bloco" apenas chamando
`agendamento!/2` — dependiam do gatilho que saiu. Em vez de seis montagens copiadas, entrou
`Api.Generators.confirmacao!/3` (e o par `lembrete!/3`), pelo mesmo motivo que `paciente_com/2`
existe: helper de teste copiado é helper que diverge.

---

## 7. O que ficou de fora

- **Granularidade em minutos** no lembrete (ex.: 90 min). O campo continua em **horas**; com o
  passo de 15 min o cron já suportaria, mas ninguém pediu e a tela ficaria mais complicada.
- **Um lembrete por tipo de atendimento** ou por profissional. A configuração segue **por
  clínica** — por profissional vira matriz que ninguém mantém (doc 52 §7).
- **Reintroduzir a confirmação como opção.** Se um dia voltar, volta com a dedupe por presença
  junto: está registrado no moduledoc do `Notifier` que uma coisa não vai sem a outra.
