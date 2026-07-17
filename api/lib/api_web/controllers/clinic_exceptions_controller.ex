defmodule ApiWeb.ClinicExceptionsController do
  @moduledoc """
  Exceções de data **da clínica** (doc 22 §3) — feriados, dias fechados, expediente reduzido.
  Leitura para qualquer membro; escrita só owner/admin (H7). O `clinic_id` vem do escopo; o
  `professional_id` não entra no corpo nesta fatia (é sempre nulo — a rota é "da clínica").

  Excluir é `DELETE` de verdade (H4): a exceção é uma linha de data sem FK dependente. Um
  `confirm` no corpo do POST é aceito e ignorado até o motor de conflitos existir (H2) — o
  whitelist de campos já o descarta.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Scheduling

  @campos ~w(data nome tipo periods)a

  # GET /api/clinic-exceptions — só as da clínica (professional_id nulo), ordenadas por data.
  def index(conn, _params) do
    with_member_scope(conn, fn scope ->
      json(conn, %{
        clinic_exceptions: Enum.map(Scheduling.list_clinic_exceptions(scope), &exception_json/1)
      })
    end)
  end

  # POST /api/clinic-exceptions — cria uma exceção da clínica.
  def create(conn, params) do
    with_admin_scope(conn, fn scope ->
      case Scheduling.create_clinic_exception(scope, input(params)) do
        {:ok, exception} ->
          conn |> put_status(:created) |> json(%{clinic_exception: exception_json(exception)})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # DELETE /api/clinic-exceptions/:id — apaga (404 se não existe ou é de outra clínica).
  def delete(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      with {:ok, %{} = exception} <- Scheduling.fetch_clinic_exception(scope, id),
           :ok <- Scheduling.destroy_clinic_exception(scope, exception) do
        send_resp(conn, :no_content, "")
      else
        {:ok, nil} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # ---- helpers ----

  defp exception_json(e) do
    %{
      id: e.id,
      data: Date.to_iso8601(e.data),
      nome: e.nome,
      tipo: to_string(e.tipo),
      periods: e.periods
    }
  end

  # `clinic_id`, `professional_id`, `confirm` e qualquer outra chave são ignorados pela
  # whitelist. `tipo` chega string ("fechado"/"horario") e o enum do Ash converte.
  defp input(params), do: whitelist(params, @campos)
end
