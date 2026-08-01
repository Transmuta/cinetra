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

      # A trilha (`Api.Audit.Capture`) grava num `after_action`, e hook de after_action é
      # incompatível com update atômico. Custo nulo: o controller já busca a clínica antes de
      # escrever (fetch-then-update para poder devolver 404) — é o mesmo motivo pelo qual todo
      # recurso por-tenant deste projeto já roda não-atômico por causa do `SetTenantGuc`.
      require_atomic? false
    end

    # Comunicação com o paciente (doc 52 §7) — a tela /configuracoes/comunicacao.
    #
    # Ação própria, e não campos somados ao `update_settings`: aquele é o formulário de
    # onboarding/ajustes gerais, e o que ele aceita é o que ele mostra. Somar aqui deixaria a
    # tela de ajustes capaz de desligar o lembrete sem ter um controle para isso — a fronteira
    # HTTP aceita o que a ação aceita, não o que o formulário desenha (09 §8).
    update :update_messaging do
      accept [
        :msg_lembrete_horas,
        :msg_silencio_inicio,
        :msg_silencio_fim
      ]

      # Ver a nota em `update_settings`: a trilha grava num `after_action`.
      require_atomic? false
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

  changes do
    # A trilha (doc 63). Baixo volume, alto impacto: é o que sai em documento (CNPJ, razão
    # social, endereço) e o que reconfigura a agenda inteira (`timezone`, `slot_minutos`,
    # `cap_turma_padrao`) e a comunicação com o paciente (janela de silêncio, lembrete).
    #
    # `tenant_from: :id` — a `Clinic` é o único recurso em que o tenant é o **próprio registro**,
    # não um `clinic_id` que ele carrega.
    change {Api.Audit.Capture, resource: :clinic, label: :nome, tenant_from: :id},
      on: [:create, :update, :destroy]
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

    # Quantas horas antes da sessão sai o lembrete. `nil` = **desligado**.
    #
    # **Padrão 2 h** (decisão de 2026-07-31, doc 98), revogando o `nil` de 2026-07-27. Aquele
    # existia porque a confirmação na criação já era o disparo automático da fatia e o cron podia
    # nascer calado sem deixar ninguém sem comunicação; removida a confirmação, `nil` como padrão
    # deixaria a clínica **muda** para o paciente até alguém abrir esta tela.
    #
    # Duas horas, e não vinte e quatro, porque o que este aviso serve é a decisão de sair de casa
    # — não o planejamento da semana. Quem quiser a véspera troca o número na tela.
    attribute :msg_lembrete_horas, :integer,
      public?: true,
      default: 2,
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

    # O número de WhatsApp pelo qual esta clínica fala — a conta na Zernio (doc 52 §9.1.4).
    #
    # **Nasce nulo em todas, e é assim que tem de ser.** A v1 vai com um número único da Cinetra
    # (C11), então nulo significa "usa o compartilhado", que vem do ambiente. O campo existe
    # desde já não porque alguém vá preenchê-lo agora, mas porque é ele que faz "a clínica nº 2
    # quer o número dela" ser um `UPDATE` em vez de uma refatoração — o §9.1.4 é explícito em
    # que essas quatro coisas são baratas hoje e caras depois.
    #
    # Não é `public?`: não há tela para isso, e não vai haver enquanto número próprio for
    # funcionalidade futura. Quem preenche é operação, direto no banco, com o par
    # `OptOut.clinic_id` preenchido junto (C10) — os dois contam a mesma história.
    attribute :zernio_account_id, :string, constraints: [max_length: 60]

    timestamps()
  end

  relationships do
    # Usada pelas policies (quem é membro/owner desta clínica). Membership é global.
    has_many :memberships, Api.Accounts.Membership
  end
end
