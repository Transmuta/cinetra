defmodule Api.Scheduling.Validations.ProfessionalDayPeriods do
  @moduledoc """
  Amarra `periods` ao `modo` de um dia da grade do profissional (correção g, `01 §4.3`):

    * `:herda`   — usa o horário da clínica nesse dia; **não** carrega períodos próprios;
    * `:fechado` — o profissional não atende nesse dia; sem períodos;
    * `:custom`  — usa os próprios períodos, que precisam existir e ser bem-formados.

  A regra de que um período `:custom` tem de **caber dentro** do horário da clínica (invariante
  prof ⊆ clínica) NÃO mora aqui: depende do expediente da clínica naquele `dow`, que a
  validação de linha não tem à mão sem uma query extra. Ela é conferida na conferência prévia
  da semana em `Api.Scheduling.update_professional_hours/3`, junto do resto — mesmo desenho de
  `update_clinic_hours/2`.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    modo = Ash.Changeset.get_attribute(changeset, :modo)
    periods = Ash.Changeset.get_attribute(changeset, :periods) || []

    cond do
      modo in [:herda, :fechado] and periods != [] ->
        {:error, field: :periods, message: "modo #{modo} não carrega períodos próprios"}

      modo == :custom and periods == [] ->
        {:error, field: :periods, message: "informe ao menos um período para um horário próprio"}

      true ->
        case Api.Scheduling.Periods.validate(periods) do
          :ok -> :ok
          {:error, message} -> {:error, field: :periods, message: message}
        end
    end
  end
end
