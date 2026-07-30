defmodule Api.Repo.Migrations.IndiceDoFeedComDesempate do
  @moduledoc """
  `audit_events_feed_index` passa a incluir o `id` (bate-volta, causa C6 / achado A-3).

  A leitura do feed ordena por `at DESC, id DESC` — o `id` é o desempate que dá **ordem total**,
  sem a qual duas linhas do mesmo instante repetiriam ou sumiriam entre páginas. O índice tinha
  só `(clinic_id, at)`, então o banco não conseguia servir essa ordenação e acrescentava um nó de
  `Sort`. Medido: **2,52 ms · 19 buffers** contra **0,090 ms · 9 buffers** — 28×.

  O caso ruim é comum aqui, e não teórico: `at` vem de `scope.now` (ADR-009), que é **estável por
  requisição**, então toda escrita em massa grava N linhas com o mesmo `at`. Uma massa de pacote
  de 200 sessões produz um grupo de 200 que o `Sort` materializa inteiro.

  ## `CONCURRENTLY`, e por que agora sim

  Quando a tabela nasceu (`20260728053848`) ela estava **vazia**, e a regra do projeto
  (`.claude/rules/migrations.md`) diz que ali `CONCURRENTLY` só atrapalha — faz duas varreduras
  para nada. Depois do backfill a tabela **tem dado**, e é a mais escrita do sistema: um
  `CREATE INDEX` comum toma `ShareLock` e põe todo `INSERT` na fila enquanto constrói. Como as
  migrations rodam no `release_command`, essa janela cairia **no deploy**.

  As duas anotações são obrigatórias: `CONCURRENTLY` não roda dentro de transação, e a migration
  do Ecto abre uma por padrão.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS audit_events_feed_index"

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_events_feed_index
      ON audit_events (clinic_id, at, id)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS audit_events_feed_index"

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_events_feed_index
      ON audit_events (clinic_id, at)
    """
  end
end
