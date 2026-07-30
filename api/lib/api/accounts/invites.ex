defmodule Api.Accounts.Invites do
  @moduledoc """
  Aceite de convites no **primeiro acesso** (ADR-015 / D24). Quando um convidado entra
  pela primeira vez (magic link ou Google), seus `Membership`s pendentes viram ativos —
  é o que faz o escopo passar a resolver o tenant do convidado. Mantém a orquestração Ash
  fora dos controllers web (regra ash.md).
  """
  alias Api.Accounts

  @doc """
  Ativa todos os vínculos pendentes de `user`. Retorna a lista de vínculos ativados
  (vazia quando não há nenhum). A leitura é de sistema (`authorize?: false`); o aceite
  em si roda como o próprio usuário (policy `user_id == actor.id`).
  """
  def activate_pending(%Accounts.User{} = user) do
    user.id
    |> Accounts.list_pending_memberships!(authorize?: false)
    |> Enum.map(&Accounts.accept_invite!(&1, actor: user))
  end
end
