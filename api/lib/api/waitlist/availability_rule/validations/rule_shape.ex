defmodule Api.Waitlist.AvailabilityRule.Validations.RuleShape do
  @moduledoc """
  Amarra a forma de uma regra de disponibilidade ao seu `tipo` (doc 25 §1, `01 §4.5`):

    * `:semana` exige ao menos um dia-da-semana (`dows`) e **não** carrega `data`;
    * `:data` exige uma `data` e **não** carrega `dows`;
    * ambos exigem ao menos uma faixa de horário (`periodos`), com a forma validada por
      `Api.Scheduling.Periods` (reuso — a mesma autoridade do expediente).

  Uma única validação porque é um único invariante ("a regra é coerente com seu tipo"), no
  molde de `Api.Scheduling.Validations.ExceptionPeriods`.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    tipo = Ash.Changeset.get_attribute(changeset, :tipo)
    dows = Ash.Changeset.get_attribute(changeset, :dows) || []
    data = Ash.Changeset.get_attribute(changeset, :data)
    periodos = Ash.Changeset.get_attribute(changeset, :periodos) || []

    with :ok <- validate_tipo(tipo, dows, data),
         :ok <- validate_periodos(periodos) do
      :ok
    end
  end

  defp validate_tipo(:semana, [], _data),
    do: {:error, field: :dows, message: "informe ao menos um dia da semana"}

  defp validate_tipo(:semana, _dows, _data), do: :ok

  defp validate_tipo(:data, _dows, nil),
    do: {:error, field: :data, message: "informe a data"}

  defp validate_tipo(:data, _dows, _data), do: :ok

  defp validate_tipo(_tipo, _dows, _data), do: :ok

  defp validate_periodos([]),
    do: {:error, field: :periodos, message: "informe ao menos uma faixa de horário"}

  defp validate_periodos(periodos) do
    case Api.Scheduling.Periods.validate(periodos) do
      :ok -> :ok
      {:error, message} -> {:error, field: :periodos, message: message}
    end
  end
end
