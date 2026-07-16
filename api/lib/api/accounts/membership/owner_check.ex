defmodule Api.Accounts.Membership.OwnerCheck do
  @moduledoc """
  Helper compartilhado das validações de hierarquia (ADR-016): o actor é owner ATIVO da
  clínica? Consulta o `Membership` global com `authorize?: false` — é uma decisão de RBAC,
  não pode recorrer nas policies do próprio recurso.
  """
  require Ash.Query

  alias Api.Accounts.Membership

  @doc "true se o actor é owner ativo da clínica dada."
  def owner?(actor_id, clinic_id) when is_binary(actor_id) and is_binary(clinic_id) do
    Membership
    |> Ash.Query.filter(
      user_id == ^actor_id and clinic_id == ^clinic_id and papel == :owner and status == :ativo
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  def owner?(_actor_id, _clinic_id), do: false
end
