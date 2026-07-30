defmodule Api.Accounts.Membership.Validations.RestrictOwnerInvite do
  @moduledoc """
  Complemento da hierarquia (ADR-016) para os convites: só a dona (owner) pode convidar/criar
  um vínculo já com papel `owner`. Sem isso, um admin poderia cunhar um owner par direto pela
  API — a UI não oferece (INVITABLE_ROLES não tem owner), mas a policy do convite autoriza
  qualquer owner/admin. É a mesma classe de takeover que o `RoleManagement` barra no update.

  O `clinic_id` do convite vem como argumento da ação. Não-atômica: consulta o `Membership`
  (via `OwnerCheck`) para saber se o actor é owner da clínica.
  """
  use Ash.Resource.Validation

  alias Api.Accounts.Membership.OwnerCheck

  @impl true
  def validate(changeset, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    if Ash.Changeset.get_attribute(changeset, :papel) == :owner and
         not OwnerCheck.owner?(actor_id, clinic_id(changeset)) do
      {:error, field: :papel, message: "só a dona (owner) pode convidar alguém como owner"}
    else
      :ok
    end
  end

  # Sem actor (operação de sistema, authorize?: false): RBAC não se aplica.
  def validate(_changeset, _opts, _context), do: :ok

  defp clinic_id(changeset) do
    case Ash.Changeset.get_argument(changeset, :clinic_id) do
      nil -> nil
      value -> to_string(value)
    end
  end
end
