defmodule Api.Accounts.User.Changes.RequireMagicLinkTokenPresence do
  @moduledoc """
  Allowlist do magic link: exige que o `jti` do token EXISTA na tabela `tokens`
  (`purpose: "magic_link"`, gravado na emissão por `store_all_tokens?`), espelhando o que
  `require_token_presence_for_authentication?` já faz na sessão — que o AshAuthentication
  aplica só no pipeline da sessão (`Plug.Helpers`), não na redenção do link.

  Sem isto, o `SignInChange` aceita qualquer JWT bem assinado: `Jwt.verify` só valida
  assinatura/claims e o `validate_jti` apenas checa se há registro de *revogação* — um `jti`
  forjado offline nunca foi revogado, então passa. Com os dois segredos vazados
  (assinatura + envelope do selo, doc 14 §7) isso vira impersonação de qualquer conta, e as
  defesas da sessão (presença, binding jti↔sub) não pegam: o atacante não forja uma sessão —
  faz o **servidor emitir uma legítima** para a vítima. Com a allowlist, forjar um link passa
  a exigir escrita no banco (o "game over composto" que já é o piso do modelo).

  Roda depois de `UnsealMagicLinkToken` (que entrega o JWT cru) e antes do `SignInChange`.
  """
  use Ash.Resource.Change

  alias AshAuthentication.{Errors.InvalidToken, Info, Jwt, TokenResource}

  @impl true
  def change(changeset, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with token when is_binary(token) <- Ash.Changeset.get_argument(changeset, :token),
         # Claims verificados (assinatura + exp/nbf/iss/aud), não o peek cru.
         {:ok, %{"jti" => jti}, _} <- Jwt.verify(token, changeset.resource, opts, context),
         {:ok, [_]} <- get_token(changeset.resource, jti, opts) do
      changeset
    else
      _ -> invalid(changeset)
    end
  end

  defp get_token(resource, jti, opts) do
    resource
    |> Info.authentication_tokens_token_resource!()
    |> TokenResource.Actions.get_token(%{"jti" => jti, "purpose" => "magic_link"}, opts)
  end

  # Mesmo erro do SignInChange para token ruim: não distingue "forjado" de "expirado" para
  # quem tenta (nada a aprender com a resposta).
  defp invalid(changeset) do
    Ash.Changeset.add_error(
      changeset,
      InvalidToken.exception(
        field: :token,
        reason: "Token não está na allowlist",
        type: :magic_link
      )
    )
  end
end
