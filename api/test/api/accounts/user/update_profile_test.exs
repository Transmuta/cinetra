defmodule Api.Accounts.User.UpdateProfileTest do
  @moduledoc """
  Tela "Meu perfil" no domínio: editar o próprio nome e sair de todos os dispositivos. A
  fronteira HTTP sempre passa o próprio usuário como alvo, então o recorte de segurança —
  "só a si mesmo" — só é exercitável aqui, chamando as ações direto com um ator forjado.
  """
  use Api.DataCase, async: false

  alias Api.Accounts

  defp create_user do
    addr = "user-#{System.unique_integer([:positive])}@example.com"
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  describe "update_profile" do
    test "o dono edita o próprio nome" do
      user = create_user()

      assert {:ok, updated} =
               Accounts.update_profile(user, %{nome: "Nome Novo"}, actor: user)

      assert updated.nome == "Nome Novo"
      assert updated.email == user.email
    end

    test "não dá para editar OUTRO usuário (IDOR): forbidden" do
      alvo = create_user()
      intruso = create_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.update_profile(alvo, %{nome: "Sequestrado"}, actor: intruso)

      # E o nome do alvo permaneceu intacto.
      {:ok, recarregado} = Accounts.get_user(alvo.id, authorize?: false)
      assert recarregado.nome == alvo.nome
    end

    test "nome em branco reprova (allow_nil? false)" do
      user = create_user()

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.update_profile(user, %{nome: ""}, actor: user)
    end
  end

  describe "log_out_everywhere" do
    test "o dono revoga as próprias sessões" do
      user = create_user()
      assert :ok = Accounts.log_out_everywhere(user, actor: user)
    end

    test "não dá para derrubar as sessões de OUTRO usuário: forbidden" do
      alvo = create_user()
      intruso = create_user()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.log_out_everywhere(alvo, actor: intruso)
    end
  end
end
