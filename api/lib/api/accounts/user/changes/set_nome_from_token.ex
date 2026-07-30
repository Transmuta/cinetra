defmodule Api.Accounts.User.Changes.SetNomeFromToken do
  @moduledoc """
  Aplica ao `User` o `nome` que veio (opcional) como claim do token do magic link,
  colocado lá no cadastro por `Api.Accounts.User.RequestMagicLink`.

  O `sign_in_with_magic_link` é um upsert com `upsert_fields [:email]`: num usuário já
  existente o nome NÃO é sobrescrito no conflito, então este change só tem efeito no
  primeiro acesso (criação). Roda antes de `Api.Accounts.User.Changes.DefaultNomeFromEmail`,
  que segue como fallback quando o token não trouxe nome (ex.: login por `/entrar`).
  """
  use Ash.Resource.Change

  alias AshAuthentication.Jwt

  @impl true
  def change(changeset, _opts, context) do
    with token when is_binary(token) <- Ash.Changeset.get_argument(changeset, :token),
         {:ok, claims, _} <-
           Jwt.verify(token, changeset.resource, Ash.Context.to_opts(context), context),
         nome when is_binary(nome) <- Map.get(claims, "nome"),
         trimmed when trimmed != "" <- String.trim(nome) do
      Ash.Changeset.force_change_attribute(changeset, :nome, trimmed)
    else
      _ -> changeset
    end
  end
end
