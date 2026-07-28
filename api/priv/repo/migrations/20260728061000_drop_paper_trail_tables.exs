defmodule Api.Repo.Migrations.DropPaperTrailTables do
  @moduledoc """
  O "contract" do expand-contract (doc 63 §4): saem `appointments_versions` e
  `attendances_versions`, as tabelas de versão do `AshPaperTrail`.

  ## Por que dropar agora, e não daqui a 90 dias

  O plano original as deixaria esvaziar pela poda antes do `DROP`, pelo reflexo certo de não
  apagar histórico. Mas a migration **anterior** (`BackfillAuditEvents`) já copiou cada linha
  para `audit_events` — com o diff `from`/`to` resolvido, que é mais do que estas tabelas
  guardavam — e as migrations rodam **em ordem**, cada uma na própria transação. Se o backfill
  falhar, a execução para nele e este `DROP` não chega a rodar. Não há janela em que o dado
  exista só aqui.

  (A primeira versão desta nota dizia "na mesma transação de release". Não é verdade — o Ecto
  abre uma transação **por migration** —, e a conclusão continua valendo pelo motivo certo: o
  que garante a ordem é a parada na primeira falha, não uma transação englobante.)

  Manter as duas por 90 dias custaria o oposto do que parece: tabela sem resource é ponto cego
  (nada a valida, nada a cobre), a poda teria de saber que a coluna de tempo delas se chama
  diferente, e o teste de contrato de `ON DELETE` já as reporta como "FK sem dono" — foi ele que
  cobrou esta decisão em vez de deixá-la vencer o prazo em silêncio.

  ## O `down` não recupera o dado

  Recria as tabelas **vazias**, para que a migration seja reversível estruturalmente. O
  histórico continua em `audit_events`, que é o ponto: a trilha não some com o rollback do
  esquema. Um rollback real até aqui exigiria restaurar backup — e é o que se espera de qualquer
  `DROP` de tabela.
  """
  use Ecto.Migration

  def up do
    execute "DROP TABLE IF EXISTS appointments_versions"
    execute "DROP TABLE IF EXISTS attendances_versions"
  end

  def down do
    execute """
    CREATE TABLE IF NOT EXISTS appointments_versions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      version_action_type text NOT NULL,
      version_action_name text NOT NULL,
      starts_at timestamp(0) without time zone NOT NULL,
      status text NOT NULL DEFAULT 'agendado',
      clinic_id uuid NOT NULL,
      professional_id uuid NOT NULL,
      version_source_id uuid NOT NULL,
      changes jsonb,
      version_inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      version_updated_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      user_id uuid REFERENCES users(id) ON UPDATE CASCADE ON DELETE SET NULL
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS attendances_versions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      version_action_type text NOT NULL,
      version_action_name text NOT NULL,
      status text NOT NULL,
      clinic_id uuid NOT NULL,
      patient_id uuid NOT NULL,
      appointment_id uuid NOT NULL,
      version_source_id uuid NOT NULL,
      changes jsonb,
      version_inserted_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      version_updated_at timestamp without time zone NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
      user_id uuid REFERENCES users(id) ON UPDATE CASCADE ON DELETE SET NULL
    )
    """
  end
end
