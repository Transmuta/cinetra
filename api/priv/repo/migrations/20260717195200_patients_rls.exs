defmodule Api.Repo.Migrations.PatientsRls do
  @moduledoc """
  RLS como defesa-em-profundidade da tenancy por atributo (ADR-018), igual a `professionals`.
  Mesmo que o filtro do Ash (`WHERE clinic_id = ...`) seja contornado (query crua, bug,
  authorize?: false sem tenant), o Postgres só devolve/aceita linhas do `clinic_id` setado na
  GUC `movimento.clinic_id`. Sem GUC → 0 linhas (fail-closed).

  Escrita depende de `Api.Directory.Changes.SetTenantGuc` setar a GUC dentro da transação da
  ação (senão o `WITH CHECK` barra o INSERT/UPDATE). Roda como `postgres` (owner) no
  migrate; o app conecta como role NOBYPASSRLS sujeito à policy.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE patients ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE patients FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON patients
      USING (clinic_id = current_setting('movimento.clinic_id', true)::uuid)
      WITH CHECK (clinic_id = current_setting('movimento.clinic_id', true)::uuid)
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation ON patients"
    execute "ALTER TABLE patients NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE patients DISABLE ROW LEVEL SECURITY"
  end
end
