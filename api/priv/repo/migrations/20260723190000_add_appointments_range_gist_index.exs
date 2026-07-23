defmodule Api.Repo.Migrations.AddAppointmentsRangeGistIndex do
  @moduledoc """
  D-A (doc 30). O `:in_range` lia por `(clinic_id, starts_at)` cobrindo só `starts_at < to`, e
  descartava o limite inferior (`ends_at > from`) num filtro — medido no seed de volume: **5.460
  linhas lidas para devolver 120** (5.340 removidas pelo filtro).

  Este índice **GiST não-parcial** sobre `(clinic_id, tsrange(starts_at, ends_at, '[)'))` deixa a
  sobreposição de range (`&&`, como o `:in_range` passou a expressar) ser resolvida pelo índice.
  Não-parcial de propósito: o read mostra também canceladas e encaixes, então não pode herdar o
  `WHERE encaixe = false AND status <> 'cancelado'` da `appointments_no_overlap`.

  `tsrange` e não `tstzrange` pela mesma razão da exclusion constraint (doc da migration
  `agenda_constraint_and_rls`): `:utc_datetime` do Ash é `timestamp(0) without time zone`, e
  `tstzrange` exigiria um cast STABLE que índice recusa (42P17). `btree_gist` (já instalada)
  permite `clinic_id WITH =` combinado com o range no mesmo GiST.

  Manual (não codegen) como a exclusion constraint: é DDL que o gerador do Ash não escreve.
  """
  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX appointments_clinic_range_gist
      ON appointments USING gist (clinic_id, tsrange(starts_at, ends_at, '[)'))
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS appointments_clinic_range_gist"
  end
end
