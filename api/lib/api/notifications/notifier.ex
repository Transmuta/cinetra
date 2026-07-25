defmodule Api.Notifications.Notifier do
  @moduledoc """
  A cola Ash entre os eventos de domínio e o `Api.Notifications.Fanout` (doc 31). Um `Ash.Notifier`
  roda **depois do commit**, então a caixa nunca registra um evento que a transação ainda vai
  desfazer. Anexado ao `Appointment` (ciclo de vida) e ao `Membership` (convite aceito).

  Toda decisão de *quem recebe* mora no `Fanout`; aqui só se roteia a ação para a função certa. As
  gravações do Fanout são best-effort e engolidas lá — este notifier sempre devolve `:ok`, para
  não transformar uma falha de notificação em erro da ação de origem.
  """
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.Appointment,
        action: %{name: name},
        data: appointment,
        changeset: changeset,
        actor: actor
      }) do
    Api.Notifications.Fanout.appointment_touched(appointment, name, actor)

    Api.Notifications.Fanout.slot_maybe_opened(
      appointment,
      slot_action(name, appointment, changeset),
      actor
    )

    :ok
  end

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Accounts.Membership,
        action: %{name: :accept_invite},
        data: membership
      }) do
    Api.Notifications.Fanout.member_joined(membership)
    :ok
  end

  @impl true
  def notify(_notification), do: :ok

  # A2 (doc 41), achado A-5 do bate-volta: o desfecho do bloco virou ROLLUP das presenças, então a
  # falta que abre vaga não chega mais como `:mark_missed` — chega como `:apply_participant_rollup`,
  # e o aviso para a fila sumiria assim que a UI migrasse para a presença por participante.
  #
  # O gate é a **transição**, não o estado: o rollup roda a cada mexida numa presença (justificar
  # uma falta depois roda de novo, com o bloco já em `:faltou`), e sem comparar com o valor
  # anterior a mesma vaga seria anunciada várias vezes.
  defp slot_action(:apply_participant_rollup, %{status: :faltou}, %Ash.Changeset{
         data: %{status: anterior}
       })
       when anterior != :faltou,
       do: :mark_missed

  defp slot_action(name, _appointment, _changeset), do: name
end
