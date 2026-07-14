defmodule Api.Accounts.User.MagicLinkToken do
  @moduledoc """
  Selo (cifra autenticada) do token de magic link/convite que viaja na URL do e-mail.

  O JWT do magic link é **assinado, não cifrado**: sem o selo, qualquer um que veja o
  link (caixa de e-mail, histórico do browser, log de proxy) lê os claims — `identity`
  (e-mail) e `nome`, PII sob LGPD. O padrão da sessão (doc 14 §2) é o token nunca
  trafegar legível; o equivalente para um link é cifrar o JWT inteiro antes de ele
  entrar na URL. `Plug.Crypto.encrypt/3` dá cifra autenticada (XChaCha20-Poly1305).

  A chave do selo deriva do **`secret_key_base`** — o segredo do ENVELOPE, mesmo papel
  que ele já tem no cookie de sessão — e NÃO da `token_signing_secret` que assina o JWT
  (doc 14 §7): quem vaza só a secret de assinatura consegue assinar um JWT válido, mas
  não sela, e o sign-in estrito rejeita — forjar convite/login exige vazar os dois
  segredos. Rotacionar o `secret_key_base` invalida links em trânsito (vida de 10 min,
  custo ~zero) junto com as sessões.

  Emissão: `Api.Accounts.User.RequestMagicLink`. Abertura: o change
  `Api.Accounts.User.Changes.UnsealMagicLinkToken` no `sign_in_with_magic_link` —
  **estrito**: JWT cru não autentica.
  """

  # Salt de derivação (não é segredo): isola esta chave da assinatura dos JWTs e de
  # qualquer outro uso futuro da mesma secret. Mudá-lo invalida links em trânsito.
  @salt "magic link url v1"

  @doc "Cifra o JWT do magic link para viajar opaco na URL do e-mail."
  @spec seal(String.t()) :: String.t()
  def seal(jwt) when is_binary(jwt), do: Plug.Crypto.encrypt(secret(), @salt, jwt)

  @doc """
  Abre o selo, devolvendo o JWT original. Qualquer coisa que não seja um selo íntegro
  (JWT cru, blob adulterado, lixo) → `{:error, _}`. A validade continua sendo do `exp`
  do JWT interno (10 min); o `max_age` do envelope fica no default (1 dia) só como teto.
  """
  @spec unseal(term()) :: {:ok, String.t()} | {:error, term()}
  def unseal(sealed) when is_binary(sealed) do
    case Plug.Crypto.decrypt(secret(), @salt, sealed) do
      {:ok, jwt} when is_binary(jwt) -> {:ok, jwt}
      {:ok, _nao_string} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def unseal(_), do: {:error, :invalid}

  defp secret do
    :api
    |> Application.fetch_env!(ApiWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
