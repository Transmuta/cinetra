defmodule Api.Accounts.Membership do
  @moduledoc """
  Vínculo pessoa↔clínica com papel isolado por tenant — a peça central do modelo
  Vercel (ADR-014). Liga um `User` global a uma `Clinic`, com papel por-clínica. A
  mesma pessoa tem N memberships (é assim que um profissional atende em mais de uma
  clínica e uma dona tem mais de uma unidade). `professional_id` é um UUID mole que
  aponta o `Professional` daquele tenant (sem FK entre schemas).
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    # Convite aceito → notifica owner/admin (doc 31). Só `:accept_invite` interessa; o notifier
    # ignora as demais ações.
    #
    # S1: revogar/rebaixar derruba os WebSockets abertos daquele usuário — a conexão só reavalia
    # o vínculo no `join`, e sem isto a revogação valia no REST e não valia no tempo real.
    notifiers: [Api.Notifications.Notifier, ApiWeb.SocketRevocation]

  # Global: o vínculo vive no schema público (liga entidades globais User<->Clinic),
  # sem bloco `multitenancy`. FKs para users e clinics (ambos públicos).
  postgres do
    table "memberships"
    repo Api.Repo

    references do
      reference :user, on_delete: :delete
      reference :clinic, on_delete: :delete

      # `nilify` e não `delete` (doc 92, P1-3(b)): o vínculo sobrevive ao profissional. Se um dia
      # a eliminação da LGPD (D-1) apagar um `Professional` de fato, a pessoa continua na equipe
      # — só deixa de ter coluna na agenda. Perder o membership junto seria apagar acesso por um
      # motivo que não é sobre acesso.
      #
      # **O que esta FK não faz:** ela é *global* — garante que o profissional **existe**, não que
      # é **desta clínica**. A metade que importa (cross-tenant) continua sendo trabalho da
      # `Validations.ProfessionalInClinic`, presente nas três portas de escrita desde a Onda 1.
      # Fechá-la no banco exigiria `UNIQUE (id, clinic_id)` em `professionals` e FK composta;
      # ficou de fora porque a validação já cobre todos os caminhos vivos, e o custo é um índice
      # a mais numa tabela que já tem o seu.
      reference :professional, on_delete: :nilify
    end
  end

  actions do
    defaults [:read]

    # Memberships ATIVOS de um usuário (para o seletor de clínica e o scope da sessão).
    # Chamado na resolução de identidade (authorize?: false) pelo plug de scope.
    read :active_for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status == :ativo)
      prepare build(load: [:clinic], sort: [inserted_at: :asc])
    end

    # O membership ativo de um usuário numa clínica (valida a troca de tenant, 09 §8).
    read :active_for_user_and_clinic do
      argument :user_id, :uuid, allow_nil?: false
      argument :clinic_id, :uuid, allow_nil?: false
      get? true

      filter expr(
               user_id == ^arg(:user_id) and clinic_id == ^arg(:clinic_id) and status == :ativo
             )
    end

    # Convites pendentes de um usuário — ativados no primeiro acesso (ADR-015). Leitura de
    # sistema (authorize?: false) do `Invites.activate_pending/1`.
    read :pending_for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and status == :pendente)
    end

    # Todos os vínculos de uma clínica (a tela de Equipe & acessos). O `user` vem
    # carregado porque a lista mostra nome/e-mail; a policy de leitura garante que só
    # owner/admin da clínica enxergam todos (os demais só a si mesmos).
    read :for_clinic do
      argument :clinic_id, :uuid, allow_nil?: false
      filter expr(clinic_id == ^arg(:clinic_id))
      prepare build(load: [:user], sort: [inserted_at: :asc])
    end

    # Convite: cria pendente; ativa no primeiro acesso (magic link/Google, ADR-015).
    create :invite do
      accept [:papel, :professional_id]
      argument :user_id, :uuid, allow_nil?: false
      argument :clinic_id, :uuid, allow_nil?: false
      change manage_relationship(:user_id, :user, type: :append)
      change manage_relationship(:clinic_id, :clinic, type: :append)
      # D: professional_id (UUID mole) precisa ser da clínica do convite. Estava só em
      # `:invite_by_email` e no `:update` — as três portas escrevem o mesmo vínculo, e o
      # `Scope.professional_id` propaga a referência cross-tenant a partir de qualquer uma
      # delas (doc 92, P1-3).
      validate {Api.Accounts.Membership.Validations.ProfessionalInClinic, []}
      # Só owner convida como owner (barra cunhagem de owner par por admin).
      validate {Api.Accounts.Membership.Validations.RestrictOwnerInvite, []}
    end

    # Convite por e-mail (D24): acha-ou-cria o `User` do convidado a partir do e-mail,
    # cria o vínculo pendente e dispara o magic link. O `clinic_id` vem do escopo (09 §8).
    create :invite_by_email do
      accept [:papel, :professional_id]
      argument :email, :ci_string, allow_nil?: false
      argument :nome, :string, allow_nil?: true
      argument :clinic_id, :uuid, allow_nil?: false

      change manage_relationship(:clinic_id, :clinic, type: :append)
      change Api.Accounts.Membership.Changes.ResolveInvitedUser
      # D: professional_id (UUID mole) precisa ser da clínica do convite.
      validate {Api.Accounts.Membership.Validations.ProfessionalInClinic, []}
      # Só owner convida como owner (barra cunhagem de owner par por admin).
      validate {Api.Accounts.Membership.Validations.RestrictOwnerInvite, []}
    end

    update :update do
      accept [:papel, :professional_id]
      require_atomic? false
      # Hierarquia (ADR-016): owner faz tudo; admin não promove a owner, não mexe em owner
      # nem em outro admin (barra takeover por admin).
      validate {Api.Accounts.Membership.Validations.RoleManagement, []}
      # D: professional_id precisa ser da clínica do vínculo.
      validate {Api.Accounts.Membership.Validations.ProfessionalInClinic, []}
    end

    update :accept_invite do
      accept []
      require_atomic? false
      change set_attribute(:status, :ativo)
    end

    destroy :revoke_access do
      require_atomic? false
      # Hierarquia (ADR-016): só owner revoga owners; admin não revoga outro admin.
      validate {Api.Accounts.Membership.Validations.RoleManagement, []}
    end
  end

  # ADR-016 — RBAC por tenant. As leituras de sistema do scope (active_for_user*) rodam
  # com authorize?: false e não passam por aqui.
  policies do
    # Leitura para todos (D): qualquer membro ATIVO da clínica vê todos os vínculos dela —
    # a gestão é que fica restrita a owner/admin. O primeiro clause cobre o próprio vínculo
    # ainda PENDENTE (antes do primeiro acesso ativar), quando o segundo ainda não vale.
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       clinic.memberships,
                       user_id == ^actor(:id) and status == :ativo
                     )
                   )
    end

    # Convidar: owner/admin da clínica alvo (clinic_id vem como argumento do convite).
    policy action([:invite, :invite_by_email]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin], clinic_from: {:argument, :clinic_id}}
    end

    # Aceitar convite: só o próprio convidado (primeiro acesso via magic link).
    policy action(:accept_invite) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Alterar papel / revogar acesso: owner/admin da clínica do vínculo.
    policy action([:update, :revoke_access]) do
      authorize_if expr(
                     exists(
                       clinic.memberships,
                       user_id == ^actor(:id) and papel in [:owner, :admin] and status == :ativo
                     )
                   )
    end
  end

  changes do
    # A trilha (doc 63) — e este é o recurso mais sensível dos doze. "Quem promoveu Fulano a
    # admin?" e "quem revogou o acesso de Sicrana?" não tinham resposta: `:update` (troca de
    # papel) e `:revoke_access` não deixavam rastro nenhum.
    #
    # O `destroy` agrava: sem a trilha o registro some **inteiro**, e não sobra nem o estado
    # final do qual inferir o que houve — ao contrário de um update. Por isso o `label` sai de
    # `user.nome` com uma leitura: a linha precisa continuar dizendo de quem era o acesso depois
    # que o vínculo não existe mais.
    #
    # `Membership` não tem bloco `multitenancy` (é a tabela que atravessa tenants), então o
    # `changeset.tenant` é nulo e o `clinic_id` do próprio registro é a fonte do tenant da linha.
    change {Api.Audit.Capture,
            resource: :membership,
            label: {:load, :user, :nome},
            meta: [:user_id, :professional_id, :papel, :status]},
           on: [:create, :update, :destroy]
  end

  # ADR-016 — invariante ">=1 owner por tenant" (não-atômica; ver o módulo). Global em
  # update/destroy: é no-op no `accept_invite` (não mexe em papel). A hierarquia de gestão
  # (RoleManagement) NÃO fica aqui — é específica das ações de gestão de papel
  # (`:update`/`:revoke_access`), senão barraria o `accept_invite` de um convite de owner.
  validations do
    validate {Api.Accounts.Membership.Validations.NotLastOwner, []}, on: [:update, :destroy]
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :papel, Api.Accounts.Role, allow_nil?: false, default: :recepcao, public?: true

    attribute :status, Api.Accounts.MemberStatus,
      allow_nil?: false,
      default: :pendente,
      public?: true

    timestamps()
  end

  relationships do
    belongs_to :user, Api.Accounts.User, allow_nil?: false
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false

    # Opcional e único por clínica: aponta um membro `:profissional` ao seu `Professional`.
    #
    # Era `attribute :professional_id, :uuid` — o "UUID mole" — e virou `belongs_to` na Onda 4
    # para ganhar a FK (ver a nota no `references` acima). `attribute_writable?` porque as ações
    # aceitam o id direto (`accept [:papel, :professional_id]`), que é como as três portas de
    # convite/edição sempre escreveram.
    belongs_to :professional, Api.Directory.Professional,
      allow_nil?: true,
      attribute_writable?: true,
      public?: true
  end

  identities do
    identity :unique_user_per_clinic, [:user_id, :clinic_id]
    # profId único por clínica (nulos são distintos no Postgres — vários sem prof ok).
    identity :unique_professional_link, [:clinic_id, :professional_id]
  end
end
