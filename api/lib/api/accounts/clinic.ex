defmodule Api.Accounts.Clinic do
  @moduledoc """
  A clínica — o **tenant** (ADR-014). Recurso global (schema público) que serve de
  registry de tenants. Com tenancy por atributo (ADR-017) a clínica **não** provisiona
  schema nenhum: os recursos por-tenant carregam a coluna `clinic_id` apontando para aqui.
  Reúne o que o protótipo mantinha como singletons globais (hours/settings), agora
  escopado por clínica.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    # D-K: o fuso da clínica é cacheado; quem escreve aqui derruba o cache (em todos os nós).
    notifiers: [Api.Accounts.Clinic.CacheNotifier]

  # A Clinic é o registry de tenants (schema público). Com tenancy por atributo
  # (ADR-017), a clínica não provisiona schema nenhum — os recursos por-tenant
  # carregam a coluna `clinic_id` apontando para aqui.
  postgres do
    table "clinics"
    repo Api.Repo
  end

  actions do
    defaults [:read]

    # ADR-016: o `onboard` cria a clínica E o Membership `owner` do usuário atual, na
    # mesma transação (ver o change). Garante a invariante "≥1 owner por tenant".
    # Doc 20 (T3): e o catálogo de tipos de atendimento, sem o qual não se agenda.
    create :onboard do
      accept [:nome, :timezone, :cap_turma_padrao, :falta_consome_padrao, :slot_minutos]
      change Api.Accounts.Clinic.Changes.CreateOwnerMembership
      change Api.Accounts.Clinic.Changes.SeedAppointmentTypes
      # Doc 22 §2: e o expediente semanal, sem o qual a agenda não sabe quando se atende.
      change Api.Accounts.Clinic.Changes.SeedClinicHours
    end

    update :update_settings do
      accept [:nome, :timezone, :cap_turma_padrao, :falta_consome_padrao, :slot_minutos]
    end

    # Dados de identidade da clínica (tela /configuracoes/clinica): nome, CNPJ e endereço.
    # O CNPJ chega mascarado do form, é normalizado para a forma canônica e validado como
    # CNPJ alfanumérico (jul/2026); ambos são opcionais e podem ser limpos (branco → nil).
    update :update_info do
      accept [:nome, :cnpj, :endereco]

      # A validação do CNPJ (módulo 11 com aritmética por caractere) e a normalização não são
      # atômicas — a ação roda a leitura+escrita numa transação, sem UPDATE atômico.
      require_atomic? false
      validate Api.Accounts.Clinic.Validations.ValidCnpj
      change Api.Accounts.Clinic.Changes.NormalizeCnpj
    end
  end

  # ADR-016: leitura só para membros ativos; onboard para qualquer autenticado (vira
  # owner); ajuste de settings só para owner/admin. Papel derivado do Membership do tenant.
  policies do
    policy action_type(:read) do
      authorize_if expr(exists(memberships, user_id == ^actor(:id) and status == :ativo))
    end

    policy action(:onboard) do
      authorize_if actor_present()
    end

    policy action([:update_settings, :update_info]) do
      authorize_if expr(
                     exists(
                       memberships,
                       user_id == ^actor(:id) and papel in [:owner, :admin] and status == :ativo
                     )
                   )
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # max_length casado com o maxlength do form de onboarding (web). Vazio já é barrado
    # pelo default do tipo (allow_empty? false); o limite superior fecha a fronteira HTTP,
    # já que o cap do client não vale para quem bate direto na API (09 §8).
    attribute :nome, :string, allow_nil?: false, public?: true, constraints: [max_length: 160]

    # Identidade fiscal (opcional). Guardado na forma canônica de 14 posições (12 alfanuméricas
    # + 2 DV), sem máscara — ver `Api.Cnpj` e a `NormalizeCnpj`. O `max_length` folgado só limita
    # a fronteira HTTP para caber a forma mascarada (18 chars) antes da normalização.
    attribute :cnpj, :string, public?: true, constraints: [max_length: 20]

    # Endereço da clínica em texto único (linha livre). Opcional; branco vira nil.
    attribute :endereco, :string, public?: true, constraints: [max_length: 200, trim?: true]

    # ADR-009: timezone canônico da clínica. "Hoje"/"já começou" resolvem aqui.
    attribute :timezone, :string, allow_nil?: false, default: "America/Sao_Paulo", public?: true

    # settings do protótipo: {capPilates:4, noShowConsome:false, slot:15}
    attribute :cap_turma_padrao, :integer, allow_nil?: false, default: 4, public?: true
    attribute :falta_consome_padrao, :boolean, allow_nil?: false, default: false, public?: true
    attribute :slot_minutos, :integer, allow_nil?: false, default: 15, public?: true

    timestamps()
  end

  relationships do
    # Usada pelas policies (quem é membro/owner desta clínica). Membership é global.
    has_many :memberships, Api.Accounts.Membership
  end
end
