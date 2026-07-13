defmodule Api.Accounts.Membership.Changes.ResolveInvitedUser do
  @moduledoc """
  Convite por e-mail (D24): resolve o `User` do convidado a partir do e-mail —
  acha-ou-cria, **sem** sobrescrever o nome de quem já existe — liga ao `Membership`
  pendente, e, fora da transação, dispara o magic link que serve de convite (ADR-015).

  O `clinic_id` vem sempre do escopo (argumento da ação), nunca do corpo (09 §8); o
  RBAC de quem pode convidar é a policy da ação, não este change.
  """
  use Ash.Resource.Change

  alias Api.Accounts

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    # `before_action` roda DEPOIS da autorização e DENTRO da transação. Resolver o user
    # aqui (e não no corpo do change/3, que roda na montagem do changeset, antes da policy)
    # impede que um convite negado crie um User fantasma no banco.
    |> Ash.Changeset.before_action(&resolve_and_link/1)
    |> Ash.Changeset.after_transaction(&send_invite/2)
  end

  defp resolve_and_link(changeset) do
    email = Ash.Changeset.get_argument(changeset, :email)
    nome = Ash.Changeset.get_argument(changeset, :nome)
    user = resolve_user(email, nome)
    Ash.Changeset.manage_relationship(changeset, :user, user, type: :append)
  end

  # Acha o usuário pelo e-mail; só cria (com nome) quando ainda não existe, para não
  # sobrescrever o nome de uma pessoa que já tem conta em outra clínica.
  defp resolve_user(email, nome) do
    case Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, %Accounts.User{} = user} ->
        user

      _ ->
        Accounts.register_user!(nome_or_default(nome, email), to_string(email), authorize?: false)
    end
  end

  defp send_invite(changeset, {:ok, membership}) do
    email = Ash.Changeset.get_argument(changeset, :email)
    # Best-effort: o convite é um magic link para o e-mail do convidado (D24). Uma falha
    # de envio não deve derrubar o vínculo já criado.
    _ = Accounts.request_magic_link(to_string(email))
    {:ok, membership}
  end

  defp send_invite(_changeset, result), do: result

  defp nome_or_default(nome, _email) when is_binary(nome) and nome != "", do: nome

  defp nome_or_default(_nome, email) do
    email |> to_string() |> String.split("@") |> List.first()
  end
end
