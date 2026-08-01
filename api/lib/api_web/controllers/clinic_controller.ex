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

  # Os campos de identidade, numa lista só: é ela que a whitelist do PATCH usa E que o JSON do GET
  # devolve. Duas listas iguais divergiriam no primeiro campo novo, e a divergência tem uma cara
  # específica e chata de achar — o formulário grava um campo que a leitura seguinte não traz, e a
  # tela "perde" o valor ao recarregar.
  @campos_de_info [
    :nome,
    :cnpj,
    :telefone,
    :cep,
    :endereco,
    :numero,
    :complemento,
    :bairro,
    :cidade,
    :uf
  ]

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
             Accounts.update_clinic_info(clinic, whitelist(params, @campos_de_info), scope: scope) do
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

  # Os inteiros da janela de silêncio podem chegar em branco, e **branco é `nil`** — as duas
  # pontas nulas significam "sem janela".
  defp messaging_params(params) do
    %{
      # Booleano vem do form como string. `parse_bool/1` trata ausente como `false` de propósito:
      # o formulário manda um hidden sempre (`SwitchToggle` é `<button>` e não entra no FormData),
      # e a alternativa — ausente significa "não mexe" — faria o interruptor ser impossível de
      # DESLIGAR pela tela. É exatamente o bug que o doc 98 §6 pegou ao vivo na janela de
      # silêncio, e ele não vai acontecer duas vezes.
      msg_whatsapp_ativo: parse_bool(params["msg_whatsapp_ativo"]),
      msg_silencio_inicio: parse_int(params["msg_silencio_inicio"]),
      msg_silencio_fim: parse_int(params["msg_silencio_fim"])
    }
  end

  defp parse_bool(valor) when valor in [true, "true", "on", "1"], do: true
  defp parse_bool(_valor), do: false

  # Os campos de comunicação viajam junto com a identidade: as duas telas de configuração leem
  # do mesmo `GET /api/clinic`, e uma segunda rota só para três escalares seria um round-trip a
  # mais por uma economia de bytes que não existe.
  defp clinic_json(c) do
    @campos_de_info
    |> Map.new(fn campo -> {campo, Map.fetch!(c, campo)} end)
    |> Map.put(:id, c.id)
    |> Map.merge(messaging_json(c))
  end

  defp messaging_json(c) do
    %{
      msg_whatsapp_ativo: c.msg_whatsapp_ativo,
      msg_silencio_inicio: c.msg_silencio_inicio,
      msg_silencio_fim: c.msg_silencio_fim
    }
  end
end
