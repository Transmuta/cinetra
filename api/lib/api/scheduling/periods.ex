defmodule Api.Scheduling.Periods do
  @moduledoc """
  Regras **puras** dos períodos de atendimento (doc 22 §1). Um período é um par
  `["HH:MM", "HH:MM"]` (início, fim); um dia é uma lista de períodos; `[]` = fechado.

  Valida forma (`HH:MM` 24h), ordem (início antes do fim) e não-sobreposição/ordenação entre
  períodos do mesmo dia — sem tocar no banco. É a autoridade do servidor sobre o que o
  protótipo só marcava visualmente: a fronteira HTTP não confia no cliente (09 §8). Usada pela
  validação Ash dos recursos e pela conferência prévia da semana em
  `Api.Scheduling.update_clinic_hours/2`.
  """

  @time ~r/^([01]\d|2[0-3]):([0-5]\d)$/

  @doc """
  Valida os períodos de um dia. `:ok`, ou `{:error, mensagem}` na primeira falha. Lista vazia
  (dia fechado) é válida.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(periods) when is_list(periods) do
    with :ok <- validate_each(periods) do
      validate_ordered_disjoint(periods)
    end
  end

  def validate(_), do: {:error, "períodos devem ser uma lista"}

  defp validate_each(periods) do
    Enum.reduce_while(periods, :ok, fn period, :ok ->
      case validate_period(period) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_period([ini, fim]) when is_binary(ini) and is_binary(fim) do
    cond do
      not Regex.match?(@time, ini) ->
        {:error, "horário inválido: #{ini}"}

      not Regex.match?(@time, fim) ->
        {:error, "horário inválido: #{fim}"}

      to_minutes(ini) >= to_minutes(fim) ->
        {:error, "início deve vir antes do fim (#{ini}–#{fim})"}

      true ->
        :ok
    end
  end

  defp validate_period(_), do: {:error, "cada período deve ser um par [início, fim]"}

  # Ordenados por início e sem sobreposição: o fim de um período <= o início do próximo.
  defp validate_ordered_disjoint(periods) do
    periods
    |> Enum.map(fn [ini, fim] -> {to_minutes(ini), to_minutes(fim)} end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce_while(:ok, fn [{_, fim_anterior}, {ini_proximo, _}], :ok ->
      if fim_anterior <= ini_proximo,
        do: {:cont, :ok},
        else: {:halt, {:error, "períodos se sobrepõem ou estão fora de ordem"}}
    end)
  end

  @doc """
  Invariante prof ⊆ clínica (doc 22 §5): todos os `periods` cabem dentro de **algum** período
  do expediente da clínica naquele dia (`dayValid` do protótipo,
  [`:2978`](../../../interface/Movimento.dc.html#L2978)). Se a clínica está fechada no dia
  (`clinic_periods == []`), qualquer período próprio é inválido — não se atende quando a
  clínica não abre. Assume `periods`/`clinic_periods` já validados na forma.

  `:ok`, ou `{:error, mensagem}` na primeira falha.
  """
  @spec within(list(), list()) :: :ok | {:error, String.t()}
  def within(periods, clinic_periods) when is_list(periods) and is_list(clinic_periods) do
    Enum.reduce_while(periods, :ok, fn [ini, fim], :ok ->
      if fits_in_any?(to_minutes(ini), to_minutes(fim), clinic_periods) do
        {:cont, :ok}
      else
        {:halt, {:error, "período #{ini}–#{fim} fora do horário da clínica nesse dia"}}
      end
    end)
  end

  defp fits_in_any?(ini, fim, clinic_periods) do
    Enum.any?(clinic_periods, fn [cini, cfim] ->
      to_minutes(cini) <= ini and fim <= to_minutes(cfim)
    end)
  end

  @doc "Converte `\"HH:MM\"` em minutos desde a meia-noite. Só para strings já validadas."
  @spec to_minutes(String.t()) :: non_neg_integer()
  def to_minutes(<<h::binary-size(2), ":", m::binary-size(2)>>),
    do: String.to_integer(h) * 60 + String.to_integer(m)
end
