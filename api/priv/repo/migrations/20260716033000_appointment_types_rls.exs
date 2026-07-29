defmodule Api.Repo.Migrations.AppointmentTypesRls do
  @moduledoc """
  RLS como defesa-em-profundidade da tenancy por atributo (ADR-018), espelhando
  `ProfessionalsRls`. Mesmo que o filtro do Ash (`WHERE clinic_id = ...`) seja contornado
  (query crua, bug, authorize?: false sem tenant), o Postgres só devolve linhas do
  `clinic_id` setado na GUC `cinetra.clinic_id`. Sem GUC → 0 linhas (fail-closed).

  Migration escrita à mão e separada da autogerada de propósito: o gerador do Ash não
  conhece as policies, e o Postgres recusa ALTER em coluna usada por policy — então o RLS
  entra depois que a tabela está no formato final.

  Roda como `postgres` (owner) no deploy/migrate; o app conecta como um role
  NOSUPERUSER/NOBYPASSRLS que fica sujeito à policy.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE appointment_types ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE appointment_types FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON appointment_types
      USING (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
      WITH CHECK (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation ON appointment_types"
    execute "ALTER TABLE appointment_types NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE appointment_types DISABLE ROW LEVEL SECURITY"
  end
end
