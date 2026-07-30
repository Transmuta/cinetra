defmodule Api.Notifications.Notification.Changes.StampReadAtOnce do
  @moduledoc """
  Carimba `read_at` com o instante atual — **uma vez** (idempotente): marcar como lida de novo não
  reescreve o instante da primeira leitura. Módulo próprio (não fn anônima) para seguir a convenção
  do projeto (ash.md — "Custom Modules vs. Anonymous Functions").
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_data(changeset, :read_at) do
      nil -> Ash.Changeset.change_attribute(changeset, :read_at, DateTime.utc_now())
      _already -> changeset
    end
  end
end
