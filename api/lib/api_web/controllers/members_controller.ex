defmodule ApiWeb.MembersController do
  @moduledoc """
  Gestão de membros da clínica (Fatia 10 / tela Equipe & acessos). Espelha o padrão do
  `ApiWeb.AuthController`: lê o `Api.Scope` do request, chama os code interfaces do
  domínio com `scope:` e monta o JSON. O `clinic_id` vem **sempre** do escopo, nunca do
  corpo (09 §8). RBAC ADR-016 (defesa em profundidade sobre as policies do `Membership`):
  a **leitura** (GET) é liberada a qualquer membro ativo da clínica; a **gestão**
  (POST/PATCH/DELETE) exige owner/admin.
  """
  use ApiWeb, :controller

  alias Api.Accounts
  alias Api.Directory
  alias Api.Scope

  @papeis %{
    "owner" => :owner,
    "admin" => :admin,
    "profissional" => :profissional,
    "recepcao" => :recepcao
  }

  # GET /api/members — membros da clínica ativa + profissionais (para o vínculo e o card
  # "profissionais sem acesso"). Leitura para todos: qualquer membro da clínica vê a lista
  # (a gestão é que exige owner/admin). A policy do `Membership` é a autoridade.
  def index(conn, _params) do
    with_member_scope(conn, fn scope ->
      members = Accounts.list_clinic_members!(scope.clinic_id, scope: scope)
      # A leitura por-tenant (com o GUC de RLS) mora na camada de domínio, não aqui.
      professionals = Directory.list_clinic_professionals(scope)

      json(conn, %{
        members: Enum.map(members, &member_json/1),
        professionals: Enum.map(professionals, &professional_json/1)
      })
    end)
  end

  # POST /api/members {email, nome, papel, professional_id} — convida por e-mail.
  def create(conn, params) do
    with_admin_scope(conn, fn scope ->
      input = %{
        papel: parse_papel(params["papel"]),
        professional_id: blank_to_nil(params["professional_id"]),
        nome: params["nome"],
        clinic_id: scope.clinic_id
      }

      case Accounts.invite_member_by_email(params["email"], input, scope: scope, load: [:user]) do
        {:ok, membership} ->
          conn |> put_status(:created) |> json(%{member: member_json(membership)})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # PATCH /api/members/:id {papel, professional_id} — troca papel / vínculo.
  def update(conn, %{"id" => id} = params) do
    with_admin_scope(conn, fn scope ->
      with {:ok, %{} = membership} <- fetch(id, scope),
           {:ok, updated} <-
             Accounts.update_membership(membership, update_input(params), scope: scope, load: [:user]) do
        json(conn, %{member: member_json(updated)})
      else
        {:ok, nil} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # DELETE /api/members/:id — revoga o acesso.
  def delete(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      with {:ok, %{} = membership} <- fetch(id, scope),
           :ok <- revoke(membership, scope) do
        send_resp(conn, :no_content, "")
      else
        {:ok, nil} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # ---- helpers ----

  defp fetch(id, scope), do: Accounts.get_membership(id, scope: scope)

  defp revoke(membership, scope) do
    case Accounts.revoke_access(membership, scope: scope) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end
  end

  # Gestão (POST/PATCH/DELETE): exige owner/admin da clínica ativa.
  defp with_admin_scope(conn, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid, papel: papel} = scope
      when not is_nil(cid) and papel in [:owner, :admin] ->
        fun.(scope)

      %Scope{} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthenticated"})
    end
  end

  # Leitura (GET): qualquer membro de uma clínica ativa, independentemente do papel.
  defp with_member_scope(conn, fun) do
    case conn.assigns[:scope] do
      %Scope{clinic_id: cid} = scope when not is_nil(cid) ->
        fun.(scope)

      %Scope{} ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthenticated"})
    end
  end

  defp member_json(m) do
    %{
      id: m.id,
      nome: m.user.nome,
      email: to_string(m.user.email),
      papel: m.papel,
      status: m.status,
      professional_id: m.professional_id
    }
  end

  defp professional_json(p), do: %{id: p.id, nome: p.nome}

  defp update_input(params) do
    %{}
    |> put_if_present(params, "papel", :papel, &parse_papel/1)
    |> put_if_present(params, "professional_id", :professional_id, &blank_to_nil/1)
  end

  defp put_if_present(input, params, key, field, transform) do
    if Map.has_key?(params, key),
      do: Map.put(input, field, transform.(params[key])),
      else: input
  end

  # Whitelist (nunca String.to_atom em entrada do usuário). Papel inválido → nil, e a
  # validação da ação (`allow_nil? false`) devolve 422.
  defp parse_papel(value), do: Map.get(@papeis, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "not_found"})

  defp error_response(conn, %Ash.Error.Forbidden{}),
    do: conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

  defp error_response(conn, %Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
      not_found(conn)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "invalid", details: error_messages(error)})
    end
  end

  defp error_response(conn, _error),
    do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})

  defp error_messages(%{errors: errors}) when is_list(errors) do
    Enum.map(errors, fn err ->
      %{field: Map.get(err, :field), message: Exception.message(err)}
    end)
  end

  defp error_messages(_), do: []
end
