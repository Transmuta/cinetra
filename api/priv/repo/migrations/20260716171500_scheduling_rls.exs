defmodule Api.Repo.Migrations.SchedulingRls do
  @moduledoc """
  RLS como defesa-em-profundidade da tenancy por atributo (ADR-018) para `clinic_hours` e
  `schedule_exceptions`, espelhando `AppointmentTypesRls`. Mesmo que o filtro do Ash
  (`WHERE clinic_id = ...`) seja contornado, o Postgres só devolve/aceita linhas do `clinic_id`
  setado na GUC `cinetra.clinic_id`. Sem GUC → 0 linhas (fail-closed).

  Escrita à mão e separada da autogerada de propósito: o gerador do Ash não conhece as
  policies, e o Postgres recusa ALTER em coluna usada por policy — o RLS entra depois que as
  tabelas estão no formato final. Roda como `postgres` (owner); o app conecta como role
  NOBYPASSRLS.
  """
  use Ecto.Migration

  @tables ~w(clinic_hours schedule_exceptions)

  def up do
    for table <- @tables do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute """
      CREATE POLICY tenant_isolation ON #{table}
        USING (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
        WITH CHECK (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
      """
    end
  end

  def down do
    for table <- @tables do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end
end
