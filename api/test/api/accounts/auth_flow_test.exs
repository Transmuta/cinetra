defmodule Api.Accounts.AuthFlowTest do
  @moduledoc """
  Fluxo de autenticação sem senha (ADR-015) + resolução de escopo (ADR-014): pedir
  magic link → e-mail → sign-in cria/vincula o `User` → onboard vira owner → o escopo
  resolve o tenant ativo e o papel.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Scope

  defp email, do: "user-#{System.unique_integer([:positive])}@example.com"

  # Bootstrap de conta nova = pedido de CADASTRO (register?: true); o login não cria conta.
  defp request_and_capture_token(addr, nome \\ nil) do
    :ok = Accounts.request_magic_link(addr, %{nome: nome, register?: true})
    assert_receive {:email, email}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, email.text_body)
    token
  end

  test "cadastro (register?: true) envia e-mail para o endereço pedido" do
    addr = email()
    assert :ok = Accounts.request_magic_link(addr, %{register?: true})

    assert_receive {:email, email}, 1_000
    assert email.subject =~ "link de acesso"
    assert [{_, ^addr}] = email.to
    # O link aponta para o callback do WEB (BFF, ADR-005), não para a API.
    assert email.text_body =~ "/auth/callback?token="
  end

  # O buraco que originou esta fatia: o formulário de LOGIN (register?: false, o default)
  # não pode gerar link nem criar conta para um e-mail que ainda não existe — senão o
  # "entrar" vira um cadastro silencioso e dá para enumerar quem tem conta.
  describe "login não cria conta (register?: false)" do
    test "e-mail SEM conta: resposta neutra, sem enviar link e sem criar User" do
      addr = email()

      assert :ok = Accounts.request_magic_link(addr)

      refute_receive {:email, _}, 200
      assert {:error, _} = Accounts.get_user_by_email(addr, authorize?: false)
    end

    test "e-mail COM conta: o login envia o link normalmente" do
      addr = email()
      # Cadastra a conta antes (register?: true), depois um login para o mesmo e-mail.
      {:ok, _user} = Accounts.sign_in_with_magic_link(request_and_capture_token(addr))

      assert :ok = Accounts.request_magic_link(addr)

      assert_receive {:email, mail}, 1_000
      assert [{_, ^addr}] = mail.to
    end
  end

  test "sign-in por magic link cria o User com nome defaultado do e-mail" do
    addr = email()
    token = request_and_capture_token(addr)

    {:ok, user} = Accounts.sign_in_with_magic_link(token)

    assert to_string(user.email) == addr
    # DefaultNomeFromEmail: nome = parte local do e-mail.
    assert user.nome == addr |> String.split("@") |> List.first()
    assert user.__metadata__.token
  end

  test "sign-in por magic link usa o nome informado no cadastro" do
    addr = email()
    token = request_and_capture_token(addr, "Ana Paula")

    {:ok, user} = Accounts.sign_in_with_magic_link(token)

    assert to_string(user.email) == addr
    # O nome do cadastro viaja como claim assinado no token e vira o nome do User.
    assert user.nome == "Ana Paula"
  end

  test "nome absurdamente longo é limitado (não estoura o token/URL nem o DB)" do
    addr = email()
    token = request_and_capture_token(addr, String.duplicate("a", 3_000))

    {:ok, user} = Accounts.sign_in_with_magic_link(token)

    # Ingresso público e não autenticado: o nome é limitado antes de virar claim do token,
    # então nem o link nem a coluna users.nome crescem sem limite.
    assert String.length(user.nome) <= 160
  end

  test "nome do cadastro NÃO sobrescreve o nome de um usuário já existente" do
    addr = email()
    # Primeiro acesso define o nome real.
    {:ok, existing} =
      Accounts.sign_in_with_magic_link(request_and_capture_token(addr, "Nome Verdadeiro"))

    # Um segundo pedido (ex.: alguém tentando "recadastrar") não altera o nome existente:
    # upsert_fields [:email] protege o nome no conflito.
    {:ok, user} =
      Accounts.sign_in_with_magic_link(request_and_capture_token(addr, "Nome Falso"))

    assert user.id == existing.id
    assert user.nome == "Nome Verdadeiro"
  end

  # O link do e-mail (login E convite — o convite é um magic link, D24) carrega o token
  # na URL, que passa por caixa de e-mail, histórico e logs. O padrão da sessão é o token
  # nunca trafegar legível; aqui o equivalente é o selo: o JWT vai CIFRADO na URL.
  describe "selo do token na URL (confidencialidade do link)" do
    alias Api.Accounts.User.MagicLinkToken

    test "o token no link é opaco: não é JWT legível nem expõe e-mail/nome (LGPD)" do
      addr = email()
      :ok = Accounts.request_magic_link(addr, %{nome: "Sigila Segredo", register?: true})
      assert_receive {:email, email}, 1_000
      [_, token] = Regex.run(~r/token=([\w.\-]+)/, email.text_body)

      # Não decodifica como JWT (antes do selo, Joken.peek_claims lia e-mail e nome daqui).
      assert {:error, _} = Joken.peek_claims(token)

      # Nenhum segmento base64 do que viaja revela os claims.
      decodable =
        token
        |> String.split(".")
        |> Enum.flat_map(fn seg ->
          case Base.url_decode64(seg, padding: false) do
            {:ok, bin} -> [bin]
            :error -> []
          end
        end)
        |> Enum.join()

      refute decodable =~ addr
      refute decodable =~ "Sigila"
    end

    test "sign-in exige o token selado: JWT cru (sem selo) é rejeitado" do
      addr = email()
      sealed = request_and_capture_token(addr)

      # Sanidade: dentro do selo existe um JWT normal…
      assert {:ok, jwt} = MagicLinkToken.unseal(sealed)
      assert String.starts_with?(jwt, "eyJ")

      # …mas ele NÃO serve cru: só o formato selado (o que sai no e-mail) autentica.
      assert {:error, _} = Accounts.sign_in_with_magic_link(jwt)
      assert {:ok, user} = Accounts.sign_in_with_magic_link(sealed)
      assert to_string(user.email) == addr
    end

    # Modelo de ameaça (doc 14 §7): com a token_signing_secret vazada o atacante assina
    # JWTs válidos — e o salt do selo é público (código aberto). Se a chave do selo
    # derivasse da MESMA secret, ele selaria também e forjaria convite/login para
    # qualquer e-mail. O selo deriva do secret_key_base (o segredo do ENVELOPE, como no
    # cookie de sessão): forjar um link exige vazar os DOIS segredos.
    test "atacante só com a token_signing_secret assina mas NÃO sela: forja rejeitada" do
      addr = email()
      sealed = request_and_capture_token(addr)
      {:ok, jwt} = MagicLinkToken.unseal(sealed)

      tss = Application.fetch_env!(:api, :token_signing_secret)
      forged_seal = Plug.Crypto.encrypt(tss, "magic link url v1", jwt)

      assert {:error, _} = Accounts.sign_in_with_magic_link(forged_seal)
    end

    # Doc 14 §7: com os DOIS segredos vazados o atacante assina E sela — as barreiras do
    # selo caem. A allowlist é o que sobra: o `jti` do link precisa EXISTIR na tabela
    # (gravado no request_magic_link). Um link forjado offline tem jti que nunca foi
    # emitido → rejeitado. Sem isto, o magic link vira impersonação de qualquer conta,
    # driblando presença/binding da sessão — porque quem emite a sessão é o servidor.
    test "link forjado offline (jti nunca emitido) é rejeitado mesmo com os dois segredos" do
      addr = email()
      Accounts.register_user!(addr, addr, authorize?: false)

      signer = Joken.Signer.create("HS256", Application.fetch_env!(:api, :token_signing_secret))
      now = System.system_time(:second)

      {:ok, jwt, _} =
        Joken.encode_and_sign(
          %{
            "act" => "sign_in_with_magic_link",
            "identity" => addr,
            "sub" => "user",
            "iss" => "AshAuthentication v4.14.1",
            "aud" => "~> 4.14",
            "jti" => "forjado-#{System.unique_integer([:positive])}",
            "iat" => now,
            "nbf" => now,
            "exp" => now + 600,
            "purpose" => "magic_link"
          },
          signer
        )

      # O atacante tem o secret_key_base, então sela sem problema.
      assert {:error, _} = Accounts.sign_in_with_magic_link(MagicLinkToken.seal(jwt))
    end

    test "token selado adulterado é rejeitado (sem estourar 500)" do
      addr = email()
      sealed = request_and_capture_token(addr)

      assert {:error, _} = Accounts.sign_in_with_magic_link(sealed <> "x")
      assert {:error, _} = Accounts.sign_in_with_magic_link("nem-parece-um-selo")

      # Contrato do unseal para entradas fora do caminho feliz: nunca estoura.
      assert {:error, _} = MagicLinkToken.unseal(nil)
      assert {:error, _} = MagicLinkToken.unseal(:nao_e_binario)
    end
  end

  test "onboard cria a clínica E o Membership owner ativo (ADR-016)" do
    addr = email()
    token = request_and_capture_token(addr)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)

    {:ok, clinic} = Accounts.onboard_clinic("Clínica Teste", %{}, actor: user)

    memberships = Accounts.list_active_memberships!(user.id, authorize?: false)
    assert [membership] = memberships
    assert membership.papel == :owner
    assert membership.status == :ativo
    assert membership.clinic_id == clinic.id
  end

  test "o escopo deriva tenant/papel do Membership ativo (Ash.Scope.ToOpts)" do
    addr = email()
    token = request_and_capture_token(addr)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    {:ok, clinic} = Accounts.onboard_clinic("Clínica Escopo", %{}, actor: user)

    [membership] = Accounts.list_active_memberships!(user.id, authorize?: false)
    scope = Scope.with_membership(user, membership)

    assert scope.clinic_id == clinic.id
    assert scope.papel == :owner
    # ToOpts: actor = user, tenant = clinic_id.
    assert {:ok, ^user} = Ash.Scope.ToOpts.get_actor(scope)
    assert {:ok, clinic_id} = Ash.Scope.ToOpts.get_tenant(scope)
    assert clinic_id == clinic.id
  end

  test "onboard exige actor autenticado (policy actor_present)" do
    assert {:error, %Ash.Error.Forbidden{}} = Accounts.onboard_clinic("Sem Dono", %{})
  end
end
