defmodule ApiWeb.PackagesController do
  @moduledoc """
  Os pacotes (Fatia 3, doc 09). Molde do `WaitlistController`: `with_member_scope` na fronteira (o
  RBAC fino é da policy do recurso), `whitelist/2` no corpo, `error_response/2` na escada
  401/403/404/422. `clinic_id` nunca vem do corpo — é do `Ash.Scope`.

  ## A prévia e o save-gate

  `POST /preview` classifica a série sem escrever (o `occIssue` do protótipo). `POST /` cria: roda
  a mesma prévia server-side e **decide** — se há ocorrência fora do expediente, ou conflito sem
  `forcar`, devolve **422 com a prévia** (código `series_blocked`) para a tela reapresentar; senão
  cria o pacote e enfileira a materialização.

  Pausar/retomar/cancelar operam sobre a série inteira; a retomada reprojeta as sessões seguradas
  para o futuro (GAP-06), re-materializando via job.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Packages
  alias ApiWeb.PackagesJSON

  # GET /api/patients/:patient_id/packages
  def index(conn, %{"patient_id" => patient_id}) do
    with_member_scope(conn, fn scope ->
      packages = Packages.list_patient_packages(scope, patient_id)
      json(conn, %{packages: Enum.map(packages, &PackagesJSON.package/1)})
    end)
  end

  # POST /api/packages/preview
  def preview(conn, params) do
    with_member_scope(conn, fn scope ->
      with {:ok, attrs} <- series_params(params),
           {:ok, previa} <- Packages.preview_series(scope, attrs) do
        json(conn, PackagesJSON.preview(previa))
      else
        :invalid -> bad_request(conn)
        {:error, motivo} -> series_error(conn, motivo)
      end
    end)
  end

  # POST /api/packages
  def create(conn, params) do
    with_member_scope(conn, fn scope ->
      forcar = params["forcar"] in [true, "true"]

      with {:ok, attrs} <- series_params(params),
           {:ok, pkg} <- Packages.create_series(scope, attrs, forcar: forcar) do
        pkg = Packages.get_patient_package!(scope, pkg.id, load: derivados())
        conn |> put_status(:created) |> json(%{package: PackagesJSON.package(pkg)})
      else
        :invalid ->
          bad_request(conn)

        {:error, {gate, previa}} when gate in [:fora_expediente, :precisa_confirmar] ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "series_blocked", reason: gate, preview: PackagesJSON.preview(previa)})

        {:error, motivo} ->
          series_error(conn, motivo)
      end
    end)
  end

  # POST /api/packages/:id/pause
  def pause(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.pause_package(scope, id))
    end)
  end

  # POST /api/packages/:id/resume
  def resume(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.resume_package(scope, id))
    end)
  end

  # POST /api/packages/:id/cancel
  def cancel(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      transition(conn, scope, Packages.cancel_package(scope, id))
    end)
  end

  defp transition(conn, scope, result) do
    case result do
      {:ok, pkg} ->
        pkg = Packages.get_patient_package!(scope, pkg.id, load: derivados())
        json(conn, %{package: PackagesJSON.package(pkg)})

      {:error, error} ->
        error_response(conn, error)
    end
  end

  # Extrai e valida os campos que criam a série. `data_inicio` chega como "AAAA-MM-DD"; a grade é
  # um mapa aninhado. Erro de forma vira `:invalid` (→ 400), sem estourar no domínio.
  defp series_params(params) do
    with %{"grade" => grade} when is_map(grade) <- params,
         {:ok, data_inicio} <- parse_date(params["data_inicio"]) do
      attrs =
        params
        |> whitelist([:nome, :total, :falta_punitiva, :cor, :patient_id, :appointment_type_id])
        |> Map.put(:data_inicio, data_inicio)
        |> Map.put(:grade, %{
          dows: grade["dows"],
          horarios: grade["horarios"],
          professional_id: grade["professional_id"]
        })

      {:ok, attrs}
    else
      _ -> :invalid
    end
  end

  defp bad_request(conn),
    do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_), do: :error

  # Os erros do motor de série (grade vazia, horário faltando) viram 422 com a razão.
  defp series_error(conn, motivo) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_series", reason: inspect(motivo)})
  end

  defp derivados, do: [:usadas, :restantes, :acabando, :schedule]
end
