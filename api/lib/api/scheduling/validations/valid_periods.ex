defmodule Api.Scheduling.Validations.ValidPeriods do
  @moduledoc """
  Valida o atributo `periods` (default `:periods`) pelas regras puras de
  `Api.Scheduling.Periods` (forma `HH:MM`, ordem, não-sobreposição). Usada pelo `ClinicHours`;
  o `ScheduleException` usa `ExceptionPeriods`, que soma a consistência com o `tipo`.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    field = Keyword.get(opts, :attribute, :periods)

    case Ash.Changeset.get_attribute(changeset, field) do
      nil -> :ok
      periods -> check(field, periods)
    end
  end

  defp check(field, periods) do
    case Api.Scheduling.Periods.validate(periods) do
      :ok -> :ok
      {:error, message} -> {:error, field: field, message: message}
    end
  end
end
