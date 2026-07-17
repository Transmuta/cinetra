defmodule ApiWeb.ClinicController do
  @moduledoc """
  A clínica ativa como recurso HTTP. Duas superfícies:

    * `onboard` — o primeiro acesso: cria a clínica e torna o usuário atual `owner`, na mesma
      transação (ADR-016). É a única porta que faz nascer um tenant; qualquer autenticado pode
      (política `actor_present()`). O `onboard` é um create que NÃO exige tenant — o escopo sem
      `clinic_id` é o esperado aqui.
    * `show`/`update` — dados de identidade da clínica ativa (nome, CNPJ, endereço; tela
      /configuracoes/clinica). Leitura para todo membro, edição só owner/admin (RBAC ADR-016,
      via `ApiWeb.TenantScope`).

  O ator vem sempre do escopo da sessão e o `clinic_id` também (nunca do corpo/URL, 09 §8).
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Accounts
  alias Api.Scope

  # POST /api/clinics {nome} — cria a clínica + o Membership `owner` do usuário atual.
  def onboard(conn, params) do
    case conn.assigns[:scope] do
      %Scope{user: %{}} = scope ->
        case Accounts.onboard_clinic(params["nome"], %{}, scope: scope) do
          {:ok, clinic} ->
            conn |> put_status(:created) |> json(%{clinic: %{id: clinic.id, nome: clinic.nome}})

          {:error, error} ->
            error_response(conn, error)
        end

      _ ->
        unauthorized(conn)
    end
  end

  # GET /api/clinic — nome, CNPJ e endereço da clínica ativa. Leitura para todo membro.
  def show(conn, _params) do
    with_member_scope(conn, fn scope ->
      case Accounts.get_clinic(scope.clinic_id, scope: scope) do
        {:ok, %{} = clinic} -> json(conn, %{clinic: clinic_json(clinic)})
        {:ok, nil} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # PATCH /api/clinic {nome, cnpj, endereco} — edita a identidade da clínica. Só owner/admin.
  # O CNPJ pode chegar mascarado; o domínio normaliza e valida (alfanumérico). Campo ausente do
  # corpo não é tocado; branco limpa. `clinic_id`/qualquer outra chave são ignorados (whitelist).
  def update(conn, params) do
    with_admin_scope(conn, fn scope ->
      with {:ok, %{} = clinic} <- Accounts.get_clinic(scope.clinic_id, scope: scope),
           {:ok, updated} <-
             Accounts.update_clinic_info(clinic, whitelist(params, [:nome, :cnpj, :endereco]),
               scope: scope
             ) do
        json(conn, %{clinic: clinic_json(updated)})
      else
        {:ok, nil} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  defp clinic_json(c), do: %{id: c.id, nome: c.nome, cnpj: c.cnpj, endereco: c.endereco}
end
