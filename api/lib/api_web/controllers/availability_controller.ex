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
  #
  # `professional_id` aceita **vários** — separados por vírgula ou repetidos (`professional_id[]`).
  # Era um por requisição, e o BFF compensava com um fan-out de uma chamada por coluna do dia
  # (achado (f) do doc 26). A leitura da janela (e o teto de 31 dias) mora em
  # `TenantScope.parse_window/4`.
  def index(conn, params) do
    with_member_scope(conn, fn scope ->
      with {:ok, professional_ids} <- fetch_professionals(params),
           {:ok, from, to} <- parse_window(params, "date_from", "date_to") do
        render_availability(conn, scope, professional_ids, from, to)
      else
        {:error, :not_found} -> not_found(conn)
        {:error, message} -> invalid(conn, message)
      end
    end)
  end

  defp render_availability(conn, scope, professional_ids, from, to) do
    dates = Date.range(from, to) |> Enum.to_list()

    case Scheduling.load_availability_window(scope.clinic_id, professional_ids, from, to) do
      {:error, :professional_not_found} ->
        not_found(conn)

      {:ok, loaded} ->
        json(conn, %{professionals: Enum.map(loaded, &render_professional(&1, dates))})
    end
  end

  # A resposta é sempre `professionals: [...]`, inclusive para um profissional só — ver o teste
  # de contrato. As fontes já vêm carregadas para a janela inteira; aqui só se compõe cada dia.
  defp render_professional({professional, sources}, dates) do
    %{
      professional_id: professional.id,
      days: Enum.map(dates, &day(professional, sources, &1))
    }
  end

  defp day(professional, sources, date) do
    case Scheduling.Availability.day_periods(date, professional, sources) do
      {:open, periods} ->
        %{date: Date.to_iso8601(date), periods: periods}

      {:closed, reason} ->
        %{date: Date.to_iso8601(date), periods: [], closed_reason: reason}
    end
  end

  # Duas formas, porque as duas aparecem na prática: `?professional_id=a,b` (o que o BFF monta)
  # e `?professional_id[]=a&professional_id[]=b` (o que um cliente HTTP idiomático manda).
  defp fetch_professionals(params) do
    params
    |> Map.get("professional_id")
    |> List.wrap()
    |> Enum.flat_map(&String.split(to_string(&1), ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] -> {:error, "informe professional_id"}
      ids -> {:ok, ids}
    end
  end
end
