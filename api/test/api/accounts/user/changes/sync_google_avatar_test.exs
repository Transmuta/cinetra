defmodule Api.Accounts.User.Changes.SyncGoogleAvatarTest do
  @moduledoc """
  Quando o Google enfileira a busca da foto — e, principalmente, quando **não** enfileira.

  A regra é **uma busca por conta**, no cadastro. `register_with_google` é a mesma ação para
  cadastro e login (upsert por e-mail), então o que decide não é o ponto de entrada e sim o
  estado da conta: enquanto `avatar_key` e `avatar_origem` forem nulas, ela nunca passou por aqui.
  A pessoa loga todos os dias; o login não pode carregar trabalho recorrente.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Accounts
  alias Api.Accounts.AvatarSyncJob
  alias Api.Accounts.User

  @foto "https://lh3.googleusercontent.com/a/ACg8ocK=s96-c"

  defp logar_com_google(user_info) do
    User
    |> Ash.Changeset.for_create(
      :register_with_google,
      %{
        user_info: user_info,
        oauth_tokens: %{"access_token" => "tok-#{System.unique_integer([:positive])}"}
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp user_info(extra \\ %{}) do
    Map.merge(
      %{
        "email" => "google-#{System.unique_integer([:positive])}@example.com",
        "name" => "Ana Souza",
        "sub" => "sub-#{System.unique_integer([:positive])}",
        "iss" => "https://accounts.google.com"
      },
      extra
    )
  end

  test "cadastro com foto: enfileira a busca" do
    user = logar_com_google(user_info(%{"picture" => @foto}))

    assert_enqueued(worker: AvatarSyncJob, args: %{"user_id" => user.id, "url" => @foto})
  end

  test "conta sem foto: nada a buscar" do
    logar_com_google(user_info())

    refute_enqueued(worker: AvatarSyncJob)
  end

  test "foto num host que não é do Google: não vira requisição do servidor" do
    # Sem esta guarda, o `picture` do payload seria um `GET` do servidor para onde ele mandasse —
    # a rede interna do compose inclusive (SSRF). A regra mora em `User.Avatar`; aqui se prova
    # que o produtor do job também a aplica, e não só o consumidor.
    logar_com_google(user_info(%{"picture" => "http://169.254.169.254/latest/meta-data/"}))

    refute_enqueued(worker: AvatarSyncJob)
  end

  test "login seguinte com a MESMA foto: não enfileira de novo" do
    info = user_info(%{"picture" => @foto})
    user = logar_com_google(info)

    Accounts.set_user_avatar!(
      user,
      %{avatar_key: "user/#{user.id}/avatar.png", avatar_origem: @foto},
      authorize?: false
    )

    logar_com_google(info)

    assert [_um_so] = all_enqueued(worker: AvatarSyncJob)
  end

  # Decisão de produto (2026-08-01): a busca é **só no cadastro**. Trocar a foto no Google depois
  # disso NÃO repropaga — o preço de o login não carregar trabalho recorrente. Este teste é o que
  # segura a decisão: antes ele afirmava o contrário, e reverter a regra o deixa vermelho.
  test "a pessoa trocou a foto no Google: NÃO busca de novo" do
    info = user_info(%{"picture" => @foto})
    user = logar_com_google(info)

    Accounts.set_user_avatar!(
      user,
      %{avatar_key: "user/#{user.id}/avatar.png", avatar_origem: @foto},
      authorize?: false
    )

    logar_com_google(%{info | "picture" => @foto <> "-outra"})

    assert [um_so] = all_enqueued(worker: AvatarSyncJob)
    assert um_so.args["url"] == @foto
  end

  # A foto recusada carimba `avatar_origem` sem chave (ver `AvatarSyncJob.recusar/2`), e é esse
  # carimbo que impede a conta de tentar de novo a cada login — o modo de falha silencioso que a
  # regra "só no cadastro" existe para não ter.
  test "conta cuja foto foi recusada não tenta de novo no login seguinte" do
    info = user_info(%{"picture" => @foto})
    user = logar_com_google(info)

    Accounts.set_user_avatar!(user, %{avatar_key: nil, avatar_origem: @foto}, authorize?: false)

    logar_com_google(info)

    assert [_um_so] = all_enqueued(worker: AvatarSyncJob)
  end

  # A fronteira do "cadastro": conta que nasceu por magic link e só depois liga o Google. Ela
  # ainda não tem foto nenhuma, e este é o primeiro momento em que existe uma para buscar.
  test "conta antiga que entra com Google pela primeira vez: busca" do
    email = "magic-#{System.unique_integer([:positive])}@example.com"
    user = Accounts.register_user!("Ana Souza", email, authorize?: false)

    logar_com_google(user_info(%{"email" => email, "picture" => @foto}))

    assert_enqueued(worker: AvatarSyncJob, args: %{"user_id" => user.id, "url" => @foto})
  end

  test "a foto já baixada sobrevive ao próximo login (não está no upsert_fields)" do
    info = user_info(%{"picture" => @foto})
    user = logar_com_google(info)
    chave = "user/#{user.id}/avatar.png"

    Accounts.set_user_avatar!(user, %{avatar_key: chave, avatar_origem: @foto}, authorize?: false)

    logar_com_google(info)

    assert Accounts.get_user!(user.id, authorize?: false).avatar_key == chave
  end
end
