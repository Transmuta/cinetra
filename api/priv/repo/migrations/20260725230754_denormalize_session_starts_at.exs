defmodule Api.Repo.Migrations.DenormalizeSessionStartsAt do
  @moduledoc """
  `attendances.session_starts_at` — a cópia do `starts_at` do bloco na presença (doc 43 §4), com o
  índice `(clinic_id, patient_id, session_starts_at)` que o histórico da ficha percorre.

  Ajustada à mão sobre o que o `mix ash.codegen denormalize_session_starts_at` gerou, em três
  pontos que o gerador não tem como saber:

    * **coluna nasce nula, é preenchida, e só então vira `NOT NULL`.** O gerado adiciona
      `null: false` de uma vez, o que falha em qualquer banco com linha (`column contains null
      values`). O backfill é o `UPDATE … FROM appointments` do meio;
    * **`CONCURRENTLY` nos índices** (`.claude/rules/migrations.md`): `attendances` é tabela quente
      e as migrations rodam no `release_command` do deploy. O `DROP` do índice
      `(clinic_id, patient_id)` — agora prefixo estrito do novo — segue a mesma regra;
    * a ordem: cria o índice novo **antes** de derrubar o antigo, para não deixar janela sem índice
      por paciente.

  O `ALTER … SET NOT NULL` faz uma varredura da tabela sob `ACCESS EXCLUSIVE`. Em `attendances` no
  volume de hoje (10 mil linhas) é milissegundos; se um dia doer, o caminho é a dança do
  `CHECK … NOT VALID` + `VALIDATE CONSTRAINT`. Não vale a complexidade agora.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:attendances) do
      add(:session_starts_at, :utc_datetime)
    end

    execute """
    UPDATE attendances a
       SET session_starts_at = ap.starts_at
      FROM appointments ap
     WHERE ap.id = a.appointment_id
       AND a.session_starts_at IS NULL
    """

    execute "ALTER TABLE attendances ALTER COLUMN session_starts_at SET NOT NULL"

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS attendances_clinic_id_patient_id_session_starts_at_index
    ON attendances (clinic_id, patient_id, session_starts_at)
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS attendances_clinic_id_patient_id_index"
  end

  def down do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS attendances_clinic_id_patient_id_index
    ON attendances (clinic_id, patient_id)
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS attendances_clinic_id_patient_id_session_starts_at_index"

    alter table(:attendances) do
      remove(:session_starts_at)
    end
  end
end
