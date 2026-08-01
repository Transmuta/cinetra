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

  import ApiWeb.TenantScope

  alias Api.Accounts
  alias Api.Directory

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
      # `%{id, nome}` é tudo o que `professional_json/1` emite — então é só isso que se lê. A
      # grade semanal e as 38 colunas da ficha eram carregadas e descartadas em toda abertura
      # desta tela, e agora também da Auditoria, que consome este endpoint para o filtro de autor.
      professionals = Directory.list_clinic_professionals(scope, query: [select: [:id, :nome]])

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
             Accounts.update_membership(membership, update_input(params),
               scope: scope,
               load: [:user]
             ) do
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

  # A checagem explícita de `clinic_id` é a **segunda camada** que `memberships` não tem no banco
  # (doc 96, S-5). Todas as 17 tabelas por-tenant têm RLS; esta não tem, e não pode ter uma policy
  # por `cinetra.clinic_id`: ela é lida CROSS-CLINIC por desenho — o `/me` lista todos os vínculos
  # do usuário, e o `LoadScope` resolve o vínculo ativo **antes** de existir tenant. Uma policy
  # por tenant aqui derrubaria o login.
  #
  # Sem esta linha a fronteira dependia só da expressão da policy do recurso — correta hoje, mas
  # uma camada, não duas, contra a norma do projeto (ADR-018). Efeito colateral observável que ela
  # também fecha: um `owner` de A que tentasse `PATCH` num id de B onde ele também é membro recebia
  # **403** (a leitura passava, a escrita recusava), enquanto um id inexistente dava **404** — o
  # par distinguia "existe numa clínica que você conhece" de "não existe".
  #
  # A ausência de RLS aqui é **exceção documentada**, não esquecimento. Ver `docs/00-decisoes.md`.
  defp fetch(id, %{clinic_id: clinic_id} = scope) do
    case Accounts.get_membership(id, scope: scope) do
      {:ok, %{clinic_id: ^clinic_id} = membership} -> {:ok, membership}
      # De outra clínica é indistinguível de inexistente: 404, nunca 403.
      {:ok, %{}} -> {:ok, nil}
      outro -> outro
    end
  end

  defp revoke(membership, scope) do
    case Accounts.revoke_access(membership, scope: scope) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end
  end

  # As guardas de escopo (`with_admin_scope`/`with_member_scope`) e a escada de erro
  # (`error_response`/`not_found`) vêm do `ApiWeb.TenantScope` compartilhado (doc 23) — antes
  # eram cópias privadas aqui. Ganho de brinde: a `error_response` do módulo tem o fallback
  # `:fields`, então um 422 de identity duplicada (convite repetido) para de sair com
  # `field: null`.

  defp member_json(m) do
    %{
      id: m.id,
      # O id do VÍNCULO (`id`) é o que edita/revoga; o do USUÁRIO é o que a trilha de auditoria
      # grava em `version.user_id`, e é por ele que a tela de Auditoria filtra "por autor".
      user_id: m.user_id,
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
end
