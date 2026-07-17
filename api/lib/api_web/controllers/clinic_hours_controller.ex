defmodule ApiWeb.ClinicHoursController do
  @moduledoc """
  Horário semanal da clínica (doc 22 §3). Leitura para qualquer membro; escrita só owner/admin
  (RBAC ADR-016 / H7, defesa em profundidade sobre as policies do `ClinicHours`). O `clinic_id`
  vem sempre do escopo, nunca do corpo (09 §8).

  `PATCH` recebe a semana num mapa `{"clinic_hours": {dow: periods}}` e substitui só os dias
  presentes. Um `confirm` no corpo é aceito e ignorado até o motor de conflitos com a agenda
  existir (doc 22 §6/H2) — o whitelist de `clinic_hours` já descarta qualquer outra chave.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Scheduling

  # GET /api/clinic-hours — as 7 linhas, como mapa `{dow => periods}`.
  def index(conn, _params) do
    with_member_scope(conn, fn scope ->
      json(conn, %{clinic_hours: hours_map(Scheduling.list_clinic_hours(scope))})
    end)
  end

  # PATCH /api/clinic-hours — substitui os dias enviados; valida a semana antes de aplicar.
  def update(conn, params) do
    with_admin_scope(conn, fn scope ->
      case Scheduling.update_clinic_hours(scope, week_input(params)) do
        {:ok, rows} ->
          json(conn, %{clinic_hours: hours_map(rows)})

        {:error, {:invalid, details}} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid", details: details})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # ---- helpers ----

  defp hours_map(rows), do: Map.new(rows, &{Integer.to_string(&1.dow), &1.periods})

  # `{"clinic_hours": {"0": [...], "1": [...]}}` → `%{0 => [...], 1 => [...]}`. Chaves fora de
  # 0..6 (ou não-numéricas) são descartadas — a fronteira HTTP não confia no cliente (09 §8).
  # Os períodos em si são validados no domínio (`Api.Scheduling.Periods`).
  defp week_input(%{"clinic_hours" => week}) when is_map(week) do
    Map.new(dows(week))
  end

  defp week_input(_), do: %{}

  defp dows(week) do
    Enum.flat_map(week, fn {key, periods} ->
      case Integer.parse(to_string(key)) do
        {dow, ""} when dow in 0..6 -> [{dow, periods}]
        _ -> []
      end
    end)
  end
end
