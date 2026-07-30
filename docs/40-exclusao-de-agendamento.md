# 40 — Excluir agendamento (soft-delete)

Decisão tomada em 2026-07-24, com o humano. Fecha o `Trash2` que o protótipo desenha no rodapé do
drawer ([`Movimento.dc.html:1846`](../interface/Movimento.dc.html)) e que não tinha contraparte no
backend. Distingue-se de **cancelar** (ciclo de vida, [`25 §3`](25-agenda.md)) e de **arquivar**
(profissional/tipo/paciente).

**A decisão em uma linha:** excluir é **soft-delete** — o bloco some de toda leitura (agenda,
relatório, fila, tempo real) mas a linha e a trilha ficam. É para **lançamento feito por engano**;
cancelar é para atendimento que **existiu** e não vai acontecer.

---

## Por que soft-delete, e não `DELETE`

Cancelar já carregava dois trabalhos que são um só clique só na aparência: "o atendimento foi
desmarcado" (conta em `cancelados`, na taxa de falta, na ficha do paciente) e "esse lançamento
nunca deveria ter existido" (paciente errado, dia errado, duplicado, teste). O segundo suja três
números de uma vez. Excluir separa os dois: some da vista, **não** entra em nenhuma métrica.

O `DELETE` de verdade foi descartado porque quebra quatro mecanismos que já existem — não é "a
mesma coisa sem a coluna":

1. **Tempo real fica com bloco fantasma.** O canal ([`AgendaChannel`](../api/lib/api_web/channels/agenda_channel.ex))
   resolve cada evento **relendo o bloco com o escopo do assinante**; um registro apagado não tem o
   que reler. O soft-delete é um `UPDATE` comum — entra no `@lifecycle` do notifier e o canal
   empurra a **remoção do id** (evento `appointment_excluded`), em vez de deixar o bloco na tela até
   um F5.
2. **A concorrência otimista deixa de funcionar.** Toda mutação manda `expected_version`; um bloco
   apagado sob outra aba vira "sumiu" sem versão para o 409 comparar.
3. **Há dependente `allow_nil? false` com trilha própria.** [`Attendance`](../api/lib/api/scheduling/attendance.ex)
   é `belongs_to :appointment, allow_nil?: false` **e** versiona. Apagar forçaria violar FK ou
   cascatear e orfanar as versões das presenças também.
4. **`reference_source? false` já é concessão, não projeto.** O comentário no recurso
   ([`appointment.ex`](../api/lib/api/scheduling/appointment.ex)) diz na letra: *"trilha que some
   quando o registro some não é trilha"*. Não se gasta essa concessão à toa.

`DELETE` seria a resposta certa para **expurgo de LGPD** — dado de paciente, fluxo próprio, com
purga das versões junto. Nenhum desses é um botão no drawer da agenda.

## Regras

- **Quem:** qualquer um que já agenda — **inclusive recepção** (decisão do humano; recepção cancela
  e remarca, excluir não é privilégio de owner/admin). Herda a policy de escrita do ciclo de vida:
  o `profissional` só na própria coluna (`OwnProfessionalColumn`), como nas outras transições.
- **O quê:** só o que **não aconteceu** — `agendado`, `confirmado`, `cancelado`. Nunca
  `concluído`/`faltou`/`em_atendimento`: esses debitam pacote e cascatearam presença. Para desfazer
  um "faltou" lançado errado, o caminho é **reabrir → excluir** (compõe com o que já existe). O
  guard é o mesmo `StatusIn` de F4 ([`34`](34-qa-exploratorio-playwright.md)); o espelho de UX é
  `canExcludeAppointment/1`.
- **Confirmação, sem motivo.** Vem com `ConfirmDialog` (destrutivo, sem desfazer imediato na mesma
  tela — o único desfazer é pela auditoria). **Não** pede motivo: o registro some da vista, então um
  motivo só viveria na trilha — valor marginal para v1, e o protótipo não pede. Diverge do
  protótipo só no diálogo (o protótipo exclui em um clique); o humano endossou a confirmação.
- **Modelagem:** atributo `excluded_at`, **não** um 7º status. Um `prepare` global
  (`HideExcluded`, `is_nil(excluded_at)`) tira o bloco de agenda, relatório, `SlotFinder` e
  releitura do canal num lugar só; um status novo obrigaria cada `Enum.reject(status == :cancelado)`
  e o `STATUS_META` a aprender sobre ele.

## A pegadinha da constraint (o que só o banco prova)

O índice parcial `appointments_no_overlap` tinha predicado `WHERE encaixe = false AND status <>
'cancelado'`. Sem `AND excluded_at IS NULL`, um bloco excluído **continuaria bloqueando o horário** —
um engano seguraria o slot para sempre. A migration
[`20260724041000_exclude_appointment_frees_slot`](../api/priv/repo/migrations/20260724041000_exclude_appointment_frees_slot.exs)
troca o predicado. Exclusion constraint **não** tem forma `CONCURRENTLY` (nem `USING INDEX` nem
`NOT VALID` para `EXCLUDE`), então o swap é uma janela breve de `ACCESS EXCLUSIVE` — aceitável em
tabela nova (v1), documentado para quando tiver volume. Ver a regra em
[`.claude/rules/migrations.md`](../.claude/rules/migrations.md) §2.

Provado sob o role restrito `cinetra_app` (NOBYPASSRLS), não só no `mix test` (BYPASSRLS): a
escrita da exclusão passa, o bloco some da leitura e o mesmo horário volta a ser agendável.

## Tempo real

`:exclude` entra no `@lifecycle` do [`AgendaNotifier`](../api/lib/api/scheduling/agenda_notifier.ex)
como evento `appointment_excluded` (só o id). No canal:

- **modo `block`** (Dia/Lista) — não relê (o bloco já sumiu); empurra `appointment_excluded` com o
  id, gated pelo recorte A7. O cliente remove do store (`onRemove`); o drawer aberto naquele bloco
  fecha sozinho, porque `selecionado` é derivado da lista.
- **modo `signal`** (Semana/Mês) — cai no caminho de sempre e recarrega a contagem.

## Pendência assumida

Sem tela de "excluídos", o desfazer só existe pela **auditoria**. Como só se exclui o que não
aconteceu e a trilha guarda quem·quando, aceita-se na v1 — mas é follow-up real, não algo que some.
