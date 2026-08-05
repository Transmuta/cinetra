defmodule ApiWeb.AuthController do
  @moduledoc """
  Endpoints de autenticação e sessão (ADR-015, contrato 09 §8). Sem senha: magic link
  e Google (o hand-off OAuth em si é feito pelo `ApiWeb.AuthStrategyController`, via
  Assent). Aqui ficam o pedido de magic link, o callback que assina a sessão, o
  `/me`, a troca de tenant e o sign-out.
  """
  use ApiWeb, :controller

  # Tradução do erro do Ash em resposta HTTP (403/404/422). Fonte única compartilhada com os
  # controllers de tenant, mesmo que estes endpoints de identidade sejam globais (sem clínica).
  import ApiWeb.TenantScope, only: [error_response: 2, unauthorized: 1, invalid: 2]

  alias Api.Accounts
  alias Api.Accounts.Membership
  alias Api.Scope
  alias AshAuthentication.Plug.Helpers

  # POST /api/auth/magic-link {email} — dispara o e-mail. Resposta NEUTRA (não revela se
  # o e-mail existe), ADR-015 / 09 §8.
  def request_magic_link(conn, params) do
    email = params["email"] || get_in(params, ["user", "email"])
    # Nome opcional (só no cadastro por magic link); viaja assinado no token.
    nome = params["nome"] || get_in(params, ["user", "nome"])
    # Só o formulário de CADASTRO (/criar-conta) manda register:true; o de login não. Assim
    # um e-mail sem conta no login não gera link nem conta (a resposta segue neutra).
    register? = params["register"] == true

    if is_binary(email) and email != "" do
      # Best-effort: erros (e-mail inválido etc.) não vazam existência de conta.
      _ = Accounts.request_magic_link(email, %{nome: nome, register?: register?})
    end

    json(conn, %{ok: true})
  end

  # GET /api/auth/magic-link/callback?token=… — valida o token, cria/vincula o User e
  # assina a sessão. Redireciona ao app web.
  def magic_link_callback(conn, %{"token" => token}) do
    case Accounts.sign_in_with_magic_link(token) do
      {:ok, user} ->
        # Primeiro acesso do convidado ativa seus vínculos pendentes (D24).
        _ = Api.Accounts.Invites.activate_pending(user)

        conn
        |> Helpers.store_in_session(user)
        |> redirect(external: Api.web_app_url())

      # **401 de verdade, sem `Location`** (doc 96, H-10). Isto era
      # `put_status(:unauthorized) |> redirect(external: …)`, e `Phoenix.Controller.redirect/2`
      # faz `send_resp(conn.status || 302, …)` — saía **401 com header `Location`**, um redirect
      # que browser nenhum segue. Funcionava porque quem lê esta resposta é o BFF, com
      # `redirect: 'manual'`, e ele olha só o `set-cookie` (`reemitSession/2`); o destino do
      # "redirect" nunca foi usado por ninguém.
      #
      # Quem decide para onde o usuário vai depois de um link inválido é o BFF, que já faz
      # `redirect(303, '/entrar?erro=link')` — e é o lugar certo, porque a rota de destino é dele.
      {:error, _reason} ->
        unauthorized(conn)
    end
  end

  def magic_link_callback(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "missing_token"})
  end

  # GET /api/auth/google — entrada limpa que leva ao fluxo OAuth (Assent) montado sob
  # /api/auth/strategy pelo AuthStrategyController.
  def google(conn, _params) do
    redirect(conn, to: "/api/auth/strategy/user/google")
  end

  # GET /api/auth/me — identidade global + memberships + tenant ativo (ADR-014, 09 §8).
  def me(conn, _params) do
    case conn.assigns[:scope] do
      %Scope{user: user} = scope ->
        memberships = Accounts.list_active_memberships!(user.id, authorize?: false)

        json(conn, %{
          user: user_json(user),
          active_clinic_id: scope.clinic_id,
          papel: scope.papel,
          professional_id: scope.professional_id,
          # O fuso da clínica ativa (ADR-009). Quem consome é a agenda, que precisa saber que
          # dia é NA CLÍNICA antes de pedir o dia. Sai da membership já carregada: zero leitura
          # a mais.
          #
          # O relógio NÃO viaja junto, de propósito: o `/me` é carregado pelo layout, que o
          # SvelteKit não reexecuta em navegação client-side, e um instante vindo daqui
          # congelaria na abertura da aba. O fuso pode ser cacheado — ele não muda durante a
          # sessão; um relógio, não.
          timezone: active_timezone(memberships, scope.clinic_id),
          memberships: Enum.map(memberships, &membership_json/1)
        })

      _ ->
        unauthorized(conn)
    end
  end

  # POST /api/auth/switch-tenant {clinic_id} — valida o vínculo ativo e grava o tenant
  # ativo na sessão. Devolve o novo /me.
  def switch_tenant(conn, %{"clinic_id" => clinic_id}) do
    case conn.assigns[:scope] do
      %Scope{user: user} ->
        case Accounts.get_active_membership(user.id, clinic_id, authorize?: false) do
          {:ok, %Membership{}} ->
            conn
            |> put_session(:active_clinic_id, clinic_id)
            |> assign(:scope, nil)
            |> reload_scope(user, clinic_id)
            |> me(%{})

          # 404, e não 403 (doc 96, H-7): o ator não está proibido de nada — a clínica pedida
          # simplesmente não existe para ele. Com 403 o cliente não distinguia "sem permissão
          # nesta clínica" de "esta clínica não é sua", e as duas pedem telas diferentes.
          _ ->
            conn |> put_status(:not_found) |> json(%{error: "no_active_membership"})
        end

      _ ->
        unauthorized(conn)
    end
  end

  def switch_tenant(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "missing_clinic_id"})
  end

  # DELETE /api/auth/sign-out — invalida a sessão. Revoga o token no servidor (não só
  # limpa o cookie): mesmo um cookie capturado deixa de valer (o `jti` vira revogado).
  def sign_out(conn, _params) do
    # Derruba os WebSockets vivos do usuário (Entrega 4). A revogação do cookie não alcança um
    # socket já aberto — o `UserSocket.id/1` nasceu por usuário justamente para permitir isto.
    # Sem o disconnect, uma aba com a agenda aberta seguiria recebendo push da clínica depois do
    # sign-out, por fora da sessão que acabou de ser revogada.
    if user = conn.assigns[:current_user] do
      ApiWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
    end

    conn
    |> Helpers.revoke_session_tokens(:api)
    |> clear_session()
    |> send_resp(:no_content, "")
  end

  # PATCH /api/auth/me {nome} — a pessoa edita o próprio nome de exibição (tela "Meu perfil").
  # Ator e alvo são o usuário da sessão; o e-mail (identidade de login passwordless) não é
  # editável aqui. Nome em branco reprova na ação (`allow_nil? false`) e vira 422.
  def update_profile(conn, params) do
    case conn.assigns[:scope] do
      %Scope{user: user} ->
        case Accounts.update_profile(user, %{nome: params["nome"]}, actor: user) do
          {:ok, updated} ->
            json(conn, %{user: user_json(updated)})

          {:error, error} ->
            error_response(conn, error)
        end

      _ ->
        unauthorized(conn)
    end
  end

  # POST /api/auth/terms-acceptance {versao} — registra o aceite dos documentos legais (`[D-14]`).
  #
  # Quem chama é o **BFF**, logo depois de assinar a sessão, nos dois caminhos de login. E a
  # versão vem dele, não daqui, de propósito: o texto legal mora em `web/src/lib/legal.ts`, e uma
  # constante espelhada nesta ponta apodreceria em silêncio no dia em que o texto mudasse — o
  # banco passaria a registrar aceite de uma versão que ninguém leu. É o A5 aplicado ao registro
  # que menos pode estar errado.
  #
  # Idempotente por versão (ver `Api.Accounts.User.Changes.StampTermsAcceptance`): rodar a cada
  # login não reescreve a data do primeiro aceite.
  def terms_acceptance(conn, params) do
    versao = params["versao"]

    case {conn.assigns[:scope], versao} do
      {%Scope{user: user}, v} when is_binary(v) and v != "" ->
        case Accounts.accept_terms(user, v, %{}, actor: user) do
          {:ok, _updated} -> send_resp(conn, :no_content, "")
          {:error, error} -> error_response(conn, error)
        end

      {%Scope{}, _} ->
        invalid(conn, "versao é obrigatória")

      _ ->
        unauthorized(conn)
    end
  end

  # POST /api/auth/sign-out-everywhere — revoga TODOS os tokens do usuário (add-on
  # log_out_everywhere), encerrando a sessão em todos os dispositivos, INCLUSIVE este. Como o
  # sign-out comum, derruba os WebSockets vivos e limpa a sessão local (o cookie já não vale,
  # pois o próprio token desta requisição foi revogado).
  def sign_out_everywhere(conn, _params) do
    case conn.assigns[:scope] do
      %Scope{user: user} ->
        case Accounts.log_out_everywhere(user, actor: user) do
          {:error, error} ->
            error_response(conn, error)

          _ok ->
            ApiWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
            conn |> clear_session() |> send_resp(:no_content, "")
        end

      _ ->
        unauthorized(conn)
    end
  end

  # GET /api/realtime/token — token efêmero (Phoenix.Token) para o WebSocket dos Channels
  # (ADR-014, 09 §8). Escopo do token: `user_id` + `clinic_id` ativo, para o `join`
  # validar o tópico. Vida curta; trocar de tenant reemite (o BFF chama de novo). É o
  # único token que vai ao browser — o resto é cookie de sessão.
  #
  # O salt e a validade moram em `ApiWeb.RealtimeToken`, com quem verifica (`ApiWeb.UserSocket`).
  #
  # Devolve o `clinic_id` junto: o cliente precisa dele para montar o nome do tópico
  # (`clinic:<id>:agenda:<dia>`), e tirá-lo daqui evita que a página da agenda tenha de
  # buscar o `/me` só por causa disso.
  def realtime_token(conn, _params) do
    case conn.assigns[:scope] do
      %Scope{user: user, clinic_id: clinic_id} when is_binary(clinic_id) ->
        token = ApiWeb.RealtimeToken.sign(%{user_id: user.id, clinic_id: clinic_id})

        expires_at =
          DateTime.utc_now()
          |> DateTime.add(ApiWeb.RealtimeToken.max_age(), :second)
          |> DateTime.to_iso8601()

        json(conn, %{token: token, expires_at: expires_at, clinic_id: clinic_id})

      # 422, e não 409 (doc 96, H-6). A régua do projeto está escrita em `TenantScope`:
      # **422 = "seu pedido está errado"; 409 = "seu pedido estava certo, o mundo mudou"**, com o
      # 409 reservado a concorrência. "Você não tem clínica ativa" não é corrida — e o corpo
      # tampouco seguia a forma do 409 do projeto.
      %Scope{} ->
        invalid(conn, "Nenhuma clínica ativa nesta sessão.")

      _ ->
        unauthorized(conn)
    end
  end

  # A identidade como o cliente a vê. Fonte única do `/me` e do PATCH de perfil — as duas
  # respostas descreviam o mesmo usuário com dois literais, e foi assim que a segunda ficaria
  # para trás quando um campo entrasse (o `avatar_url` seria exatamente esse campo).
  defp user_json(user) do
    %{
      id: user.id,
      nome: user.nome,
      email: to_string(user.email),
      avatar_url: avatar_url(user)
    }
  end

  # A foto de perfil sai como **URL assinada de vida curta**, nunca como a chave do objeto: a
  # chave é o endereço interno no bucket e o cliente não teria o que fazer com ela.
  #
  # Vida de #{div(900, 60)} min, mais longa que os 5 do anexo, porque o consumo é outro: o anexo
  # é um clique que abre uma aba, e o avatar é um `<img>` que a tela do usuário monta a cada
  # `/me`. A URL não é segredo (aponta para uma foto de perfil), mas continua expirando —
  # link vazado deixa de valer.
  #
  # Falha do storage não derruba o `/me`: sem foto, a tela cai nas iniciais, e a sessão inteira
  # não pode depender do Cloudflare estar de pé.
  defp avatar_url(%{avatar_key: chave}) when is_binary(chave) do
    tipo = Api.Accounts.User.Avatar.tipo_da_chave(chave)

    case Api.Storage.presign_get(chave, "avatar", tipo, expires_in: 900) do
      {:ok, %{url: url}} -> url
      _ -> nil
    end
  end

  defp avatar_url(_user), do: nil

  # Reconstrói o scope em memória após a troca de tenant, para o /me refletir na hora.
  defp reload_scope(conn, user, clinic_id) do
    case Accounts.get_active_membership(user.id, clinic_id, authorize?: false) do
      {:ok, %Membership{} = membership} ->
        assign(conn, :scope, Scope.with_membership(user, membership))

      _ ->
        assign(conn, :scope, Scope.new(user))
    end
  end

  # A identidade da clínica que viaja no /me, com o prefixo `clinic_` (o payload é um membership
  # por clínica). Alimenta o topo do sidebar — nome no lugar da marca, CNPJ, contato e endereço —
  # sem um fetch extra e reagindo à troca de tenant; a `clinic` já vem carregada pela read
  # `active_for_user`, então nada disto custa query.
  #
  # É uma LISTA, e espelha o `@campos_de_info` do `ClinicController`, porque foi exatamente aí
  # que ela falhou: quando o endereço deixou de ser uma linha livre e virou sete campos, só
  # `endereco` (o logradouro) continuou atravessando. A tela salvava número, bairro, cidade e
  # CEP, e o sidebar mostrava "Av. Paulista" — dado gravado e invisível, sem erro nenhum.
  # Campo novo lá entra aqui, e chega ao sidebar.
  @campos_da_clinica for campo <- [
                           :nome,
                           :cnpj,
                           :telefone,
                           :cep,
                           :endereco,
                           :numero,
                           :complemento,
                           :bairro,
                           :cidade,
                           :uf,
                           # Por membership também, e não só no topo: na troca de tenant o fuso
                           # muda junto, e a UI não deveria precisar de um /me novo para saber.
                           :timezone
                         ],
                         do: {campo, :"clinic_#{campo}"}

  defp membership_json(%Membership{} = m) do
    Map.merge(
      %{
        clinic_id: m.clinic_id,
        papel: m.papel,
        professional_id: m.professional_id
      },
      clinic_json(m.clinic)
    )
  end

  defp clinic_json(%Api.Accounts.Clinic{} = clinic) do
    Map.new(@campos_da_clinica, fn {campo, chave} -> {chave, Map.get(clinic, campo)} end)
  end

  # Membership sem a clínica carregada: as chaves continuam existindo, nulas. O cliente não deve
  # precisar distinguir "a API não manda esse campo" de "a clínica não preencheu".
  defp clinic_json(_), do: Map.new(@campos_da_clinica, fn {_campo, chave} -> {chave, nil} end)

  # Acha a membership da clínica ativa e SÓ ENTÃO extrai o fuso. A forma óbvia —
  # `Enum.find_value` com `m.clinic_id == clinic_id && m.clinic.timezone` — parece equivalente
  # e não é: `find_value` continua para a próxima membership sempre que o predicado dá falsy,
  # e ele dá falsy tanto para "clínica errada" quanto para "clínica certa, mas sem `timezone`".
  # No segundo caso a busca escorregaria para OUTRA clínica do usuário e devolveria o fuso
  # dela como se fosse o da ativa — num app multi-clínica (ADR-017), o dia inteiro da agenda
  # sairia deslocado. Achar primeiro e casar depois não tem como escorregar.
  defp active_timezone(memberships, clinic_id) do
    case Enum.find(memberships, &(&1.clinic_id == clinic_id)) do
      %{clinic: %{timezone: timezone}} -> timezone
      _ -> nil
    end
  end
end
