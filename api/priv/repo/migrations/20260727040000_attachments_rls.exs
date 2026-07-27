defmodule Api.Repo.Migrations.AttachmentsRls do
  @moduledoc """
  RLS para `attachments` e `attachment_events` (doc 51), espelhando `SchedulingRls`.

  Defesa-em-profundidade da tenancy por atributo (ADR-018): mesmo que o `WHERE clinic_id = ...`
  do Ash seja contornado, o Postgres só devolve/aceita linhas do `clinic_id` que está na GUC
  `movimento.clinic_id`. Sem GUC → 0 linhas (fail-closed).

  Aqui o valor é maior que nas outras tabelas: `attachments.chave` é o **endereço do laudo no
  bucket**. Uma leitura que vazasse entre clínicas não vazaria só metadado — vazaria o caminho do
  arquivo, que é o insumo de uma URL assinada.

  Escrita à mão e separada da autogerada de propósito (o gerador do Ash não conhece as policies).
  Roda como `postgres` (owner); o app conecta como role NOBYPASSRLS.
  """
  use Ecto.Migration

  @tables ~w(attachments attachment_events)

  def up do
    for table <- @tables do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute """
      CREATE POLICY tenant_isolation ON #{table}
        USING (clinic_id = current_setting('movimento.clinic_id', true)::uuid)
        WITH CHECK (clinic_id = current_setting('movimento.clinic_id', true)::uuid)
      """
    end
  end

  def down do
    for table <- @tables do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end
end
