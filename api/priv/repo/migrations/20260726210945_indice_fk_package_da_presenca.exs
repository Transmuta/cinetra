defmodule Api.Repo.Migrations.IndiceFkPackageDaPresenca do
  @moduledoc """
  Os índices que servem à **checagem de FK** das relações que a H64 criou/alterou (achado do
  bate-volta da Onda 5, docs/47).

  Ao apagar o pai, o Postgres emite `WHERE <coluna_fk> = $1` no filho — **sem `clinic_id`**,
  porque ele não tem noção de tenant. Índice `(clinic_id, coluna)` não serve a essa forma: a
  coluna não lidera. Medido antes:

    * `attendances.package_id` → *Index Only Scan* varrendo o índice composto inteiro
      (13 buffers, custo 197) contra 2 buffers e custo 13 do dedicado;
    * `appointments_versions.user_id` e `attendances_versions.user_id` → **Seq Scan**, porque
      não havia índice nenhum com a coluna. A H64 trocou o `NO ACTION` dessas duas por
      `SET NULL`, o que transformou "o DELETE do usuário é recusado" em "o DELETE do usuário
      **escreve** em toda linha correspondente" — e a trilha é a tabela que mais cresce do
      sistema (3× a base, doc 43 §5f).

  **Por que os das versões são SQL na mão:** os recursos `*.Version` são gerados pelo
  AshPaperTrail e não têm bloco `custom_indexes` para declarar. É o mesmo precedente dos índices
  `*_clinic_time_idx`, criados assim na migration `20260719200000_agenda_constraint_and_rls`.

  **`CONCURRENTLY` nos três** (`.claude/rules/migrations.md`): `CREATE INDEX` comum toma
  `ShareLock` e fila todo `INSERT`/`UPDATE` da tabela enquanto constrói, e estas migrations rodam
  no `release_command` do deploy. Numa base vazia o `CONCURRENTLY` custa alguns ms a mais (faz
  duas varreduras); numa que já tem histórico, é a diferença entre travar ou não a escrita da
  agenda e da trilha — e uma migration não sabe em qual das duas vai rodar.
  """

  use Ecto.Migration

  # As duas são obrigatórias: `CONCURRENTLY` não roda dentro de transação, e a migration do Ecto
  # abre uma por padrão.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS attendances_package_id_index
      ON attendances (package_id)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS appointments_versions_user_id_index
      ON appointments_versions (user_id)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS attendances_versions_user_id_index
      ON attendances_versions (user_id)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS attendances_versions_user_id_index"
    execute "DROP INDEX CONCURRENTLY IF EXISTS appointments_versions_user_id_index"
    execute "DROP INDEX CONCURRENTLY IF EXISTS attendances_package_id_index"
  end
end
