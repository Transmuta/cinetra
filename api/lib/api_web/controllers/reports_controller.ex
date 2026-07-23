defmodule ApiWeb.ReportsController do
  @moduledoc """
  A tela de Relatórios (doc 33, Fatia 9). Um agregado de período — volume, status, taxa de
  falta e ocupação, quebrados por dia/tipo/profissional — para a recepção e a gestão.

  Leitura para todo membro (`with_member_scope`): o recorte do papel `profissional` ("só os
  próprios números", doc 33 §3) é de **dados**, não um 403 — vem da mesma preparation da agenda
  (`OwnAgendaOnly`), então não se reimplementa aqui. Sem faturamento na v1 (doc 33 §1 R4).

  Como a agenda, devolve os **profissionais e tipos inteiros** junto: a quebra vem por id e o
  nome/cor da barra é lookup no cliente (mesmo precedente de `AppointmentsController`).
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Scheduling

  # GET /api/reports/summary?date_from=YYYY-MM-DD&date_to=YYYY-MM-DD&professional_id=
  def summary(conn, params) do
    with_member_scope(conn, fn scope ->
      clinic = Scheduling.load_clinic(scope.clinic_id)

      case parse_window(params, "date_from", "date_to") do
        {:ok, from_date, to_date} ->
          professional_id = professional_id(params)

          report =
            Scheduling.load_summary(scope, from_date, to_date, professional_id, clinic.timezone)

          json(conn, render_summary(report, scope, clinic))

        {:error, message} ->
          invalid(conn, message)
      end
    end)
  end

  # `professional_id` vazio ("todos") vira `nil` — o escopo efetivo é resolvido no domínio
  # (doc 33 §3), inclusive o override do papel `profissional`.
  defp professional_id(%{"professional_id" => id}) when is_binary(id) and id != "", do: id
  defp professional_id(_), do: nil

  # A fronteira nomeia o wire (como `render_day_count` em `AppointmentsController`): o domínio
  # devolve mapas de negócio, aqui viram o contrato HTTP.
  defp render_summary(report, scope, clinic) do
    %{
      range: %{from: Date.to_iso8601(report.from), to: Date.to_iso8601(report.to)},
      totals: render_totals(report.totais),
      por_dia: Enum.map(report.por_dia, &render_dia/1),
      por_tipo: report.por_tipo,
      por_profissional: report.por_profissional,
      professionals: Enum.map(report.professionals, &ApiWeb.AgendaJSON.professional/1),
      appointment_types:
        Enum.map(report.appointment_types, &ApiWeb.AgendaJSON.appointment_type/1),
      agora: DateTime.to_iso8601(scope.now),
      timezone: clinic.timezone
    }
  end

  defp render_totals(totais) do
    %{totais | pico: render_pico(totais.pico)}
  end

  defp render_pico(nil), do: nil
  defp render_pico(%{date: date, total: total}), do: %{date: Date.to_iso8601(date), total: total}

  defp render_dia(%{date: date, total: total, concluidos: concluidos}),
    do: %{date: Date.to_iso8601(date), total: total, concluidos: concluidos}
end
