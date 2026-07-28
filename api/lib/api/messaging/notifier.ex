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

  Só `:schedule` e `:add_participant` — criação e entrada numa turma. Remarcação e cancelamento
  ficam de fora **por decisão** (C7): são copy nova, não estrutura nova, e entram depois sem
  mexer em nada disto.

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

  # A escrita de LOTE (materialização de pacote) passa por aqui uma vez por sessão. Um pacote de
  # 40 sessões mandaria 40 confirmações de uma vez — que é spam, e no WhatsApp seria spam *pago*.
  # A marca viaja no contexto do changeset, posta por `Api.Packages.Bulk`; é a mesma que o
  # `Api.Notifications.Notifier` usa para suprimir a caixa, e pelo mesmo motivo.
  #
  # **Esta linha é idêntica à de lá, e continua duplicada de propósito.** O bate-volta propôs
  # extraí-la; as duas saídas pioram o código: função não casa em head, e a `defguard` equivalente
  # fica menos legível do que a linha que ela substitui. O risco real da cópia — alguém trocar a
  # marca em `Api.Packages.Bulk` e esquecer um dos dois assinantes, sem erro nenhum e com 40
  # mensagens saindo — está preso por teste, em `Api.Messaging.NotifierTest`.
  #
  # **Vem antes de todas as outras cláusulas**, como lá: uma cláusula específica atrás de uma
  # geral nunca roda, e o sintoma seria só uma mensagem a mais — sem erro nenhum.
  @impl true
  def notify(%Ash.Notifier.Notification{changeset: %{context: %{bulk_pacote: true}}}), do: :ok

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: name},
        data: appointment
      })
      when name in [:schedule, :add_participant] do
    confirmar(appointment)
    :ok
  end

  @impl true
  def notify(_notification), do: :ok

  defp confirmar(appointment) do
    Api.Repo.with_clinic(appointment.clinic_id, fn ->
      clinic = Api.Accounts.get_clinic!(appointment.clinic_id, authorize?: false)

      if clinic.msg_confirmacao_auto, do: disparar(clinic, appointment)
    end)
  rescue
    erro ->
      # Best-effort: o agendamento já está gravado e não pode cair porque a comunicação falhou.
      Logger.warning(
        "confirmação automática falhou (#{appointment.id}): #{Exception.message(erro)}"
      )

      :ok
  end

  defp disparar(clinic, appointment) do
    for attendance <- participantes(clinic, appointment) do
      # `disparado_por_id` fica **nulo**: quem disparou foi a regra, não a pessoa. É o que a
      # timeline lê como "automático" (§6) — e é a distinção que a recepção usa para saber se
      # precisa fazer algo.
      Dispatch.dispatch(clinic, attendance, attendance.patient, :confirmacao,
        disparado_por_id: nil
      )
    end

    :ok
  end

  # Só presenças **vivas** (quem foi cancelado do bloco não é participante) e ainda **sem
  # confirmação**. O segundo filtro existe por causa do `:add_participant`: entrar numa turma
  # dispara o notifier para o bloco inteiro, e sem ele quem já estava lá receberia a mesma
  # confirmação de novo a cada colega novo. Numa turma de 4 isso é o paciente recebendo 4 vezes —
  # o defeito mais visível que esta fatia poderia ter.
  defp participantes(clinic, appointment) do
    appointment
    |> Ash.load!([attendances: [:patient]], tenant: clinic.id, authorize?: false)
    |> Map.fetch!(:attendances)
    |> Enum.filter(&Api.Scheduling.Attendance.viva?/1)
    |> Enum.reject(&ja_confirmada?(clinic, &1))
  end

  defp ja_confirmada?(clinic, attendance) do
    Api.Messaging.Message
    |> Ash.Query.for_read(:read, %{}, tenant: clinic.id, authorize?: false)
    |> Ash.Query.filter(attendance_id == ^attendance.id and kind == :confirmacao)
    |> Ash.exists?(authorize?: false)
  end
end
