defmodule Api.Notifications.Notifier do
  @moduledoc """
  A cola Ash entre os eventos de domínio e o `Api.Notifications.Fanout` (doc 31). Um `Ash.Notifier`
  roda **depois do commit**, então a caixa nunca registra um evento que a transação ainda vai
  desfazer. Anexado ao `Appointment` (ciclo de vida), à `Attendance` (falta por participante, A2),
  ao `Membership` (convite aceito, papel alterado, membro removido) e à `WaitlistEntry` (urgente
  na fila).

  Toda decisão de *quem recebe* mora no `Fanout`; aqui só se roteia a ação para a função certa. As
  gravações do Fanout são best-effort e engolidas lá — este notifier sempre devolve `:ok`, para
  não transformar uma falha de notificação em erro da ação de origem.

  **A ordem das cláusulas importa**: a de `:add_participant` vem antes da cláusula geral do
  `Appointment`, que casa qualquer nome de ação. Invertê-las faria a específica nunca rodar — e o
  sintoma seria só uma notificação a menos, sem erro nenhum.
  """
  use Ash.Notifier

  alias Api.Notifications.Fanout
  alias Api.Notifications.SlotOpenedJob

  # Escrita de LOTE (a massa por pacote): a caixa recebe **uma** notificação agregada, emitida pelo
  # próprio lote quando ele fecha — não N "novo agendamento na sua agenda" (doc 43 §5b). A marca
  # viaja no contexto do changeset, posta por `Api.Packages.Bulk`.
  #
  # Vem **antes** de todas as outras cláusulas, e é o mesmo cuidado de ordem que o moduledoc
  # descreve: uma cláusula específica atrás de uma geral nunca roda.
  #
  # Só a CAIXA é suprimida. O `AgendaNotifier` (tempo real) é outro notifier e continua recebendo
  # tudo, sessão por sessão — a agenda aberta na tela precisa de cada bloco que se moveu.
  @impl true
  def notify(%Ash.Notifier.Notification{changeset: %{context: %{bulk_pacote: true}}}), do: :ok

  # #47 (doc 31 §3a): alguém entrou numa turma da coluna do profissional. Cláusula própria porque
  # o texto é outro — `appointment_touched` fala de "um agendamento", e aqui o bloco já existia.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: :add_participant},
        data: appointment,
        actor: actor
      }) do
    Fanout.participant_added(appointment, actor)
    :ok
  end

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: name},
        data: appointment,
        changeset: changeset,
        actor: actor
      }) do
    Fanout.appointment_touched(appointment, name, actor)

    # #52: aqui só se decide QUE a vaga abriu. Responder "quem cabe" custa ler a fila inteira —
    # 6 queries com a fila vazia — e isso saiu do caminho síncrono do cancelamento para um job.
    if vaga_abriu?(name, appointment, changeset), do: SlotOpenedJob.enqueue(appointment, actor)

    :ok
  end

  # #46 (doc 31 §3a), na forma da A2: a falta é da PRESENÇA. Por isso este notifier também está
  # na `Attendance` — o rollup do bloco não distingue "um dos quatro faltou" de "a turma toda
  # faltou", e é o participante que o profissional precisa saber.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Attendance,
        action: %{name: :mark_absent},
        data: attendance,
        actor: actor
      }) do
    Fanout.participant_missed(attendance, actor)
    :ok
  end

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Accounts.Membership,
        action: %{name: :accept_invite},
        data: membership
      }) do
    Fanout.member_joined(membership)
    :ok
  end

  # #50: papel alterado → o próprio afetado. O `changeset.data` é o vínculo **antes** da escrita,
  # e é a única fonte do papel anterior: a tela de equipe salva o formulário inteiro, então sem
  # comparar não se distingue "virou admin" de "gravou o mesmo papel de novo".
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Accounts.Membership,
        action: %{name: :update},
        data: membership,
        changeset: %Ash.Changeset{data: %{papel: anterior}},
        actor: actor
      }) do
    Fanout.role_changed(membership, anterior, actor)
    :ok
  end

  # #50: saiu da equipe. **Dois canais, dois destinatários**, e é a única cláusula assim:
  #
  #   * a caixa in-app vai a owner/admin — não ao removido, que sem vínculo ativo não alcança mais
  #     a caixa desta clínica (ver `Fanout.member_removed/2`);
  #   * o e-mail vai ao removido, que é justamente quem a caixa não consegue avisar.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Accounts.Membership,
        action: %{name: :revoke_access},
        data: membership,
        actor: actor
      }) do
    Fanout.member_removed(membership, actor)
    Api.Accounts.AccessRevokedEmailJob.enqueue(membership)
    :ok
  end

  # #48: entrou na fila alguém `urgente` → operacional.
  #
  # O `:enqueue` é upsert por paciente, então readicionar um urgente que já estava lá avisa de
  # novo. É um ato deliberado da recepção e o volume é baixo por definição — preferir isso a
  # inventar uma comparação que o upsert não tem como fazer (no create, `changeset.data` é vazio).
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Waitlist.WaitlistEntry,
        action: %{name: :enqueue},
        data: %{prio: :urgente} = entry,
        actor: actor
      }) do
    Fanout.waitlist_urgent(entry, actor)
    :ok
  end

  # Subir a prioridade de um item que já estava na fila é o mesmo fato — e aqui dá para comparar.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Waitlist.WaitlistEntry,
        action: %{name: :update},
        data: %{prio: :urgente} = entry,
        changeset: %Ash.Changeset{data: %{prio: anterior}},
        actor: actor
      })
      when anterior != :urgente do
    Fanout.waitlist_urgent(entry, actor)
    :ok
  end

  @impl true
  def notify(_notification), do: :ok

  # Quando a escrita **abre uma vaga** que a fila pode preencher: cancelar, ou o rollup levando o
  # bloco para `:faltou`.
  #
  # O gate é a **transição**, não o estado: o rollup roda a cada mexida numa presença (justificar
  # uma falta depois roda de novo, com o bloco já em `:faltou`), e sem comparar com o valor
  # anterior a mesma vaga seria anunciada várias vezes.
  #
  # Antes do bate-volta isto era um **tradutor** (`:apply_participant_rollup` → `:mark_missed`), que
  # só existia porque os dois eixos — bloco e presença — emitiam nomes diferentes para o mesmo fato.
  # Com o eixo de bloco aposentado, a pergunta virou o que sempre foi: abriu vaga?
  defp vaga_abriu?(:cancel, _appointment, _changeset), do: true

  defp vaga_abriu?(:apply_participant_rollup, %{status: :faltou}, %Ash.Changeset{
         data: %{status: anterior}
       }),
       do: anterior != :faltou

  defp vaga_abriu?(_name, _appointment, _changeset), do: false
end
