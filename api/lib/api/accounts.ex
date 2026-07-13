defmodule Api.Accounts do
  @moduledoc """
  Domínio de identidade e acesso (modelo Vercel, ADR-014/015/016). Recursos **globais**
  (schema público): `User` (identidade), `Clinic` (tenant registry) e `Membership`
  (vínculo com papel por-tenant).
  """
  use Ash.Domain, otp_app: :api

  resources do
    resource Api.Accounts.User do
      define :register_user, action: :register, args: [:nome, :email]
      define :get_user, action: :read, get_by: [:id]
      define :get_user_by_email, action: :get_by_email, args: [:email]
      # Auth sem senha (ADR-015): usados pelo ApiWeb.AuthController.
      define :request_magic_link, action: :request_magic_link, args: [:email]
      define :sign_in_with_magic_link, action: :sign_in_with_magic_link, args: [:token]
    end

    resource Api.Accounts.Clinic do
      define :onboard_clinic, action: :onboard, args: [:nome]
      define :get_clinic, action: :read, get_by: [:id]
    end

    resource Api.Accounts.Membership do
      define :invite_member, action: :invite
      define :invite_member_by_email, action: :invite_by_email, args: [:email]
      define :list_clinic_members, action: :for_clinic, args: [:clinic_id]
      define :update_membership, action: :update
      define :accept_invite, action: :accept_invite
      define :revoke_access, action: :revoke_access
      define :list_memberships, action: :read
      define :get_membership, action: :read, get_by: [:id]
      define :list_pending_memberships, action: :pending_for_user, args: [:user_id]
      # Resolução do scope da sessão (ADR-014):
      define :list_active_memberships, action: :active_for_user, args: [:user_id]

      define :get_active_membership,
        action: :active_for_user_and_clinic,
        args: [:user_id, :clinic_id]
    end

    resource Api.Accounts.Token
    resource Api.Accounts.UserIdentity
  end
end
