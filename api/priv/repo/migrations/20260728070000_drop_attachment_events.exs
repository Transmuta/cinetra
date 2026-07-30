defmodule Api.Repo.Migrations.DropAttachmentEvents do
  @moduledoc """
  Sai `attachment_events`, absorvida por `audit_events` (doc 63 §3).

  A tabela foi criada com o desenho certo — `AshPaperTrail` registra escrita, e a pergunta da
  LGPD sobre anexo é *"quem **leu** o laudo?"*, que leitura nenhuma produz versão para responder.
  O que estava errado era ela ser uma **segunda** tabela de eventos: nenhuma rota a expunha, e a
  resposta a essa pergunta só saía por `psql`. Agora a mesma linha entra em `audit_events` com
  `resource = 'attachment'`, e a tela de auditoria a lê junto com o resto.

  O conteúdo já foi copiado por `BackfillAuditEvents`, que roda antes desta. Mesmo raciocínio do
  `DropPaperTrailTables`: as migrations rodam em ordem, então não há janela em que o dado exista
  só aqui.

  O `down` recria a tabela **vazia** (com a RLS que ela tinha): o histórico continua em
  `audit_events`, e é isso que importa preservar.
  """
  use Ecto.Migration

  def up do
    execute "DROP TABLE IF EXISTS attachment_events"
  end

  def down do
    execute """
    CREATE TABLE IF NOT EXISTS attachment_events (
      id uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
      acao text NOT NULL,
      attachment_id uuid NOT NULL,
      patient_id uuid NOT NULL,
      user_id uuid,
      nome text NOT NULL,
      inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      clinic_id uuid NOT NULL REFERENCES clinics(id) ON DELETE CASCADE
    )
    """

    execute "CREATE INDEX IF NOT EXISTS attachment_events_clinic_id_attachment_id_inserted_at_index ON attachment_events (clinic_id, attachment_id, inserted_at)"

    execute "ALTER TABLE attachment_events ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE attachment_events FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON attachment_events
      USING (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
      WITH CHECK (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
    """
  end
end
