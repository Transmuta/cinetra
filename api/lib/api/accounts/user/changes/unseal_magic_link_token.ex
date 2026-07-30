defmodule Api.Accounts.User.Changes.UnsealMagicLinkToken do
  @moduledoc """
  Abre o selo do token do magic link (ver `Api.Accounts.User.MagicLinkToken`) antes de
  o `SignInChange` verificar o JWT. Declarado como PRIMEIRO change do
  `sign_in_with_magic_link`, reescreve o argumento `:token` com o JWT decifrado — os
  changes seguintes (`SignInChange`, `SetNomeFromToken`) seguem lendo um JWT normal.

  **Estrito**: selo inválido (JWT cru, blob adulterado, lixo) → `InvalidToken`, o mesmo
  erro que o `SignInChange` dá para token ruim — quem só tem o JWT (ex.: pescado de um
  log antigo) não autentica por nenhum entrypoint, pois todos convergem nesta ação.
  """
  use Ash.Resource.Change

  alias Api.Accounts.User.MagicLinkToken
  alias AshAuthentication.Errors.InvalidToken

  @impl true
  def change(changeset, _opts, _context) do
    case MagicLinkToken.unseal(Ash.Changeset.get_argument(changeset, :token)) do
      {:ok, jwt} ->
        Ash.Changeset.set_argument(changeset, :token, jwt)

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          InvalidToken.exception(field: :token, reason: reason, type: :magic_link)
        )
    end
  end
end
