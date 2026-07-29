defmodule Api.Repo.Migrations.ProfessionalHoursRls do
  @moduledoc """
  RLS + índice de apoio à FK para `professional_hours`, escritos à mão (o gerador do Ash não
  conhece as policies nem prefixa índices do jeito que o cascade precisa). Espelha
  `SchedulingRls` (ADR-018) e `SchedulingIndexTuning` (bate-volta F1).

  1. **RLS** (defesa-em-profundidade da tenancy por atributo): mesmo que o filtro do Ash seja
     contornado, o Postgres só devolve/aceita linhas do `clinic_id` na GUC `cinetra.clinic_id`.
     Sem GUC → 0 linhas (fail-closed). Roda como `postgres`; o app conecta NOBYPASSRLS.

  2. **Índice de `professional_id`** (leading, sem o `clinic_id` que o Ash prefixaria): o
     cascade `ON DELETE` de um profissional faz `WHERE professional_id = $1`, e a identidade
     única `(clinic_id, professional_id, dow)` não serve esse lookup.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE professional_hours ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE professional_hours FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON professional_hours
      USING (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
      WITH CHECK (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
    """

    create index(:professional_hours, [:professional_id])
  end

  def down do
    drop_if_exists(index(:professional_hours, [:professional_id]))
    execute "DROP POLICY IF EXISTS tenant_isolation ON professional_hours"
    execute "ALTER TABLE professional_hours NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE professional_hours DISABLE ROW LEVEL SECURITY"
  end
end
