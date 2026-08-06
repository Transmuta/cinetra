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

      # Lote de usuários por id. O feed de auditoria não o usa mais para o autor — desde o doc 63
      # a trilha grava o nome de quem agiu junto com o evento (`user_label`), para a linha
      # continuar legível depois que a pessoa deixa a clínica.
      define :get_user_by_email, action: :get_by_email, args: [:email]
      # Auth sem senha (ADR-015): usados pelo ApiWeb.AuthController.
      define :request_magic_link, action: :request_magic_link, args: [:email]
      define :sign_in_with_magic_link, action: :sign_in_with_magic_link, args: [:token]
      # Tela "Meu perfil": editar o próprio nome e sair de todos os dispositivos.
      define :update_profile, action: :update_profile
      # O aceite dos documentos legais (`[D-14]`), carimbado pela fronteira de autenticação
      # logo depois do login — nos DOIS caminhos, porque os dois passam pelo BFF.
      define :accept_terms, action: :accept_terms, args: [:versao]
      define :log_out_everywhere, action: :log_out_everywhere, args: [:user]
      # Só o `Api.Accounts.AvatarSyncJob` chama (com `authorize?: false`): grava a chave da foto
      # já guardada no bucket. Não há caminho de request para cá.
      define :set_user_avatar, action: :set_avatar
    end

    resource Api.Accounts.Clinic do
      define :onboard_clinic, action: :onboard, args: [:nome]
      define :list_clinics, action: :read
      define :get_clinic, action: :read, get_by: [:id]
      define :update_clinic_settings, action: :update_settings
      define :update_clinic_info, action: :update_info
      define :update_clinic_messaging, action: :update_messaging
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
