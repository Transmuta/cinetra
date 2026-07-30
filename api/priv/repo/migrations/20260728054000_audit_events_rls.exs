defmodule Api.Repo.Migrations.AuditEventsRls do
  @moduledoc """
  RLS para `audit_events` (doc 62 §2), espelhando `SchedulingRls`/`AttachmentsRls`.

  Defesa-em-profundidade da tenancy por atributo (ADR-018): mesmo que o `WHERE clinic_id = ...`
  do Ash seja contornado, o Postgres só devolve/aceita linhas do `clinic_id` que está na GUC
  `cinetra.clinic_id`. Sem GUC → 0 linhas (fail-closed).

  Aqui o valor é o maior de todas as tabelas do projeto, e vale dizer por quê: `audit_events` é a
  **única** que concentra, numa linha só, o histórico da agenda, os papéis concedidos, o diff da
  ficha e quem leu qual laudo — de todos os recursos ao mesmo tempo. Era exatamente a armadilha
  (1) do doc 25 §11.2 ("a tabela de versões viraria um buraco por fora do isolamento por clínica,
  justamente com o histórico inteiro dentro"), agora com doze recursos em vez de dois.

  E o `mix test` **não pega** um furo aqui: o sandbox conecta como `postgres` (BYPASSRLS). A
  verificação é por `psql` como `cinetra_app` — a mesma que já custou 3 bugs na fatia de Tipos
  e 1 no doc 58.

  Escrita à mão e separada da autogerada de propósito (o gerador do Ash não conhece as policies).
  Roda como `postgres` (owner); o app conecta como role NOBYPASSRLS.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE audit_events FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON audit_events
      USING (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
      WITH CHECK (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation ON audit_events"
    execute "ALTER TABLE audit_events NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE audit_events DISABLE ROW LEVEL SECURITY"
  end
end
