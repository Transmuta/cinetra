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
      accept [:nome, :timezone, :cap_turma_padrao, :slot_minutos]
      change Api.Accounts.Clinic.Changes.CreateOwnerMembership
      change Api.Accounts.Clinic.Changes.SeedAppointmentTypes
      # Doc 22 §2: e o expediente semanal, sem o qual a agenda não sabe quando se atende.
      change Api.Accounts.Clinic.Changes.SeedClinicHours
    end

    update :update_settings do
      accept [:nome, :timezone, :cap_turma_padrao, :slot_minutos]
    end

    # Comunicação com o paciente (doc 52 §7) — a tela /configuracoes/comunicacao.
    #
    # Ação própria, e não campos somados ao `update_settings`: aquele é o formulário de
    # onboarding/ajustes gerais, e o que ele aceita é o que ele mostra. Somar aqui deixaria a
    # tela de ajustes capaz de desligar o lembrete sem ter um controle para isso — a fronteira
    # HTTP aceita o que a ação aceita, não o que o formulário desenha (09 §8).
    update :update_messaging do
      accept [
        :msg_confirmacao_auto,
        :msg_lembrete_horas,
        :msg_silencio_inicio,
        :msg_silencio_fim
      ]
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

    policy action([:update_settings, :update_info, :update_messaging]) do
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

    # settings do protótipo: {capPilates:4, slot:15}. O `noShowConsome` global foi removido: a
    # falta punitiva passou a ser propriedade **do pacote**, definida na criação (RN-31 revisada,
    # Fatia 3) — não há mais padrão de clínica para o qual cair.
    attribute :cap_turma_padrao, :integer, allow_nil?: false, default: 4, public?: true
    attribute :slot_minutos, :integer, allow_nil?: false, default: 15, public?: true

    # ---- Comunicação com o paciente (doc 52 §7) ----
    #
    # Por clínica, e **não** por profissional: por profissional vira matriz que ninguém mantém.

    # A confirmação sai sozinha quando o agendamento é criado. Ligada por padrão — é o
    # comportamento que a recepção espera de "confirmação automática", e o freio de mão é o
    # consentimento da ficha, não este booleano.
    attribute :msg_confirmacao_auto, :boolean, allow_nil?: false, default: true, public?: true

    # Quantas horas antes sai o lembrete. `nil` = **desligado**, e é o default de propósito
    # (decisão de 2026-07-27): o cron nasce construído mas calado, para nada disparar em massa
    # antes de alguém decidir que deve. Ligar é escolher um número nesta tela.
    attribute :msg_lembrete_horas, :integer,
      public?: true,
      constraints: [min: 1, max: 168]

    # Janela de silêncio, em hora local da clínica (0–23). Mensagem que cairia dentro dela é
    # adiada para o fim da janela, não descartada — ver `Api.Messaging.Dispatch.silenciado?/2`.
    # Ambas `nil` = sem janela. Nascem 21h–8h porque "sua sessão é amanhã" às 23h é o tipo de
    # mensagem que faz o paciente bloquear o remetente — e no número compartilhado (§9.1) o
    # bloqueio é coletivo.
    attribute :msg_silencio_inicio, :integer,
      public?: true,
      default: 21,
      constraints: [min: 0, max: 23]

    attribute :msg_silencio_fim, :integer,
      public?: true,
      default: 8,
      constraints: [min: 0, max: 23]

    timestamps()
  end

  relationships do
    # Usada pelas policies (quem é membro/owner desta clínica). Membership é global.
    has_many :memberships, Api.Accounts.Membership
  end
end
