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

  # PATCH /api/clinic/messaging — a tela /configuracoes/comunicacao (doc 52 §7). Só owner/admin.
  #
  # Ação e rota próprias, e não campos somados ao `update`: a fronteira aceita o que a AÇÃO
  # aceita, não o que o formulário desenha (09 §8). Somados, a tela de identidade da clínica
  # passaria a poder desligar o lembrete sem ter um controle para isso.
  def update_messaging(conn, params) do
    with_admin_scope(conn, fn scope ->
      with {:ok, %{} = clinic} <- Accounts.get_clinic(scope.clinic_id, scope: scope),
           {:ok, updated} <-
             Accounts.update_clinic_messaging(clinic, messaging_params(params), scope: scope) do
        json(conn, %{clinic: messaging_json(updated)})
      else
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # O booleano chega do form como string; os inteiros podem chegar em branco, e **branco é
  # `nil`** — que para `msg_lembrete_horas` significa DESLIGADO, não zero. Tratá-lo como 0 ligaria
  # o lembrete para o instante da sessão.
  defp messaging_params(params) do
    %{
      msg_confirmacao_auto: params["msg_confirmacao_auto"] in [true, "true", "on", "1"],
      msg_lembrete_horas: parse_int(params["msg_lembrete_horas"]),
      msg_silencio_inicio: parse_int(params["msg_silencio_inicio"]),
      msg_silencio_fim: parse_int(params["msg_silencio_fim"])
    }
  end

  # Os campos de comunicação viajam junto com a identidade: as duas telas de configuração leem
  # do mesmo `GET /api/clinic`, e uma segunda rota só para quatro escalares seria um round-trip a
  # mais por uma economia de bytes que não existe.
  defp clinic_json(c) do
    %{id: c.id, nome: c.nome, cnpj: c.cnpj, endereco: c.endereco}
    |> Map.merge(messaging_json(c))
  end

  defp messaging_json(c) do
    %{
      msg_confirmacao_auto: c.msg_confirmacao_auto,
      msg_lembrete_horas: c.msg_lembrete_horas,
      msg_silencio_inicio: c.msg_silencio_inicio,
      msg_silencio_fim: c.msg_silencio_fim
    }
  end
end
