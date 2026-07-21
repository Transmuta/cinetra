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
        actor: actor
      }) do
    Api.Notifications.Fanout.appointment_touched(appointment, name, actor)
    Api.Notifications.Fanout.slot_maybe_opened(appointment, name, actor)
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
end
