defmodule Api.Repo.Migrations.AddOban do
  @moduledoc """
  As tabelas do Oban (`oban_jobs` etc.), para o cron de limpeza dos `SlotHold` vencidos
  (doc 09 §6.2). Delega ao instalador do próprio Oban.
  """
  use Ecto.Migration

  def up, do: Oban.Migration.up()

  def down, do: Oban.Migration.down(version: 1)
end
