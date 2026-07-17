defmodule Api.Scheduling.Validations.ExceptionPeriods do
  @moduledoc """
  Amarra `periods` ao `tipo` da exceção (doc 22 §1, `01:758`):

    * `:horario` exige ao menos um período (senão não há o que atender no dia);
    * `:fechado` não carrega período nenhum (o dia inteiro fecha);

  e, quando há períodos, valida a forma por `Api.Scheduling.Periods`. Uma única validação
  porque é um único invariante ("os períodos batem com o tipo").
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    tipo = Ash.Changeset.get_attribute(changeset, :tipo)
    periods = Ash.Changeset.get_attribute(changeset, :periods) || []

    cond do
      tipo == :horario and periods == [] ->
        {:error, field: :periods, message: "informe ao menos um período para um horário especial"}

      tipo == :fechado and periods != [] ->
        {:error, field: :periods, message: "um dia fechado não tem períodos"}

      true ->
        case Api.Scheduling.Periods.validate(periods) do
          :ok -> :ok
          {:error, message} -> {:error, field: :periods, message: message}
        end
    end
  end
end
