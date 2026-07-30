defmodule Api.Repo.Migrations.CreatePackages do
  @moduledoc """
  As tabelas da Fatia 3 (pacotes): `packages` e a grade `package_schedules`.

  A parte gerada pelo `mix ash.codegen` cria as tabelas, FKs, índices e o CHECK de total > 0. O
  bloco de RLS ao fim é escrito à mão — o gerador do Ash não o produz — no molde de
  `SchedulingRls`/`WaitlistConstraintAndRls`: defesa-em-profundidade da tenancy por atributo
  (ADR-018). **Nada disto aparece no `mix test`** (sandbox `postgres`, BYPASSRLS); a verificação é
  por `psql` com role NOBYPASSRLS e faz parte do critério de pronto.
  """
  use Ecto.Migration

  @tables ~w(packages package_schedules)

  def up do
    create table(:packages, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:nome, :text, null: false)
      add(:total, :bigint, null: false)
      add(:falta_punitiva, :boolean, null: false)
      add(:cor, :text, null: false)
      add(:data_inicio, :date, null: false)
      add(:status, :text, null: false, default: "ativo")

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :clinic_id,
        references(:clinics,
          column: :id,
          name: "packages_clinic_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :patient_id,
        references(:patients,
          column: :id,
          name: "packages_patient_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :restrict
        ),
        null: false
      )

      add(
        :appointment_type_id,
        references(:appointment_types,
          column: :id,
          name: "packages_appointment_type_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :restrict
        ),
        null: false
      )
    end

    create index(:packages, [:appointment_type_id])

    create index(:packages, [:clinic_id, :patient_id])

    create table(:package_schedules, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true)
      add(:dows, {:array, :bigint}, null: false)
      add(:horarios, :map, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :clinic_id,
        references(:clinics,
          column: :id,
          name: "package_schedules_clinic_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :package_id,
        references(:packages,
          column: :id,
          name: "package_schedules_package_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :professional_id,
        references(:professionals,
          column: :id,
          name: "package_schedules_professional_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :restrict
        ),
        null: false
      )
    end

    create index(:package_schedules, [:professional_id])

    create index(:package_schedules, [:clinic_id, :package_id])

    create constraint(:packages, :packages_total_positive,
             check: """
               total > 0
             """
           )

    # RLS (ADR-018) — escrito à mão, o gerador não produz. Mesmo `tenant_isolation` das demais.
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

    drop_if_exists(constraint(:packages, :packages_total_positive))

    drop(constraint(:package_schedules, "package_schedules_clinic_id_fkey"))

    drop(constraint(:package_schedules, "package_schedules_package_id_fkey"))

    drop(constraint(:package_schedules, "package_schedules_professional_id_fkey"))

    drop_if_exists(index(:package_schedules, [:clinic_id, :package_id]))

    drop_if_exists(index(:package_schedules, [:professional_id]))

    drop(table(:package_schedules))

    drop(constraint(:packages, "packages_clinic_id_fkey"))

    drop(constraint(:packages, "packages_patient_id_fkey"))

    drop(constraint(:packages, "packages_appointment_type_id_fkey"))

    drop_if_exists(index(:packages, [:clinic_id, :patient_id]))

    drop_if_exists(index(:packages, [:appointment_type_id]))

    drop(table(:packages))
  end
end
