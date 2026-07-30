defmodule ApiWeb.AuthControllerTest do
  @moduledoc """
  Endpoints de autenticação e sessão (ADR-015, contrato 09 §8) pelo pipeline real
  (`:authenticated` → load_from_session → VerifyTokenSubject → LoadScope). Cobre o que
  é sensível: resposta NEUTRA do magic link, exigência de sessão em `/me`, troca de
  tenant só com vínculo ativo, escopo do token de realtime e revogação no sign-out.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts

  defp create_user, do: sign_in!("user-#{System.unique_integer([:positive])}@example.com")

  defp onboard(user, nome \\ nil) do
    nome = nome || "Clínica #{System.unique_integer([:positive])}"
    {:ok, clinic} = Accounts.onboard_clinic(nome, %{}, actor: user)
    clinic
  end

  describe "POST /api/auth/magic-link (resposta neutra)" do
    test "cadastro (register:true), e-mail novo: 200 {ok:true} e dispara o e-mail",
         %{conn: conn} do
      addr = "user-#{System.unique_integer([:positive])}@example.com"
      conn = post(conn, ~p"/api/auth/magic-link", %{email: addr, register: true})

      assert json_response(conn, 200) == %{"ok" => true}
      assert_receive {:email, mail}, 1_000
      assert [{_, ^addr}] = mail.to
    end

    # O flag `register` é fixado por rota no BFF: /entrar não o manda. Um e-mail sem conta
    # no login recebe a MESMA resposta neutra, mas nenhum e-mail é disparado e nenhuma conta
    # é criada — não dá para descobrir quais e-mails têm conta.
    test "login (sem register), e-mail SEM conta: 200 {ok:true} mas NÃO envia", %{conn: conn} do
      addr = "user-#{System.unique_integer([:positive])}@example.com"
      conn = post(conn, ~p"/api/auth/magic-link", %{email: addr})

      assert json_response(conn, 200) == %{"ok" => true}
      refute_receive {:email, _}, 200
      assert {:error, _} = Accounts.get_user_by_email(addr, authorize?: false)
    end

    test "login (sem register), e-mail COM conta: 200 {ok:true} e dispara o e-mail",
         %{conn: conn} do
      # Conta de fato existente (fluxo completo: request + sign-in).
      addr = to_string(create_user().email)

      conn = post(conn, ~p"/api/auth/magic-link", %{email: addr})

      assert json_response(conn, 200) == %{"ok" => true}
      assert_receive {:email, mail}, 1_000
      assert [{_, ^addr}] = mail.to
    end

    test "e-mail em branco: ainda 200 {ok:true} e NÃO envia (não revela conta)", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/magic-link", %{email: ""})

      assert json_response(conn, 200) == %{"ok" => true}
      refute_receive {:email, _}, 200
    end

    test "cadastro com nome: o nome atravessa o token e vira o nome do User", %{conn: conn} do
      addr = "user-#{System.unique_integer([:positive])}@example.com"

      conn =
        post(conn, ~p"/api/auth/magic-link", %{email: addr, nome: "Bianca Souza", register: true})

      assert json_response(conn, 200) == %{"ok" => true}
      assert_receive {:email, mail}, 1_000
      [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)

      {:ok, user} = Accounts.sign_in_with_magic_link(token)
      assert user.nome == "Bianca Souza"
    end
  end

  describe "GET /api/auth/magic-link/callback" do
    test "sem token: 400 missing_token", %{conn: conn} do
      conn = get(conn, ~p"/api/auth/magic-link/callback")
      assert json_response(conn, 400) == %{"error" => "missing_token"}
    end

    test "token inválido: 401 com location para o login do web (erro=magic_link)", %{conn: conn} do
      conn = get(conn, ~p"/api/auth/magic-link/callback?token=lixo")
      assert conn.status == 401
      assert [location] = get_resp_header(conn, "location")
      assert location =~ "/entrar?erro=magic_link"
    end

    # O cookie de sessão é assinado E cifrado (encryption_salt no endpoint): assinatura
    # sozinha só garante integridade — sem cifra, base64-decode puro do payload revelava
    # a chave `user_token` e o JWT inteiro a quem tivesse o valor do cookie.
    test "o _api_key emitido não é legível por base64 puro (cifrado, não só assinado)",
         %{conn: conn} do
      addr = "user-#{System.unique_integer([:positive])}@example.com"
      :ok = Accounts.request_magic_link(addr, %{register?: true})
      assert_receive {:email, mail}, 1_000
      [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)

      conn = get(conn, ~p"/api/auth/magic-link/callback?token=#{token}")
      assert redirected_to(conn) =~ Api.web_app_url()
      assert %{value: cookie} = conn.resp_cookies["_api_key"]

      decodable =
        cookie
        |> String.split(".")
        |> Enum.flat_map(fn seg ->
          case Base.url_decode64(seg, padding: false) do
            {:ok, bin} -> [bin]
            :error -> []
          end
        end)
        |> Enum.join()

      refute decodable =~ "user_token"
      refute decodable =~ "eyJ"
    end
  end

  describe "GET /api/auth/me" do
    test "sem sessão: 401 not_authenticated", %{conn: conn} do
      conn = get(conn, ~p"/api/auth/me")
      assert json_response(conn, 401) == %{"error" => "not_authenticated"}
    end

    test "autenticado com clínica: 200 com identidade, papel e memberships", %{conn: conn} do
      user = create_user()
      clinic = onboard(user)

      conn = conn |> authed(user) |> get(~p"/api/auth/me")
      body = json_response(conn, 200)

      assert body["user"]["email"] == to_string(user.email)
      assert body["active_clinic_id"] == clinic.id
      assert body["papel"] == "owner"
      assert [membership] = body["memberships"]
      assert membership["clinic_id"] == clinic.id
    end

    # O fuso da clínica viaja no /me para que o BFF saiba QUE DIA É na clínica **antes** de
    # pedir a agenda. Sem ele, a agenda chutava o dia em UTC, descobria o fuso na resposta e,
    # na janela noturna, refazia a busca inteira — dois round-trips para um (achado (f)(4) do
    # doc 26). A `clinic` já vem carregada na membership, então isto não custa query nenhuma.
    test "traz o fuso da clínica ativa, sem custar leitura extra", %{conn: conn} do
      user = create_user()
      clinic = onboard(user)

      body = conn |> authed(user) |> get(~p"/api/auth/me") |> json_response(200)

      assert body["timezone"] == clinic.timezone
      assert [%{"clinic_timezone" => tz}] = body["memberships"]
      assert tz == clinic.timezone
    end

    # O relógio NÃO viaja no /me, e isso é decisão, não esquecimento: o payload é carregado
    # pelo layout do SvelteKit, que não reexecuta em navegação client-side — um instante daqui
    # congelaria na abertura da aba. Fuso pode ser cacheado; relógio, não.
    test "NÃO traz relógio — ele viria congelado para o cliente", %{conn: conn} do
      user = create_user()
      onboard(user)

      body = conn |> authed(user) |> get(~p"/api/auth/me") |> json_response(200)

      refute Map.has_key?(body, "agora")
    end

    # O caminho que o `Enum.find_value` errava: com duas clínicas, se a ATIVA não tivesse fuso
    # resolvível, a busca escorregava para a outra e devolvia o fuso dela. Aqui as duas têm
    # fuso, e o teste exige que venha o da ativa — não o da primeira da lista.
    test "com duas clínicas, o fuso é o da ATIVA", %{conn: conn} do
      user = create_user()
      primeira = onboard(user)

      {:ok, segunda} =
        Accounts.onboard_clinic(
          "Outra #{System.unique_integer([:positive])}",
          %{timezone: "America/Manaus"},
          actor: user
        )

      conn = conn |> authed(user) |> post(~p"/api/auth/switch-tenant", %{clinic_id: segunda.id})
      body = json_response(conn, 200)

      assert body["active_clinic_id"] == segunda.id
      assert body["timezone"] == "America/Manaus"
      refute body["timezone"] == primeira.timezone
    end
  end

  describe "POST /api/auth/switch-tenant" do
    test "troca para clínica com vínculo ativo: 200 e o /me reflete", %{conn: conn} do
      user = create_user()
      _a = onboard(user, "Clínica A")
      b = onboard(user, "Clínica B")

      conn = conn |> authed(user) |> post(~p"/api/auth/switch-tenant", %{clinic_id: b.id})
      assert json_response(conn, 200)["active_clinic_id"] == b.id
    end

    test "clínica sem vínculo ativo: 403 no_active_membership", %{conn: conn} do
      user = create_user()
      _sua = onboard(user, "Sua Clínica")
      outro = create_user()
      alheia = onboard(outro, "Clínica Alheia")

      conn = conn |> authed(user) |> post(~p"/api/auth/switch-tenant", %{clinic_id: alheia.id})
      assert json_response(conn, 403) == %{"error" => "no_active_membership"}
    end

    test "sem clinic_id: 400 missing_clinic_id", %{conn: conn} do
      user = create_user()
      _c = onboard(user)

      conn = conn |> authed(user) |> post(~p"/api/auth/switch-tenant", %{})
      assert json_response(conn, 400) == %{"error" => "missing_clinic_id"}
    end
  end

  describe "GET /api/realtime/token" do
    test "com clínica ativa: 200 e o token traz user_id + clinic_id", %{conn: conn} do
      user = create_user()
      clinic = onboard(user)

      conn = conn |> authed(user) |> get(~p"/api/realtime/token")
      body = json_response(conn, 200)

      assert is_binary(body["token"])

      assert {:ok, %{user_id: uid, clinic_id: cid}} =
               Phoenix.Token.verify(ApiWeb.Endpoint, "realtime socket", body["token"],
                 max_age: 900
               )

      assert uid == user.id
      assert cid == clinic.id
    end

    test "autenticado sem clínica ativa: 409 no_active_clinic", %{conn: conn} do
      user = create_user()

      conn = conn |> authed(user) |> get(~p"/api/realtime/token")
      assert json_response(conn, 409) == %{"error" => "no_active_clinic"}
    end

    test "sem sessão: 401", %{conn: conn} do
      conn = get(conn, ~p"/api/realtime/token")
      assert json_response(conn, 401) == %{"error" => "not_authenticated"}
    end
  end

  describe "DELETE /api/auth/sign-out" do
    test "invalida a sessão: 204 e o /me seguinte volta 401", %{conn: conn} do
      user = create_user()
      _c = onboard(user)

      conn = conn |> authed(user) |> delete(~p"/api/auth/sign-out")
      assert conn.status == 204

      # Sessão limpa: uma nova requisição na mesma conn (cookies reciclados) não autentica.
      conn = get(conn, ~p"/api/auth/me")
      assert json_response(conn, 401) == %{"error" => "not_authenticated"}
    end
  end

  describe "PATCH /api/auth/me (Meu perfil)" do
    test "sem sessão: 401 not_authenticated", %{conn: conn} do
      conn = patch(conn, ~p"/api/auth/me", %{nome: "Novo Nome"})
      assert json_response(conn, 401) == %{"error" => "not_authenticated"}
    end

    test "autenticado: 200, atualiza o nome e o /me seguinte reflete", %{conn: conn} do
      user = create_user()
      _c = onboard(user)

      conn = conn |> authed(user) |> patch(~p"/api/auth/me", %{nome: "Bianca Ferreira"})
      body = json_response(conn, 200)

      assert body["user"]["nome"] == "Bianca Ferreira"
      # O e-mail (identidade de login) NÃO muda por aqui.
      assert body["user"]["email"] == to_string(user.email)

      me = conn |> get(~p"/api/auth/me") |> json_response(200)
      assert me["user"]["nome"] == "Bianca Ferreira"
    end

    test "nome em branco: 422 (allow_nil? false)", %{conn: conn} do
      user = create_user()
      _c = onboard(user)

      conn = conn |> authed(user) |> patch(~p"/api/auth/me", %{nome: ""})
      assert json_response(conn, 422)["error"] == "invalid"

      # E não corrompeu o nome anterior.
      me = build_conn() |> authed(user) |> get(~p"/api/auth/me") |> json_response(200)
      assert me["user"]["nome"] == user.nome
    end
  end

  describe "POST /api/auth/sign-out-everywhere" do
    test "sem sessão: 401 not_authenticated", %{conn: conn} do
      conn = post(conn, ~p"/api/auth/sign-out-everywhere")
      assert json_response(conn, 401) == %{"error" => "not_authenticated"}
    end

    test "204 e limpa a própria sessão", %{conn: conn} do
      user = create_user()

      conn = conn |> authed(user) |> post(~p"/api/auth/sign-out-everywhere")
      assert conn.status == 204

      conn = get(conn, ~p"/api/auth/me")
      assert json_response(conn, 401) == %{"error" => "not_authenticated"}
    end

    test "revoga TODOS os tokens: outra sessão do mesmo usuário também para de valer",
         %{conn: conn} do
      email = "user-#{System.unique_integer([:positive])}@example.com"
      device_a = sign_in!(email)
      device_b = sign_in!(email)
      assert device_a.id == device_b.id

      # O dispositivo B pede "sair de todos".
      conn_b = conn |> authed(device_b) |> post(~p"/api/auth/sign-out-everywhere")
      assert conn_b.status == 204

      # O dispositivo A, com um TOKEN diferente, também deixa de autenticar.
      conn_a = build_conn() |> authed(device_a) |> get(~p"/api/auth/me")
      assert json_response(conn_a, 401) == %{"error" => "not_authenticated"}
    end
  end
end
