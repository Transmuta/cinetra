defmodule Api.Accounts.User.RequestMagicLink do
  @moduledoc """
  Pedido de magic link que também carrega o `nome` do cadastro (opcional) dentro do
  token assinado.

  É uma variação enxuta de `AshAuthentication.Strategy.MagicLink.Request` (que só embute
  o e-mail): quando a tela de "criar conta" informa o nome, ele viaja como claim no próprio
  link e sobrevive à ida-e-volta do e-mail — inclusive se aberto em outro aparelho — sem
  estado no servidor. O `sign_in_with_magic_link` lê esse claim
  (ver `Api.Accounts.User.Changes.SetNomeFromToken`).

  Mantém a resposta NEUTRA do magic link (ADR-015): sempre `:ok`, exista o usuário ou não,
  e sem vazar erros (e-mail inexistente/ inválido não são revelados).
  """
  use Ash.Resource.Actions.Implementation

  alias Ash.{ActionInput, Query}
  alias AshAuthentication.{Info, Jwt}

  # Este endpoint é público e não autenticado: limita o nome ANTES de assiná-lo no token,
  # para o link (que carrega o JWT na URL) e a coluna users.nome não crescerem sem limite.
  @max_nome_length 160

  @impl true
  def run(input, _opts, context) do
    strategy = Info.strategy_for_action!(input.resource, input.action.name)
    identity = ActionInput.get_argument(input, strategy.identity_field)
    nome = ActionInput.get_argument(input, :nome)
    context_opts = Ash.Context.to_opts(context)

    input.resource
    |> Query.set_context(%{private: %{ash_authentication?: true}})
    |> Ash.Query.for_read(
      strategy.lookup_action_name,
      %{strategy.identity_field => identity},
      context_opts
    )
    |> Ash.read_one()
    |> case do
      {:error, error} ->
        {:error, error}

      {:ok, user_or_nil} ->
        send_link(strategy, identity, nome, user_or_nil, context, context_opts)
    end
  end

  # Usuário inexistente só recebe link quando o registro por magic link está habilitado
  # (evita criar conta por link para quem nunca se cadastrou).
  defp send_link(%{registration_enabled?: false}, _identity, _nome, nil, _context, _opts), do: :ok

  defp send_link(strategy, identity, nome, user_or_nil, context, context_opts) do
    with {sender, send_opts} <- strategy.sender,
         {:ok, token} <- token_for(strategy, identity, nome, context_opts, context) do
      recipient = user_or_nil || to_string(identity)

      build_opts =
        Keyword.merge(send_opts,
          tenant: context.tenant,
          source_context: context.source_context
        )

      sender.send(recipient, token, build_opts)
    end

    :ok
  end

  # Espelha `MagicLink.request_token_for_identity`, mas embute o `nome` do cadastro quando
  # houver. Os demais claims (`act`, `identity`) e o ciclo do token seguem os do strategy.
  defp token_for(strategy, identity, nome, opts, context) do
    claims =
      %{"act" => strategy.sign_in_action_name, "identity" => to_string(identity)}
      |> maybe_put_nome(nome)

    opts = Keyword.merge(opts, token_lifetime: strategy.token_lifetime, purpose: :magic_link)

    case Jwt.token_for_resource(strategy.resource, claims, opts, context) do
      # O JWT nunca sai cru: viaja selado (cifrado) na URL do e-mail, para não expor
      # e-mail/nome a quem vir o link (ver Api.Accounts.User.MagicLinkToken).
      {:ok, token, _claims} -> {:ok, Api.Accounts.User.MagicLinkToken.seal(token)}
      :error -> :error
    end
  end

  defp maybe_put_nome(claims, nome) when is_binary(nome) do
    case String.trim(nome) do
      "" -> claims
      trimmed -> Map.put(claims, "nome", String.slice(trimmed, 0, @max_nome_length))
    end
  end

  defp maybe_put_nome(claims, _nome), do: claims
end
