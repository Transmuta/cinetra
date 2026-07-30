defmodule Api.Repo.Migrations.AgendaConstraintAndRls do
  @moduledoc """
  Duas coisas que o gerador do Ash não escreve, e que são o coração da fatia Agenda (doc 25):

  ## 1. `appointments_no_overlap` — a não-sobreposição (A5)

  Uma **exclusion constraint**, não uma validação. O cenário real são dois recepcionistas no
  mesmo slot ao mesmo tempo; pré-checagem em Elixir é conselho, só o banco resolve corrida
  (`04:7.1`). Três detalhes carregam regra de negócio:

    * `tsrange(starts_at, ends_at, '[)')` — intervalo **aberto no fim**: encostar
      fim-com-início não é conflito (08:00–08:50 e 08:50–09:40 convivem), fiel ao protótipo
      ([`:832`]);
    * `WHERE encaixe = false` — RN-12: encaixe não conflita **e não é conflitado**;
    * `AND status <> 'cancelado'` — RN-13: cancelar libera o horário.

  Sem `clinic_id` na constraint, por ADR-017: `professional_id` já é único globalmente, e um
  profissional não atende em duas clínicas no mesmo instante de qualquer forma.

  Exige `btree_gist` (igualdade em `professional_id` + `&&` de range no mesmo índice), que
  entra pela migration de extensões — `Api.Repo.installed_extensions/0`.

  ### Por que `tsrange` e não `tstzrange` (divergência de doc 25 §4)

  O doc especificou `tstzrange`, mas o `:utc_datetime` do Ash vira
  `timestamp(0) **without** time zone` no Postgres. `tstzrange(timestamp, timestamp, text)`
  precisaria de um cast implícito timestamp→timestamptz, que **depende do `TimeZone` da
  sessão** e portanto é `STABLE`, não `IMMUTABLE` — e índice não aceita expressão não-imutável
  (`ERROR 42P17`). `tsrange` sobre colunas que o Ash garante estarem sempre em UTC compara
  exatamente os mesmos instantes, e é imutável. A alternativa seria forçar `timestamptz` na
  coluna; não vale trocar o tipo de toda a agenda para reconquistar um cast que não usamos.

  ## 2. RLS, inclusive nas tabelas de versão

  Defesa-em-profundidade da tenancy por atributo (ADR-018), no molde de `SchedulingRls`. O que
  é novo aqui: **`appointments_versions` e `attendances_versions` também entram**. A trilha
  guarda o histórico inteiro da clínica; deixá-la fora da RLS seria abrir por fora do
  isolamento exatamente a tabela mais sensível (doc 25 §11.2). Isso só é possível porque
  `attributes_as_attributes` promoveu `clinic_id` a coluna real nas tabelas de versão — no
  mapa `changes` não haveria o que filtrar.

  **Nada disto aparece no `mix test`**: a suíte conecta como `postgres` (BYPASSRLS). A
  verificação é por `psql` com role NOBYPASSRLS, e faz parte do critério de pronto.
  """
  use Ecto.Migration

  @tables ~w(appointments attendances appointments_versions attendances_versions)

  def up do
    execute """
    ALTER TABLE appointments ADD CONSTRAINT appointments_no_overlap
      EXCLUDE USING gist (
        professional_id WITH =,
        tsrange(starts_at, ends_at, '[)') WITH &&
      )
      WHERE (encaixe = false AND status <> 'cancelado')
    """

    # Índices de apoio da trilha: toda query filtra `clinic_id` (RLS + Ash), e o histórico de
    # um registro é lido por `version_source_id`. `clinic_id` lidera (ADR-017).
    execute """
    CREATE INDEX appointments_versions_clinic_source_idx
      ON appointments_versions (clinic_id, version_source_id)
    """

    execute """
    CREATE INDEX appointments_versions_clinic_time_idx
      ON appointments_versions (clinic_id, version_inserted_at DESC)
    """

    execute """
    CREATE INDEX attendances_versions_clinic_source_idx
      ON attendances_versions (clinic_id, version_source_id)
    """

    execute """
    CREATE INDEX attendances_versions_clinic_time_idx
      ON attendances_versions (clinic_id, version_inserted_at DESC)
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

    execute "DROP INDEX IF EXISTS attendances_versions_clinic_time_idx"
    execute "DROP INDEX IF EXISTS attendances_versions_clinic_source_idx"
    execute "DROP INDEX IF EXISTS appointments_versions_clinic_time_idx"
    execute "DROP INDEX IF EXISTS appointments_versions_clinic_source_idx"

    execute "ALTER TABLE appointments DROP CONSTRAINT IF EXISTS appointments_no_overlap"
  end
end
