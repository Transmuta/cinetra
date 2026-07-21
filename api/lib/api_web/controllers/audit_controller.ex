defmodule ApiWeb.AuditController do
  @moduledoc """
  A trilha de auditoria da clínica ativa (doc 25 §11.4) — o backend da tela
  `/configuracoes/auditoria`. Um `GET` só, paginado, com os filtros do §11.4.

  RBAC **owner·admin**: ao contrário das outras leituras de gestão (que são de todo membro), a
  trilha guarda o histórico inteiro da clínica e é o pedido literal — "tela de auditoria pro
  admin". A guarda `with_admin_scope` recusa recepção/profissional com **403** (não uma lista
  vazia, que leria como "sem atividade"). É defesa-em-profundidade: as policies do recurso de
  versão (`TrailMixin`) já filtram para owner·admin de qualquer forma.

  `clinic_id` sempre do escopo (09 §8); a janela `from`/`to` é local à clínica (mesmo fuso da
  agenda, `LocalTime.window!`).
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Scheduling
  alias Api.Scheduling.LocalTime

  # As ações que geram versão — `Appointment` e `Attendance`. Whitelist antes do
  # `to_existing_atom` (nunca converter string crua de query em átomo), no molde do
  # `parse_status` de `PatientsController`.
  @audit_actions ~w(schedule add_participant reschedule mark_completed mark_missed cancel
                    reopen set_falta_justificada create transition)

  # GET /api/audit?resource=&record_id=&user_id=&action=&from=&to=&limit=&offset=
  def index(conn, params) do
    with_admin_scope(conn, fn scope ->
      case build_opts(scope, params) do
        {:ok, opts} ->
          result = Scheduling.list_audit_log(scope, opts)
          json(conn, %{entries: Enum.map(result.entries, &entry_json/1), page: result.page})

        {:error, message} ->
          invalid(conn, message)
      end
    end)
  end

  # ---- parsing ----

  defp build_opts(scope, params) do
    with {:ok, record_id} <- parse_uuid(params["record_id"], "record_id"),
         {:ok, user_id} <- parse_uuid(params["user_id"], "user_id"),
         {:ok, from_dt, to_dt} <- audit_window(scope, params) do
      {:ok,
       [
         resource: parse_resource(params["resource"]),
         record_id: record_id,
         user_id: user_id,
         action_name: parse_action(params["action"]),
         from: from_dt,
         to: to_dt,
         limit: parse_int(params["limit"]),
         offset: parse_int(params["offset"])
       ]}
    end
  end

  # `record_id`/`user_id` são filtros sobre colunas UUID. Sem validar, um valor não-uuid chega
  # cru em `Ash.Query.filter(coluna == ^valor)` e o `Ecto.Query.CastError` sobe até virar **500**
  # (bate-volta, segurança). Validar aqui devolve 422 — o mesmo contrato de `from`/`to`. Ausente/
  # vazio é filtro nulo (não é erro).
  defp parse_uuid(nil, _label), do: {:ok, nil}
  defp parse_uuid("", _label), do: {:ok, nil}

  defp parse_uuid(value, label) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> {:ok, value}
      :error -> {:error, "#{label} inválido"}
    end
  end

  # A janela é OPCIONAL (o feed default é offset-paginado, sem recorte de data — o índice
  # `(clinic_id, version_inserted_at DESC)` já limita o que se lê). Quando vem, é local à
  # clínica e limitada a 31 dias, reusando `parse_window` (a mesma regra da agenda).
  defp audit_window(scope, params) do
    if is_nil(params["from"]) and is_nil(params["to"]) do
      {:ok, nil, nil}
    else
      with {:ok, from_date, to_date} <- parse_window(params, "from", "to") do
        tz = Scheduling.load_clinic(scope.clinic_id).timezone
        {from_dt, to_dt} = LocalTime.window!(from_date, to_date, tz)
        {:ok, from_dt, to_dt}
      end
    end
  end

  defp parse_resource("attendance"), do: :attendance
  defp parse_resource(_), do: :appointment

  defp parse_action(action) when action in @audit_actions, do: String.to_existing_atom(action)
  defp parse_action(_), do: nil

  # Valor inválido (ou negativo) vira `nil` e o DOMÍNIO aplica o default/teto (a lista nunca
  # quebra por um `?limit=abc` nem por `?offset=-5`) — mesmo contrato de `PatientsController`.
  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  # ---- serialização ----

  # Átomos (`action`, `status`) o Jason emite como string; DateTime vai em ISO-8601 explícito
  # (o resto do projeto faz assim — `appointments_controller`). Campos de contexto que não se
  # aplicam ao recurso vêm `null` (professional no attendance, patient no appointment).
  defp entry_json(e) do
    %{
      id: e.id,
      resource: e.resource,
      record_id: e.record_id,
      action: e.action,
      action_type: e.action_type,
      at: iso(e.at),
      status: e.status,
      actor: e.actor,
      starts_at: iso(e.starts_at),
      professional: e.professional,
      patient: e.patient,
      appointment_id: e.appointment_id,
      diff: e.diff
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
