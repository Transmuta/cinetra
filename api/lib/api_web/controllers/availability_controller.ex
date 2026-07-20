defmodule ApiWeb.AvailabilityController do
  @moduledoc """
  Disponibilidade de um profissional num intervalo de datas (doc 25 §5).

  É **cálculo**, não coleção (`09:253`): não existe recurso "availability" no banco, é a
  composição das 4 camadas feita por `Api.Scheduling.Availability`. Por isso não tem
  `POST`/`PATCH` e não devolve `id`.

  Serve à tela para: desenhar a faixa vertical do grid a partir do expediente real (A12, em
  vez do 08–18 fixo do protótipo) e hachurar o buraco real entre períodos por coluna.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Scheduling

  # GET /api/availability?professional_id=&date_from=&date_to=
  # A leitura da janela (e o teto de 31 dias) mora em `TenantScope.parse_window/4`.
  def index(conn, params) do
    with_member_scope(conn, fn scope ->
      with {:ok, professional_id} <- fetch_professional(params),
           {:ok, from, to} <- parse_window(params, "date_from", "date_to") do
        render_days(conn, scope, professional_id, from, to)
      else
        {:error, :not_found} -> not_found(conn)
        {:error, message} -> invalid(conn, message)
      end
    end)
  end

  defp render_days(conn, scope, professional_id, from, to) do
    dates = Date.range(from, to) |> Enum.to_list()

    case Scheduling.load_availability_sources(scope.clinic_id, professional_id, List.first(dates)) do
      {:error, :professional_not_found} ->
        not_found(conn)

      {:ok, professional, _} ->
        json(conn, %{days: Enum.map(dates, &day(scope, professional, professional_id, &1))})
    end
  end

  defp day(scope, professional, professional_id, date) do
    # As exceções são por data, então recarregamos por dia. É O(dias) consultas — aceitável
    # com o teto de 31 e muito mais simples do que indexar tudo em memória; se virar gargalo,
    # o lugar de resolver é uma leitura só com `data in ^datas`.
    {:ok, _, sources} =
      Scheduling.load_availability_sources(scope.clinic_id, professional_id, date)

    case Scheduling.Availability.day_periods(date, professional, sources) do
      {:open, periods} ->
        %{date: Date.to_iso8601(date), periods: periods}

      {:closed, reason} ->
        %{date: Date.to_iso8601(date), periods: [], closed_reason: reason}
    end
  end

  defp fetch_professional(%{"professional_id" => id}) when is_binary(id) and id != "",
    do: {:ok, id}

  defp fetch_professional(_), do: {:error, "informe professional_id"}
end
