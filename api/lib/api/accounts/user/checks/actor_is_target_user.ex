defmodule Api.Accounts.User.Checks.ActorIsTargetUser do
  @moduledoc """
  Autoriza a ação de sessão `log_out_everywhere` só quando o `:user` alvo é o próprio ator.

  É uma ação genérica (sem registro no data layer), então um filter check `expr(id == actor)`
  não se aplica — não há linha para filtrar. A comparação é sobre o argumento `:user` do input,
  disponível em `context.subject` (um `Ash.ActionInput`). O controller sempre passa o usuário do
  escopo como argumento; esta checagem é defesa em profundidade contra um alvo forjado.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "o ator é o usuário alvo da ação"

  @impl true
  def match?(%{id: actor_id}, %{subject: %Ash.ActionInput{arguments: %{user: %{id: user_id}}}}, _opts),
    do: actor_id == user_id

  def match?(_actor, _context, _opts), do: false
end
