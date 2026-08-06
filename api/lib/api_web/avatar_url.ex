defmodule ApiWeb.AvatarUrl do
  @moduledoc """
  A foto de perfil de um usuário como o cliente a recebe: **URL assinada de vida curta**, ou
  `nil`.

  Existe porque duas respostas precisam exatamente disto — o `/me` (a própria pessoa) e a lista
  de `/api/members` (os co-membros da clínica) —, e a regra tem três partes que não podem
  divergir entre elas: nunca devolver a chave, derivar o tipo da extensão, e não deixar uma falha
  do storage derrubar a resposta inteira. Duplicada, a segunda cópia seria a que esqueceria a
  terceira parte.

  ## Por que a URL assinada, e não a chave

  A chave (`user/<id>/avatar.png`) é o endereço interno no bucket privado: o cliente não teria o
  que fazer com ela, e dá-la seria contar a estrutura do storage de graça.

  ## Por que #{div(900, 60)} minutos

  Mais que os 5 do anexo, e por um motivo de consumo, não de sigilo: o anexo é um clique que abre
  uma aba; o avatar é um `<img>` que a tela remonta a cada `/me` e a cada abertura da Equipe.
  Curto o suficiente para um link vazado deixar de valer, longo o suficiente para a aba aberta
  não perder a imagem no meio do uso.

  ## Falha do storage não derruba a resposta

  Sem foto — ou com o bucket fora do ar — o retorno é `nil` e a tela cai nas iniciais. A sessão
  e a lista da equipe não podem depender do Cloudflare estar de pé.
  """

  alias Api.Accounts.User.Avatar

  @ttl 900

  @doc "A URL assinada da foto do usuário, ou `nil` quando não há foto (ou o storage falhou)."
  def for_user(%{avatar_key: chave}) when is_binary(chave) do
    case Api.Storage.presign_get(chave, "avatar", Avatar.tipo_da_chave(chave), expires_in: @ttl) do
      {:ok, %{url: url}} -> url
      _ -> nil
    end
  end

  def for_user(_user), do: nil
end
