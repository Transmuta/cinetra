defmodule Api.Repo.Migrations.WaitlistConstraintAndRls do
  @moduledoc """
  O que o gerador do Ash não escreve, para a fila de espera (doc 25, Entrega 5):

  ## 1. `slot_holds_no_overlap` — a reserva de vaga sem corrida (doc 09 §6.2)

  Uma **exclusion constraint**, irmã de `appointments_no_overlap`: dois atendentes não seguram a
  mesma vaga do mesmo profissional. **Sem predicado de tempo** — `now()` é `STABLE`, não
  `IMMUTABLE`, e o Postgres recusa `WHERE expires_at > now()` num índice (`ERROR 42P17`). A
  constraint cobre **todos** os holds vivos; a expiração vive na DML (`PurgeExpired` apaga os
  vencidos do profissional antes de inserir, na mesma transação).

    * `tsrange(starts_at, ends_at, '[)')` — mesma razão de `appointments_no_overlap`: o
      `:utc_datetime` do Ash vira `timestamp(0) without time zone`, e `tstzrange` exigiria um
      cast `STABLE` que o índice recusa. O Ash garante UTC em toda escrita.
    * Sem `clinic_id` na constraint (ADR-017): `professional_id` já é único globalmente.

  Exige `btree_gist`, já instalado na Entrega 1 (`Api.Repo.installed_extensions/0`).

  ## 2. RLS nas três tabelas novas

  Defesa-em-profundidade da tenancy por atributo (ADR-018), no molde de `SchedulingRls` /
  `AgendaConstraintAndRls`. **Não há tabelas de versão** aqui: a fila não leva paper-trail
  (A-D14 — a trilha é só do agendamento).

  **Nada disto aparece no `mix test`** (sandbox `postgres`, BYPASSRLS). A verificação é por
  `psql` com role NOBYPASSRLS, e faz parte do critério de pronto.
  """
  use Ecto.Migration

  @tables ~w(waitlist_entries availability_rules slot_holds)

  def up do
    execute """
    ALTER TABLE slot_holds ADD CONSTRAINT slot_holds_no_overlap
      EXCLUDE USING gist (
        professional_id WITH =,
        tsrange(starts_at, ends_at, '[)') WITH &&
      )
    """

    for table <- @tables do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"

      execute """
      CREATE POLICY tenant_isolation ON #{table}
        USING (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
        WITH CHECK (clinic_id = current_setting('cinetra.clinic_id', true)::uuid)
      """
    end
  end

  def down do
    for table <- @tables do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end

    execute "ALTER TABLE slot_holds DROP CONSTRAINT IF EXISTS slot_holds_no_overlap"
  end
end
