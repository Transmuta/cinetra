defmodule Api.Accounts.Membership.Validations.RestrictOwnerRole do
  @moduledoc """
  ADR-016 / D23 — "só a dona (owner) gerencia owners". Impede que um **admin** promova
  alguém a `owner`, se autopromova, ou rebaixe/revogue um `owner`. Sem esta regra, a
  policy de `update`/`revoke_access` (que autoriza qualquer owner/admin) permitiria a um
  admin virar owner e destituir os owners originais (takeover) — o `NotLastOwner` não
  protege porque o admin vira owner *antes* de o owner original deixar de ser o último.

  Complementa (não substitui) o `NotLastOwner`. Não-atômica: precisa consultar o
  `Membership` (global) para saber se o actor é owner ativo da clínica do vínculo.
  """
  use Ash.Resource.Validation
  require Ash.Query

  alias Api.Accounts.Membership

  @impl true
  def validate(changeset, _opts, context) do
    if owner_operation?(changeset) and not actor_is_owner?(context.actor, changeset.data.clinic_id) do
      {:error,
       field: :papel,
       message: "só a dona (owner) pode promover, alterar ou remover owners"}
    else
      :ok
    end
  end

  # A operação "envolve owner" quando: (destroy) o vínculo-alvo é owner; (update) o vínculo
  # já é owner OU o novo papel é owner. Em ambos, mexer nisso exige que o actor seja owner.
  defp owner_operation?(changeset) do
    changeset.data.papel == :owner or
      Ash.Changeset.get_attribute(changeset, :papel) == :owner
  end

  defp actor_is_owner?(%{id: actor_id}, clinic_id)
       when is_binary(actor_id) and is_binary(clinic_id) do
    Membership
    |> Ash.Query.filter(
      user_id == ^actor_id and clinic_id == ^clinic_id and papel == :owner and status == :ativo
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  defp actor_is_owner?(_actor, _clinic_id), do: false
end
