defmodule Api.Repo.Migrations.DropRedundantAttendanceIndex do
  @moduledoc """
  Derruba `attendances_clinic_id_appointment_id_index`, prefixo estrito do único
  `attendances_one_per_patient_per_appt_index` — `(clinic_id, appointment_id, patient_id)`.

  Medido no bate-volta da Onda 3 (doc 43 §5f): `idx_scan=0` e 520 kB contra 684 varreduras do
  único na mesma janela. Era custo de escrita puro numa tabela que a massa por pacote reescreve
  (destroy + insert por sessão).

  `CONCURRENTLY` porque `DROP INDEX` comum toma `ACCESS EXCLUSIVE` na tabela e entra na fila atrás
  de qualquer leitura em curso — e as migrations rodam no `release_command` do deploy
  (`.claude/rules/migrations.md`). As duas anotações são obrigatórias: `CONCURRENTLY` não roda
  dentro de transação, e a migration do Ecto abre uma por padrão.

  Gerada por `mix ash.codegen drop_redundant_attendance_index` e ajustada à mão só no `CONCURRENTLY`
  — o snapshot correspondente é o que o codegen escreveu.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS attendances_clinic_id_appointment_id_index"
  end

  def down do
    execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS attendances_clinic_id_appointment_id_index ON attendances (clinic_id, appointment_id)"
  end
end
