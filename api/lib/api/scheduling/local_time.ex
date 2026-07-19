defmodule Api.Scheduling.LocalTime do
  @moduledoc """
  A ponte entre os dois vocabulários de tempo do sistema (doc 25 §4).

  `Api.Scheduling.Periods` fala **minuto do dia** (`"08:00"`), porque expediente é um conceito
  local e recorrente: "a clínica abre às 8" não depende de que dia é. `Appointment` fala
  **instante absoluto** (`:utc_datetime`, A2), porque a exclusion constraint compara
  `tstzrange` e porque um agendamento é um ponto na linha do tempo, não um horário de parede.
  Este módulo traduz nos dois sentidos, e é o único lugar do sistema que conhece
  `Clinic.timezone` (ADR-009).

  ## A política de DST, fixada de uma vez

  `DateTime.new/4` tem quatro retornos, e dois deles são as transições de horário de verão:

    * `{:gap, _antes, depois}` — a hora local **não existe** (o relógio pulou). Empurramos
      para `depois`: agendar "às 00:30" num dia em que 00:30 não existe vira o primeiro
      instante válido seguinte, em vez de erro. É o comportamento menos surpreendente para
      quem está ao telefone com o paciente.
    * `{:ambiguous, primeiro, _segundo}` — a hora local acontece **duas vezes** (o relógio
      voltou). Ficamos com `primeiro`, a ocorrência ainda no horário de verão.

  Fixar isso aqui, uma vez, é o que impede a regra de ser reinventada em cada chamador.

  ## Por que testar com `America/Santiago`

  O Brasil não tem horário de verão desde 2019, então com `America/Sao_Paulo` os dois ramos
  acima **nunca** são exercitados e o teste passa vazio. Mas `Clinic.timezone` é coluna livre,
  e a base `tz` guarda as transições históricas — a regra precisa de cobertura real
  (doc 25 §10).
  """

  alias Api.Scheduling.Periods

  @time ~r/^([01]\d|2[0-3]):([0-5]\d)$/

  @doc """
  Converte `date` + `"HH:MM"` no fuso `timezone` para um `DateTime` em **UTC**.

  Retornos: `{:ok, datetime_utc}` · `{:error, :invalid_time}` · `{:error, :invalid_timezone}`.
  """
  @spec to_utc(Date.t(), String.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, :invalid_time | :invalid_timezone}
  def to_utc(%Date{} = date, hhmm, timezone) when is_binary(hhmm) and is_binary(timezone) do
    with :ok <- validate_time(hhmm),
         {:ok, time} <- Time.new(hour(hhmm), minute(hhmm), 0) do
      date |> resolve(time, timezone) |> to_utc_result()
    end
  end

  defp resolve(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, dt} -> {:ok, dt}
      # Hora inexistente (salto): o primeiro instante válido depois do salto.
      {:gap, _antes, depois} -> {:ok, depois}
      # Hora repetida (volta): a primeira ocorrência.
      {:ambiguous, primeiro, _segundo} -> {:ok, primeiro}
      {:error, _} -> {:error, :invalid_timezone}
    end
  end

  defp to_utc_result({:ok, dt}), do: {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
  defp to_utc_result({:error, reason}), do: {:error, reason}

  defp validate_time(hhmm) do
    if Regex.match?(@time, hhmm), do: :ok, else: {:error, :invalid_time}
  end

  defp hour(<<h::binary-size(2), ":", _::binary>>), do: String.to_integer(h)
  defp minute(<<_::binary-size(3), m::binary-size(2)>>), do: String.to_integer(m)

  @doc """
  Minutos desde a meia-noite **local** de um instante UTC. É o que liga um `Appointment` de
  volta ao vocabulário do `Periods` — para checar se cabe no expediente, e para posicionar o
  bloco no grid.
  """
  @spec to_local_minutes(DateTime.t(), String.t()) :: non_neg_integer()
  def to_local_minutes(%DateTime{} = datetime, timezone) do
    local = DateTime.shift_zone!(datetime, timezone)
    local.hour * 60 + local.minute
  end

  @doc """
  A data **local** de um instante UTC. Não é `DateTime.to_date/1`: às 23:00 de São Paulo já é
  o dia seguinte em UTC, e a agenda do dia 20 não pode perder o agendamento das 23h.
  """
  @spec to_local_date(DateTime.t(), String.t()) :: Date.t()
  def to_local_date(%DateTime{} = datetime, timezone) do
    datetime |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
  end

  @doc """
  O intervalo `{início, fim}` em minutos locais que um agendamento ocupa. Açúcar para as
  validações, que precisam do par para perguntar `Availability.fits?/2`.
  """
  @spec to_local_range(DateTime.t(), DateTime.t(), String.t()) ::
          {non_neg_integer(), non_neg_integer()}
  def to_local_range(%DateTime{} = starts_at, %DateTime{} = ends_at, timezone) do
    ini = to_local_minutes(starts_at, timezone)
    # Duração em minutos somada ao início: fim 00:00 do dia seguinte precisa virar 1440, e
    # não 0, senão o intervalo fica invertido e nada "cabe".
    duracao = div(DateTime.diff(ends_at, starts_at, :second), 60)
    {ini, ini + duracao}
  end

  @doc "Formata minutos desde a meia-noite como `\"HH:MM\"` — o inverso de `Periods.to_minutes/1`."
  @spec from_minutes(non_neg_integer()) :: String.t()
  def from_minutes(minutes) when is_integer(minutes) and minutes >= 0 do
    h = minutes |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    m = minutes |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    h <> ":" <> m
  end

  @doc "Reexporta `Periods.to_minutes/1` para quem já depende deste módulo não importar os dois."
  @spec to_minutes(String.t()) :: non_neg_integer()
  defdelegate to_minutes(hhmm), to: Periods
end
