# 31 — Notificações in-app (análise: quais fazem sentido)

O menu lateral tem um **sino** (`Notificações`) que hoje é só placeholder visual — um
`<button>` sem rota nem handler, com badge teal hardcoded, em
[`web/src/lib/components/shell/Rail.svelte:60`](../web/src/lib/components/shell/Rail.svelte).
Não existe rota `/notificacoes`, não existe tabela/recurso de notificação, não existe
lido/não-lido. Este doc analisa **quais notificações valem a pena** antes de construir qualquer
tela — porque a decisão cara aqui não é a UI, é *o que o sistema passa a registrar por usuário*.

Legenda de recomendação:
- 🟢 **v1** — recomendo entrar já; alto valor, baixo risco de ruído.
- 🟡 **depois** — faz sentido, mas espera decisão de produto ou uma fatia anterior.
- 🔴 **não** — ruído ou redundante com algo que a tela já faz.

---

## 1. Três planos que hoje se confundem num "sino"

Antes de listar eventos, separar três coisas que são diferentes — construir a notificação como
se fosse o tempo real é o erro clássico:

| Plano | O que é | Existe hoje? | Persiste? | Escopo |
| --- | --- | --- | --- | --- |
| **Sync ao vivo** | A grade da agenda aberta se atualiza sozinha quando alguém mexe. | **Sim** — `AgendaNotifier`/`WaitlistNotifier` + canais Phoenix ([`agenda_notifier.ex`](../api/lib/api/scheduling/agenda_notifier.ex), [`agenda_channel.ex`](../api/lib/api_web/channels/agenda_channel.ex)). | Não (fire-and-forget) | Por-clínica, quem está com a tela aberta |
| **Toast** | Confirmação efêmera da *minha própria* ação ("agendamento criado"). | **Sim** — [`web/src/lib/toast.svelte.ts`](../web/src/lib/toast.svelte.ts) | Não | O próprio autor, na hora |
| **Notificação (o sino)** | "Enquanto eu não estava olhando, aconteceu algo com o **meu** trabalho que eu preciso saber." | **Não** | **Sim (é o ponto)** | **Por-usuário**, recortado por papel |

A notificação do sino é o **terceiro** plano e é o único inexistente. Ela não substitui o sync
(que mantém a tela viva) nem o toast (que fecha o loop da ação): ela é o **registro assíncrono
por usuário** do que aconteceu quando ele *não* estava na tela. Todo o valor está nisso — logo,
o critério para um evento virar notificação é:

> **É algo que aconteceu com o trabalho *deste usuário*, causado por *outra pessoa*, que ele
> precisaria descobrir sozinho abrindo a tela?**

Se a resposta é "ele mesmo fez" → é toast, não notificação. Se é "está na tela que ele está
olhando" → o sync já resolve. Se é "não muda nada que ele faça" → é ruído.

---

## 2. Modelo de destinatário (o que torna isto correto)

Três regras que decorrem direto do RBAC do projeto ([`role.ex`](../api/lib/api/accounts/role.ex)
— `owner`/`admin`/`profissional`/`recepcao`) e precisam valer desde a v1:

1. **Por usuário, não por clínica.** Diferente do PubSub atual (que joga para a clínica toda),
   uma notificação tem *um dono*. Isso exige a peça que não existe: um recurso persistido
   `Notification` com `recipient_user_id`.

2. **Recorte por papel na entrega — o `profissional` só é notificado da *própria* coluna.** O
   mesmo recorte que a leitura da agenda já aplica
   ([`own_agenda_only.ex`](../api/lib/api/scheduling/preparations/own_agenda_only.ex)): um
   profissional recebe notificação de agendamento/remarcação/cancelamento **na coluna dele**;
   `recepcao`/`admin`/`owner` recebem o operacional da clínica inteira. **Cuidado:** a fila
   *não* é recortada por papel hoje ([`waitlist_notifier.ex:9`](../api/lib/api/waitlist/waitlist_notifier.ex)),
   então notificação de fila é naturalmente operacional (recepção), não do profissional.

