defmodule Api.Repo.Migrations.IndicesDasFacetas do
  @moduledoc """
  Índices para as duas facetas da tela de auditoria (bate-volta, achado A-2).

  A sidebar filtra por **ação** (`?acao=`) e por **tipo de registro** (`?resource=`), e nenhum
  dos dois tinha índice: os três existentes cobriam `clinic_id`, `(resource, record_id)` e
  `user_id`. O `record_index` não serve a faceta de recurso sozinha, porque `record_id` fica no
  meio e impede que `at` seja usado para ordenar — o plano lia o recorte inteiro do heap e só
  então ordenava.

  Medido no pior caso (faceta rara, recorte de 84 mil linhas):

      sem índice: 14,4 ms · 7.784 buffers   (Rows Removed by Filter: 84.002 — o recorte inteiro)
      página sem filtro: 0,090 ms · 9 buffers

  Ou seja: a resposta mais barata da tela (um `?acao=revoke_access`, que devolve um punhado de
  linhas em 90 dias) era a que custava mais caro. `at` entra nos dois índices porque o feed
  sempre ordena por ele; sem a coluna, o índice resolveria o `WHERE` e devolveria o trabalho de
  ordenar.

  ## `CONCURRENTLY` é obrigatório aqui

  `audit_events` tem dado desde o backfill e é a tabela mais escrita do sistema — todo evento de
  todos os doze recursos passa por ela. Um `CREATE INDEX` comum toma `ShareLock`, que conflita
  com o `RowExclusiveLock` de qualquer `INSERT`: a agenda inteira ficaria na fila enquanto o
  índice constrói. E, como as migrations rodam no `release_command`, essa janela cairia **no
  deploy** (`.claude/rules/migrations.md`).

  As duas anotações são obrigatórias e andam juntas: `CONCURRENTLY` não roda dentro de transação,
  e a migration do Ecto abre uma por padrão.

  ## O que fica para depois

  Com `audit_events_resource_index` no ar, o `audit_events_record_index`
  (`clinic_id, resource, record_id, at`) passa a servir **só** o deep-link "ver histórico deste
  registro" — e para isso `resource` é peso morto, porque uuid não colide entre recursos. Ele
  poderia encolher para `(clinic_id, record_id, at)`. Não é feito aqui: são cinco índices numa
  tabela quente, e trocar um deles é decisão de custo de escrita que merece medição própria.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_events_action_index
      ON audit_events (clinic_id, action, at)
    """

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS audit_events_resource_index
      ON audit_events (clinic_id, resource, at)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS audit_events_action_index"
    execute "DROP INDEX CONCURRENTLY IF EXISTS audit_events_resource_index"
  end
end
