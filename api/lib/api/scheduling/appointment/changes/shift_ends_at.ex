defmodule Api.Scheduling.Appointment.Changes.ShiftEndsAt do
  @moduledoc """
  Recalcula `ends_at` ao **remarcar** (Entrega 4), preservando a duração original.

  Remarcar move o bloco no tempo (e, no arraste, de coluna) — não o redimensiona. O protótipo
  faz o mesmo: `saveRemarcar` [`:1133`] troca `date`/`start`/`profId` e nunca mexe em `dur`.
  Por isso a nova duração é `ends_at - starts_at` do registro **atual**, e não uma releitura de
  `AppointmentType.duracao_minutos` — que pode ter mudado desde a criação (o snapshot de A3 vale
  para sempre) ou ter sido sobreposta por um `duration_minutos` próprio (A-D8).

  Difere de `ComputeEndsAt` (que deriva a duração do tipo, no `:schedule`) exatamente nesse
  ponto: aqui a fonte é o par de instantes já gravado, não o catálogo.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &put_ends_at/1)
  end

  defp put_ends_at(changeset) do
    duracao_segundos = DateTime.diff(changeset.data.ends_at, changeset.data.starts_at, :second)

    case Ash.Changeset.get_attribute(changeset, :starts_at) do
      %DateTime{} = starts_at ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :ends_at,
          DateTime.add(starts_at, duracao_segundos, :second)
        )

      _ ->
        # Sem `starts_at`: a validação de presença já reprova o changeset.
        changeset
    end
  end
end
