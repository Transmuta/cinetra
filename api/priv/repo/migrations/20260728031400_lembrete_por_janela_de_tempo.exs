defmodule Api.Repo.Migrations.LembretePorJanelaDeTempo do
  @moduledoc """
  O índice que faltava para o cron de lembrete ao paciente (doc 52 §7).

  ## O que foi medido

  `Api.Messaging.ReminderJob` varre, por clínica, as presenças que começam numa janela de uma
  hora. Os índices que `attendances` tinha eram `(clinic_id, package_id)`,
  `(clinic_id, patient_id, session_starts_at)` e `(clinic_id, appointment_id, patient_id)` —
  **nenhum permite range em `session_starts_at` sem igualdade antes**. O planejador caía no de
  `package_id`, o único com `clinic_id` na frente, e filtrava o resto na heap. Na clínica de
  volume (10.185 presenças), pelo caminho da app:

      Bitmap Heap Scan on attendances  (actual time=22.371..134.440 rows=15)
        Rows Removed by Filter: 10170
        Buffers: shared hit=178 read=16685
      Execution Time: 134.804 ms

  **134,8 ms e 16.863 buffers para devolver 15 linhas** — e isso por clínica, de hora em hora,
  assim que alguém configurar `msg_lembrete_horas`. Hoje o custo está latente porque o padrão é
  desligado.

  ## Por que NÃO é índice parcial

  A tentação era `WHERE status = 'prevista'` (4.935 de 10.185 linhas). Não vale o risco: um índice
  parcial só é escolhido quando o Postgres prova que o predicado da query **implica** o do índice,
  e o AshPostgres emite a coluna com cast (`status::varchar`). É exatamente a armadilha do doc 35
  ("D-A — o diagnóstico correto"), em que um índice de expressão ficou íntegro e nunca foi usado.
  O ganho do parcial seria metade do tamanho; o risco é o índice não anexar **em silêncio**.

  ## `CONCURRENTLY` é obrigatório aqui

  `attendances` é tabela quente e com volume (`.claude/rules/migrations.md`): `CREATE INDEX` comum
  toma `ShareLock` e põe todo `INSERT`/`UPDATE` da agenda na fila enquanto constrói — e as
  migrations rodam no `release_command` do deploy. As duas anotações abaixo são o par obrigatório:
  `CONCURRENTLY` não roda dentro de transação, e a migration do Ecto abre uma por padrão.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS attendances_clinic_session_starts_at_index
      ON attendances (clinic_id, session_starts_at)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS attendances_clinic_session_starts_at_index"
  end
end