3. **Suprimir o autor.** O payload do notifier já carrega `actor: %{id, nome}`
   ([`agenda_notifier.ex:70`](../api/lib/api/scheduling/agenda_notifier.ex)). Se o destinatário
   *é* o autor, não gera notificação (ele já teve o toast). É isso que separa "recepção cancelou
   o paciente do Dr. Fulano" (→ notifica o Fulano) de "Dr. Fulano cancelou o próprio" (→ nada).

---

## 3. Catálogo de eventos candidatos

Todos os eventos abaixo **já existem no domínio** — a coluna "origem" aponta onde. A pergunta é
só se cada um vira registro no sino.

### 3a. Ciclo de vida do agendamento

| Evento (do notifier) | Quem recebe | Rec. | Racional |
| --- | --- | --- | --- |
| `appointment_scheduled` **por outra pessoa** | Profissional dono da coluna | 🟢 **v1** | O caso nº1. A recepção agenda na agenda do profissional; ele quer abrir o app e ver "3 novos na sua agenda hoje", não descobrir clicando. |
| `appointment_rescheduled` | Profissional dono (origem **e** destino) | 🟢 **v1** | "Seu paciente das 14h foi movido para 16h." Máxima relevância — muda o dia dele. O notifier já emite nos dois dias. |
| `appointment_canceled` | Profissional dono | 🟢 **v1** | "Sua sessão das 15h foi cancelada." Abre buraco na agenda; ele precisa saber (e talvez ofertar da fila). |
| `appointment_status_changed` → `:faltou` | Profissional dono | 🟡 depois | Útil, mas quase sempre é o próprio profissional marcando (autor suprimido → quase nunca dispara). Amarra com a fila (3b). |
| `appointment_status_changed` → `:concluido`/`:reopen`/`justify` | — | 🔴 não | Ação do próprio profissional na maioria dos casos; não muda nada para terceiro. Ruído. |
| `participant_added` (turma) | Profissional dono | 🟢 **v1** (A2) | Baixa frequência; entrou com a fatia de turma (doc 41 etapa 5, #47). |
| `package_bulk_adjusted` (massa por pacote) | Profissional dono (origem **e** destino) | 🟢 **v1** (bate-volta) | Uma linha por **massa**, não por sessão: remarcar um pacote de 40 mandava 40 "novo agendamento na sua agenda" para o que é um evento só — e as sessões foram *movidas*, não criadas. Ver [doc 43 §5b](43-bate-volta-onda-3.md). |

### 3b. Fila de espera

| Evento | Quem recebe | Rec. | Racional |
| --- | --- | --- | --- |
| **Vaga abriu com fila casando** (falta/cancelamento **e** `who_fits > 0`) | Recepção/admin/owner | 🟢 **v1** | O **único que gera receita**. Hoje o "quem cabe" ([`waitlist.ex:301`](../api/lib/api/waitlist.ex)) só existe se a recepção *for* abrir o drawer da falta. Como notificação, vira proativo: "Vaga livre qui 15h — 2 pacientes da fila cabem." Transforma um evento passivo (cancelamento) em ação. |
| Paciente **urgente/alta** entrou na fila | Recepção | 🟡 depois | Bom sinal operacional, mas risco de ruído em clínica movimentada; decidir limiar (só `urgente`? só quando não há vaga hoje?). |
| Oferta/hold **expirando** ou expirou sem conversão | Quem ofereceu | 🟡 depois | O `SlotHold` de 10 min já existe ([`slot_hold.ex`](../api/lib/api/scheduling/slot_hold.ex)) e o cleanup roda por Oban. "Sua reserva da vaga expira em 2 min" é útil, mas era o F4 já deferido no [doc 30 §2](30-decisoes-pendentes-agenda.md). |

### 3c. Membros / governança

| Evento | Quem recebe | Rec. | Racional |
| --- | --- | --- | --- |
| **Convite aceito / novo membro entrou** | Owner/admin | 🟢 **v1** | O convite já dispara e-mail ([`resolve_invited_user.ex`](../api/lib/api/accounts/membership/changes/resolve_invited_user.ex)); falta o **retorno**. "Fulano aceitou e entrou como recepção." Barato, baixa frequência, ótimo sinal de que quem convidou não fica no escuro. |
| Papel alterado / membro removido | O próprio membro afetado | 🟡 depois | Sensível (mexe em acesso); pequeno volume; pode esperar. |

### 3d. Lembretes por tempo (classe diferente — *cron*, não evento)

Estes não nascem de uma ação; nascem do **relógio** (Oban já está de pé, fila `housekeeping`,
[`config.exs:81`](../api/config/config.exs)). Todos dependem de decisão de produto ainda aberta:

| Ideia | Rec. | Bloqueio |
| --- | --- | --- |
| "Você tem N atendimentos amanhã" (resumo diário) | 🟡 depois | Fácil tecnicamente; decidir se agrega valor sobre só abrir a agenda. |
| "Paciente não confirmou presença" | 🔴 não (v1) | Depende de **F7** ([doc 30 §2](30-decisoes-pendentes-agenda.md)): o que "confirmar" significa sem WhatsApp está **indefinido**. Sem isso, não há evento. |
| "Sessão em 15 min" | 🔴 não (v1) | A tela do dia já mostra; valor marginal; ruído alto. |

---

## 4. Recomendação: o núcleo da v1

Se for para responder curto **"quais fazem sentido"**, são **três famílias** — as que atendem o
critério da §1 (mudança no *meu* trabalho, feita por *outro*, que eu descobriria sozinho):

1. **Mudanças na minha agenda feitas por outra pessoa** — `agendado` / `remarcado` /
   `cancelado` na coluna do profissional. → destinatário: **o profissional dono**. *É a razão de
   um sino existir num sistema onde a recepção opera a agenda do profissional.*

2. **Vaga livre com fila casando** — cancelamento/falta que abre horário **e** há paciente na
   fila que cabe. → destinatário: **recepção/admin**. *O único de retorno financeiro direto.*

3. **Convite aceito / novo membro** — → destinatário: **owner/admin**. *Fecha o loop de quem
   convidou; barato e de baixo volume.*

Tudo o mais da §3 é 🟡/🔴: ou espera decisão (confirmação/F7, fila urgente, hold expirando) ou é
ruído (status que o próprio autor mudou, lembrete que a tela já mostra).

**Por que não mais que isso na v1:** notificação boa é a que o usuário *confia* — se o sino
apita por coisa que ele mesmo fez ou por coisa que já estava na tela, ele para de olhar. Começar
enxuto e alto-sinal, e só então medir se falta algo.

---

## 5. Cortes transversais (valem para qualquer item acima)

- **Persistência + lido/não-lido.** É a peça inexistente: recurso Ash `Notification` com
  `recipient_user_id`, `clinic_id` (tenant/RLS como todo o resto), `kind`, `payload` (jsonb),
  `read_at`, `inserted_at`. O badge do sino conta `read_at IS NULL`.
- **Canal de entrega — v1 é só in-app.** Nada de e-mail/push por evento de agenda agora: o
  Swoosh existente ([`emails.ex`](../api/lib/api/accounts/emails.ex)) só manda magic link, e
  e-mail por cancelamento vira spam rápido. E-mail/push ficam para uma decisão própria (ex.:
  resumo diário, ou só urgências).
- **Tempo real do próprio sino.** Reusar o PubSub que já existe: ao criar a `Notification`, um
  broadcast num tópico **por-usuário** (`user:<id>:notifications`) faz o badge subir sem refresh —
  mesma mecânica dos canais de agenda, escopo novo.
- **Ruído / dedupe.** Uma remarcação seguida de outra no mesmo bloco não deve virar duas linhas
  soltas; agrupar por agendamento. E quando o profissional está *com a agenda aberta* e o sync ao
  vivo já mostrou a mudança, marcar a notificação correspondente como lida é um refinamento
  desejável (evita o duplo-sinal).
- **Suprimir o autor** (§2.3) — condição obrigatória em todos os itens, não opcional.

---

## 6. Esboço técnico (o que reusa, o que é novo)

**Reusa (já de pé):**
- Os `Ash.Notifier` de agenda e fila e seus **nomes de evento já padronizados**
  ([`agenda_notifier.ex:108`](../api/lib/api/scheduling/agenda_notifier.ex)) — a criação da
  `Notification` engancha no mesmo `after_commit`.
- O barramento `Api.PubSub` + canais Phoenix ([`user_socket.ex`](../api/lib/api_web/channels/user_socket.ex))
  — só falta um tópico por-usuário.
- Oban (fila `housekeeping`) e Swoosh — prontos se/quando a classe "lembrete por tempo" (§3d)
  ou e-mail entrar.
- O placeholder do sino no Rail — aguardando rota `/notificacoes`, badge real e uma tela de lista.

**Novo (greenfield):**
- Recurso/tabela `Notification` por-usuário (§5) + code interface no domínio de contas.
- O **fan-out por-papel**: dado um evento de clínica, resolver *quais usuários* devem receber
  (profissional dono via `professional_id → membership → user`; recepção/admin/owner via
  `memberships`). É onde mora a regra de negócio — candidato a um `Notifier`/serviço dedicado, não
  espalhado.
- Rota + tela do sino (lista, marcar lido, badge) no `web/`.

---

## 7. Decisões que preciso de você

1. **Fecha o núcleo v1** nas 3 famílias da §4, ou quer incluir/excluir alguma? (ex.: já entrar
   com "urgente na fila", ou já deixar cair "convite aceito".)
2. **Só in-app na v1?** Confirmo que e-mail/push ficam para decisão separada.
3. **Retenção/limpeza** das notificações lidas — apagar após X dias, ou guardar? (coerente com a
   política de retenção da trilha, [doc 30 §1 P2](30-decisoes-pendentes-agenda.md).)
4. Esta é **uma fatia própria** (recurso + fan-out + tela), fora das pendências do doc 30 — só
   registrando que não bloqueia nada do que já existe.

---

## 8. Estado — CONSTRUÍDA (2026-07-21)

O núcleo v1 das §4 foi construído e verificado. Não commitada.

- **Backend** — domínio `Api.Notifications` (recurso `Notification` por-tenant/RLS destinado a um
  `User`, título/corpo denormalizados), `Api.Notifications.Fanout` (destinatário por papel +
  supressão do autor) enganchado por `Api.Notifications.Notifier` no `Appointment`
  (schedule/reschedule/cancel → profissional; cancel/miss + `who_fits>0` → recepção) e no
  `Membership` (`:accept_invite` → owner/admin). Canal `notifications:<clinic_id>` (tópico interno
  por-usuário) para o badge ao vivo. HTTP: `GET /api/notifications`, `POST /:id/read`,
  `POST /read-all`.
- **Web** — rota `/notificacoes` (lista + marcar lida/todas), sino do Rail virou link com badge
  real (`unread` desce do `+layout.server`), realtime no layout subindo o badge sem refresh.
- **Gates** — backend 700 testes / 91,0 %; web 91,6 %; ambos verdes.
- **Verificação ao vivo (servidor real, `movimento_app`)** — pegou **um bug que o `mix test` não
  pega** (sandbox bypassa RLS): marcar-lida dava 500/400. Causa: a policy `mark_read` é
  filter-check (`recipient_id == actor`), então o `Ash.can` roda um SELECT sob RLS **antes** do
  `SetTenantGuc` (before_action) — GUC vazia → `''::uuid`. Corrigido rodando a escrita dentro de
  `in_clinic` (é a dívida **D-M** do doc 30 na prática). Isolamento cross-tenant e o caminho de
  escrita provados ao vivo.

Follow-ups (não v1): `slot_opened` computa `who_fits` no notifier pós-commit (custo por evento —
revisitar com D-A/D-D); `unread_count` lê a lista e conta (agregado quando crescer); deep-link fino
das notificações (hoje abrem agenda/fila/equipe no estado padrão).
