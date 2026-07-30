defmodule Api.Messaging.Notifier do
  @moduledoc """
  A cola Ash entre a agenda e a comunicação com o paciente (doc 52 §7): quando um agendamento
  nasce, a confirmação sai sozinha.

  ## Por que notifier, e não um `after_action` na ação

  Um `Ash.Notifier` roda **depois do commit**. Uma confirmação disparada de dentro da transação
  poderia sair para um agendamento que o banco ainda vai desfazer — e mensagem enviada não volta.
  É a mesma razão pela qual o `Api.Notifications.Notifier` existe, e vale mais aqui: lá o pior
  caso é uma linha a mais na caixa de alguém; aqui é um paciente recebendo "sua sessão está
  marcada" para uma sessão que não existe.

  ## O que dispara, e o que **não** dispara

  | Ação do bloco | Mensagem | Quem recebe |
  | --- | --- | --- |
  | `:schedule` / `:add_participant` | `:confirmacao` | quem entrou, e só quem ainda não tinha |
  | `:reschedule` | `:remarcacao` | todo participante vivo |
  | `:cancel` | `:cancelamento` | todo participante que o cancelamento acabou de derrubar |

  As duas últimas são o **C7(b)**, que a fase 1 deixou de fora por ser "copy nova, não estrutura
  nova". Era verdade: entraram sem mexer no `Dispatch`, no `SendJob` nem no transporte.

  ## E o que ele **desfaz**: `:cancel` e `:exclude` esvaziam a fila

  A janela de silêncio (§7) **adia**, e isso abriu horas entre "a mensagem foi pedida" e "a
  mensagem saiu". Dentro dessa janela o fato pode mudar: o bloco é cancelado às 22h45 e a
  confirmação das 22h continua parada até as 8h. Ela saía assim mesmo, anunciando uma sessão que
  já não existe — e mensagem enviada não volta.

  Então os dois gatilhos que **encerram** o bloco começam tirando da fila tudo que ainda não saiu
  (`Api.Messaging.MessageStatus` → `:descartada`). No `:exclude` isso é o que faz a decisão de não
  avisar valer: sem ele, ela valia só fora do horário de silêncio.

  ## Duas ações do ciclo de vida ficam de fora, e por razões diferentes

  **`:reopen`** — reabrir é desfazer um clique errado (D-E4.2), quase sempre segundos depois;
  mandar "sua sessão voltou a valer" para quem talvez nem tenha recebido o cancelamento é ruído
  com chance de confundir mais do que informar. Se um dia virar mensagem, precisa de copy própria
  — não de reúso da confirmação.

  **`:exclude`** — excluir (doc 40) é "este lançamento nunca deveria ter existido": o gesto de
  corrigir um erro de digitação. Avisar o paciente daria a esse gesto um **efeito fora do
  sistema, que não volta** — quem apagou um lançamento duplicado teria acabado de dizer a alguém
  que a sessão dele foi desmarcada. Chegou a ser ligado em 2026-07-28 e foi **removido no mesmo
  dia**, por decisão, antes de qualquer uso real.

  Quem quer desmarcar a sessão de verdade **cancela**, e aí a mensagem sai. É a mesma linha que o
  doc 40 já traça por dentro; a diferença é que agora ela vale também do lado de fora.

  ## Best-effort, e o que isso protege

  Falha ao comunicar **não** desfaz o agendamento — o notifier sempre devolve `:ok`. O
  agendamento é o fato; a mensagem é o aviso sobre ele. Inverter isso faria a agenda depender de
  um provider externo estar de pé.

  ## A ordem das cláusulas é contrato

  Como no `Api.Notifications.Notifier`: cláusula específica antes da geral, senão a específica
  nunca roda — e o sintoma é só uma mensagem a menos, sem erro nenhum.
  """
  use Ash.Notifier

  require Ash.Query
  require Logger

  alias Api.Messaging.Dispatch

  # **A exceção do lote, e vem antes dele de propósito.** Descartar não é *falar* com o paciente —
  # é o contrário: é tirar da fila uma mensagem que não pode mais sair. Cair na supressão geral
  # abaixo deixaria um pacote de 40 sessões cancelado em massa com 40 confirmações ainda a
  # caminho, que é exatamente o dano que a marca existe para evitar, pela porta do lado.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: name},
        data: appointment,
        changeset: %{context: %{bulk_pacote: true}}
      })
      when name in [:cancel, :exclude] do
    descartar_pendentes(appointment, motivo_do_descarte(name))
  end

  # A escrita de LOTE (materialização de pacote, massa por pacote) passa por aqui uma vez por
  # sessão. Um pacote de 40 sessões mandaria 40 confirmações de uma vez — que é spam, e no WhatsApp
  # seria spam *pago*. A marca viaja no contexto do changeset, posta por `Api.Packages.Bulk` e por
  # `Api.Packages.Sessions`; é a mesma que o `Api.Notifications.Notifier` usa para suprimir a
  # caixa, e pelo mesmo motivo.
  #
  # **Esta linha é idêntica à de lá, e continua duplicada de propósito.** O bate-volta propôs
  # extraí-la; as duas saídas pioram o código: função não casa em head, e a `defguard` equivalente
  # fica menos legível do que a linha que ela substitui. O risco real da cópia — alguém trocar a
  # marca e esquecer um dos dois assinantes, sem erro nenhum e com 40 mensagens saindo — está preso
  # por teste, em `Api.Messaging.NotifierTest`.
  #
  # **Vem antes das cláusulas de gatilho**, como lá: uma cláusula específica atrás de uma geral
  # nunca roda, e o sintoma seria só uma mensagem a mais — sem erro nenhum.
  @impl true
  def notify(%Ash.Notifier.Notification{changeset: %{context: %{bulk_pacote: true}}}), do: :ok

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: name},
        data: appointment
      })
      when name in [:schedule, :add_participant] do
    avisar(appointment, :confirmacao)
  end

  # C7(b). `:exclude` **não** entra aqui — ver o moduledoc.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: :reschedule},
        data: appointment
      }),
      do: avisar(appointment, :remarcacao)

  # A ordem das duas linhas é contrato: **descarta antes de avisar**. Invertido, o `:cancelamento`
  # que acabou de entrar na fila seria varrido pelo próprio descarte — `pending_for_appointment`
  # não filtra por tipo, e é essa ausência de filtro que faz o resto funcionar.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: :cancel},
        data: appointment
      }) do
    descartar_pendentes(appointment, motivo_do_descarte(:cancel))
    avisar(appointment, :cancelamento)
  end

  # Excluir não avisa (ver o moduledoc) — mas **precisa** desfazer o aviso que já estava na fila.
  # Sem isto a decisão de não falar com o paciente valia só fora da janela de silêncio: dentro
  # dela, a confirmação da criação continuava parada e saía às 8h, anunciando um lançamento que
  # alguém acabou de apagar por engano.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: :exclude},
        data: appointment
      }),
      do: descartar_pendentes(appointment, motivo_do_descarte(:exclude))

  @impl true
  def notify(_notification), do: :ok

  # A autoridade única do par ação → motivo. As três cláusulas de descarte passam por aqui: o
  # lote e as duas normais, para que trocar um motivo não deixe a outra porta dizendo o antigo.
  defp motivo_do_descarte(:cancel), do: :sessao_cancelada
  defp motivo_do_descarte(:exclude), do: :agendamento_excluido

  # Tira da fila tudo que ainda não saiu deste bloco.
  #
  # Roda **dentro** de `with_clinic/2` porque a leitura precisa da GUC: solta, a RLS devolveria
  # lista vazia sob `cinetra_app` e o descarte passaria a nunca descartar — em silêncio, e com a
  # suíte verde, porque o sandbox do `mix test` roda como superusuário (a lição de
  # `.claude/rules/migrations.md`, que já custou três medições erradas).
  #
  # Não cancela o job do Oban: o `SendJob` já sai por cima quando a mensagem não está mais
  # `:pendente`. Uma guarda só, no lugar onde o envio de fato acontece, em vez de duas que podem
  # divergir.
  defp descartar_pendentes(appointment, motivo) do
    Api.Repo.with_clinic(appointment.clinic_id, fn ->
      appointment.id
      |> Api.Messaging.list_pending_messages_for_appointment!(
        tenant: appointment.clinic_id,
        authorize?: false
      )
      |> Enum.each(
        &Api.Messaging.do_discard_message!(&1, %{descarte_motivo: motivo},
          tenant: appointment.clinic_id,
          authorize?: false
        )
      )
    end)

    :ok
  rescue
    erro ->
      # Best-effort como o resto: o bloco já foi cancelado/excluído e não pode cair porque a fila
      # não pôde ser limpa. O pior caso volta a ser o de antes desta correção.
      Logger.warning(
        "descarte de mensagens falhou (#{appointment.id}): #{Exception.message(erro)}"
      )

      :ok
  end

  defp avisar(appointment, kind) do
    Api.Repo.with_clinic(appointment.clinic_id, fn ->
      clinic = Api.Accounts.get_clinic!(appointment.clinic_id, authorize?: false)

      # `msg_confirmacao_auto` governa **só** a confirmação — é o que a tela diz que ele faz
      # ("mandar confirmação quando um agendamento é criado"). Silenciar remarcação e
      # cancelamento por causa dele seria um controle fazendo três coisas com um rótulo só; e o
      # freio de mão de verdade continua sendo o consentimento da ficha, que o `Dispatch` checa.
      if kind != :confirmacao or clinic.msg_confirmacao_auto,
        do: disparar(clinic, appointment, kind)
    end)

    :ok
  rescue
    erro ->
      # Best-effort: o agendamento já está gravado e não pode cair porque a comunicação falhou.
      Logger.warning("mensagem de #{kind} falhou (#{appointment.id}): #{Exception.message(erro)}")

      :ok
  end

  defp disparar(clinic, appointment, kind) do
    for attendance <- participantes(clinic, appointment, kind) do
      # `disparado_por_id` fica **nulo**: quem disparou foi a regra, não a pessoa. É o que a
      # timeline lê como "automático" (§6) — e é a distinção que a recepção usa para saber se
      # precisa fazer algo.
      Dispatch.dispatch(clinic, attendance, attendance.patient, kind, disparado_por_id: nil)
    end

    :ok
  end

  # Quem recebe, por gatilho.
  #
  # **`:cancelamento` é o único que não filtra por `viva?/1`**, e a inversão é o ponto: cancelar o
  # bloco cascateia as presenças para `:cancelada` (`CascadeToAttendances`) *antes* de o notifier
  # rodar, então filtrar vivas aqui devolveria lista vazia e ninguém seria avisado do cancelamento
  # — exatamente a mensagem que mais importa. Quem saiu da turma antes não aparece nessa lista
  # porque sair é **destruir** a presença (`RemoveParticipants`), não cancelá-la.
  defp participantes(clinic, appointment, kind) do
    appointment
    |> Ash.load!([attendances: [:patient]], tenant: clinic.id, authorize?: false)
    |> Map.fetch!(:attendances)
    |> filtrar_por_gatilho(kind)
  end

  defp filtrar_por_gatilho(attendances, :cancelamento), do: attendances

  # Só presenças **vivas** e, na confirmação, ainda **sem confirmação**. O segundo filtro existe
  # por causa do `:add_participant`: entrar numa turma dispara o notifier para o bloco inteiro, e
  # sem ele quem já estava lá receberia a mesma confirmação de novo a cada colega novo. Numa turma
  # de 4 isso é o paciente recebendo 4 vezes — o defeito mais visível que esta fatia poderia ter.
  #
  # Remarcação **não** tem esse filtro, e é de propósito: remarcar duas vezes são dois avisos, e o
  # segundo é tão necessário quanto o primeiro.
  defp filtrar_por_gatilho(attendances, kind) do
    vivas = Enum.filter(attendances, &Api.Scheduling.Attendance.viva?/1)

    if kind == :confirmacao,
      do: Enum.reject(vivas, &ja_confirmada?/1),
      else: vivas
  end

  defp ja_confirmada?(attendance) do
    Api.Messaging.Message
    |> Ash.Query.for_read(:read, %{}, tenant: attendance.clinic_id, authorize?: false)
    |> Ash.Query.filter(attendance_id == ^attendance.id and kind == :confirmacao)
    |> Ash.exists?(authorize?: false)
  end
end
