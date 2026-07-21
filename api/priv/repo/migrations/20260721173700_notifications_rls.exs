defmodule Api.Repo.Migrations.NotificationsRls do
  @moduledoc """
  RLS na tabela `notifications` (doc 31) — defesa-em-profundidade da tenancy por atributo
  (ADR-018), no molde de `WaitlistConstraintAndRls`/`SchedulingRls`. O recorte **por
  destinatário** (`recipient_id == actor`) é da policy do recurso; a RLS aqui garante só o
  isolamento por clínica (a caixa de uma clínica não vaza para outra).

  **Nada disto aparece no `mix test`** (sandbox `postgres`, BYPASSRLS). A prova é por `psql` com
  role NOBYPASSRLS, parte do critério de pronto da fatia.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE notifications ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE notifications FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON notifications
      USING (clinic_id = current_setting('movimento.clinic_id', true)::uuid)
      WITH CHECK (clinic_id = current_setting('movimento.clinic_id', true)::uuid)
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation ON notifications"
    execute "ALTER TABLE notifications NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE notifications DISABLE ROW LEVEL SECURITY"
  end
end
