defmodule Api.Accounts.User.Changes.SyncGoogleAvatar do
  @moduledoc """
  Enfileira a busca da foto de perfil do Google (`Api.Accounts.AvatarSyncJob`) **uma vez por
  conta**: na primeira vez que aquele usuário aparece com um `picture`.

  ## "No cadastro", não "no login"

  `register_with_google` é a mesma ação para os dois casos (upsert por e-mail), então o gatilho
  não pode ser o ponto de entrada — tem de ser o estado da conta. A pergunta que decide é
  **"esta conta já passou pela busca de foto?"**, respondida pelas duas colunas juntas:
  `avatar_key` (a foto guardada) e `avatar_origem` (a última foto do Google que o job processou,
  carimbada **inclusive quando ele a recusou** — ver `AvatarSyncJob`). Enquanto as duas forem
  nulas, a conta nunca passou por aqui; a partir da primeira passagem, nunca mais passa.

  Consequência conhecida e aceita: **trocar a foto no Google não se propaga.** Quem entrou com
  uma cara fica com ela até alguém limpar as colunas — a alternativa (comparar a URL a cada
  login) foi recusada por decisão do produto, para o login não carregar trabalho recorrente.

  A conta criada por **magic link** que só depois entra com o Google conta como primeira vez: ela
  ainda não tem foto nenhuma, e é o primeiro momento em que existe uma para buscar.

  ## Por que job, e não dentro do login

  O login com Google é um redirect: o usuário está parado numa página em branco esperando o
  `/auth/strategy/user/google/callback` responder. Baixar uma imagem de terceiro no meio disso
  soma a latência do `googleusercontent.com` ao tempo de entrar no app — e, pior, faz o **login
  falhar** quando o download falha. A foto é enfeite; a sessão não é.

  ## Por que `after_action`, e não `after_transaction`

  `Oban.insert/1` aqui roda **na mesma transação** do upsert do usuário. Se o login rolar para
  trás, o job não existe — e não há job apontando para um usuário que não foi criado. O preço
  (uma linha a mais em `oban_jobs` dentro da transação do login) é irrelevante perto disso.

  ## Quando NÃO enfileira

    * o `user_info` não trouxe `picture` (conta sem foto);
    * a URL não é um destino de onde aceitamos baixar (`Api.Accounts.User.Avatar.origem_valida?/1`);
    * a conta já passou pela busca — o caso de **todo login a partir do segundo**.
  """
  use Ash.Resource.Change

  alias Api.Accounts.AvatarSyncJob
  alias Api.Accounts.User.Avatar

  @impl true
  def change(changeset, _opts, _context) do
    url = changeset |> Ash.Changeset.get_argument(:user_info) |> foto()

    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      if sincronizar?(user, url) do
        _ = AvatarSyncJob.enqueue(user, url)
      end

      {:ok, user}
    end)
  end

  defp foto(%{} = user_info), do: user_info["picture"]
  defp foto(_), do: nil

  defp sincronizar?(user, url) do
    Avatar.origem_valida?(url) and primeira_vez?(user)
  end

  defp primeira_vez?(%{avatar_origem: origem, avatar_key: chave}),
    do: is_nil(origem) and is_nil(chave)
end
