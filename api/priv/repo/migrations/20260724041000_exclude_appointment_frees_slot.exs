defmodule Api.Repo.Migrations.ExcludeAppointmentFreesSlot do
  @moduledoc """
  Estende o predicado parcial da `appointments_no_overlap` (soft-delete, doc 40).

  A constraint nasceu (em `20260719200000_agenda_constraint_and_rls`) com

      WHERE (encaixe = false AND status <> 'cancelado')

  Agora ganha `AND excluded_at IS NULL`: um bloco **excluído** (lançamento feito por engano) tem
  de liberar o horário para um novo agendamento — se continuasse dentro do índice de exclusão, o
  slot ficaria bloqueado para sempre por um registro que a UI já nem mostra. É o irmão de RN-13
  (cancelado libera o slot); a leitura filtrar `excluded_at IS NULL` **não basta**, porque a
  constraint é DB-level e roda mesmo sob a escrita que não passou pela leitura.

  ## Por que NÃO é `CONCURRENTLY` (regra `.claude/rules/migrations.md` §2)

  A regra manda `CREATE INDEX CONCURRENTLY` em tabela quente. Aqui **não se aplica**, por dois
  motivos que se somam:

    * uma **exclusion constraint** não tem forma `CONCURRENTLY` — `ALTER TABLE ... ADD CONSTRAINT
      ... EXCLUDE` toma `ACCESS EXCLUSIVE` e não existe `ADD CONSTRAINT ... USING INDEX` para
      EXCLUDE (só para UNIQUE/PK), nem `NOT VALID` (só CHECK/FK). O lock breve é inevitável no DDL;
    * `appointments` ainda é tabela nova (a fatia Agenda é v1, pré-lançamento) — o rebuild do gist
      é sub-segundo no volume atual. A regra também isenta tabela sem dado em produção.

  Fica o registro: quando a tabela tiver volume real, este swap é uma janela de `ACCESS EXCLUSIVE`
  no deploy (as migrations rodam no `release_command`). O caminho de menor lock, se um dia doer, é
  parar de escrever no horário durante a janela — não há CONCURRENTLY que salve um EXCLUDE.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE appointments DROP CONSTRAINT appointments_no_overlap"

    execute """
    ALTER TABLE appointments ADD CONSTRAINT appointments_no_overlap
      EXCLUDE USING gist (
        professional_id WITH =,
        tsrange(starts_at, ends_at, '[)') WITH &&
      )
      WHERE (encaixe = false AND status <> 'cancelado' AND excluded_at IS NULL)
    """
  end

  def down do
    execute "ALTER TABLE appointments DROP CONSTRAINT appointments_no_overlap"

    execute """
    ALTER TABLE appointments ADD CONSTRAINT appointments_no_overlap
      EXCLUDE USING gist (
        professional_id WITH =,
        tsrange(starts_at, ends_at, '[)') WITH &&
      )
      WHERE (encaixe = false AND status <> 'cancelado')
    """
  end
end
