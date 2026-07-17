defmodule ApiWeb.TenantScope do
  @moduledoc """
  Guardas de escopo e escada de erros compartilhadas pelos controllers de gestão da clínica
  (Horário, Exceções — e o que vier). Extrai o que `MembersController`/`AppointmentTypesController`
  faziam em cópias privadas: resolver o `Api.Scope` da sessão, aplicar o RBAC (leitura para
  todo membro, escrita só owner/admin) e traduzir os erros do Ash na escada 401/403/404/422.

  O `clinic_id` vem **sempre** do escopo, nunca do corpo (09 §8).
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Api.Scope

  @doc "Escrita: exige owner/admin de uma clínica ativa. Senão 403 (membro) / 401 (sem sessão)."
  def with_admin_scope(conn, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid, papel: papel} = scope
      when not is_nil(cid) and papel in [:owner, :admin] ->
        fun.(scope)

      %Scope{} ->
        forbidden(conn)

      _ ->
        unauthorized(conn)
    end
  end

  @doc "Leitura: qualquer membro de uma clínica ativa, independentemente do papel."
  def with_member_scope(conn, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid} = scope when not is_nil(cid) ->
        fun.(scope)

      %Scope{} ->
        forbidden(conn)

      _ ->
        unauthorized(conn)
    end
  end

  @doc "Traduz um erro do Ash na resposta HTTP (403 · 404 · 422 · 400)."
  def error_response(conn, %Ash.Error.Forbidden{}), do: forbidden(conn)

  def error_response(conn, %Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
      not_found(conn)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "invalid", details: error_messages(error)})
    end
  end

  def error_response(conn, _error),
    do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  def not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  @doc "401 padrão da fronteira (sem sessão). Fonte única do corpo, reusada fora das guardas."
  def unauthorized(conn),
    do: conn |> put_status(:unauthorized) |> json(%{error: "unauthenticated"})

  @doc """
  Recorta `params` (chaves string, do corpo) aos `fields` permitidos, devolvendo um mapa de
  chaves atom. É a whitelist no espírito do `@papeis` do MembersController: `clinic_id` e
  qualquer chave fora da lista são simplesmente ignorados — o tenant vem do escopo (09 §8).

  O teste é `Map.has_key?`, não truthiness: `capacidade: null` é instrução legítima de limpar,
  e campo ausente do corpo simplesmente não é tocado (update parcial).
  """
  def whitelist(params, fields) when is_map(params) and is_list(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      key = Atom.to_string(field)
      if Map.has_key?(params, key), do: Map.put(acc, field, params[key]), else: acc
    end)
  end

  defp forbidden(conn), do: conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

  defp error_messages(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn err ->
      %{field: error_field(err), message: Exception.message(err)}
    end)
  end

  defp error_messages(_), do: []

  # O Ash reporta o campo em `:field` (`InvalidAttribute`) OU em `:fields` (`InvalidChanges` —
  # é o caso da identity duplicada). Sem este fallback o 422 chegaria com `field: null` e o
  # form não saberia qual input marcar.
  defp error_field(err) do
    case Map.get(err, :field) do
      nil -> err |> Map.get(:fields) |> List.wrap() |> List.first()
      field -> field
    end
  end
end
