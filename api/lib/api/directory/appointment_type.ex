defmodule Api.Directory.AppointmentType do
  @moduledoc """
  O catálogo de tipos de atendimento da clínica (doc 20) — Avaliação, Sessão, RPG, Pilates,
  Reavaliação e o que a clínica criar. Recurso **por-tenant** via atributo (`strategy
  :attribute`, ADR-017), espelhando `Professional`: mora na tabela única `appointment_types`
  com a coluna `clinic_id`, que o Ash filtra em toda query e preenche na criação a partir do
  tenant do escopo.

  Clínica nova nasce com os 5 tipos do protótipo — ver
  `Api.Accounts.Clinic.Changes.SeedAppointmentTypes` (T3): sem tipo não se agenda.

  **Não tem `destroy`** (T2): `Appointment`/`Package`/`PriceVersion` vão apontar para cá com
  `allow_nil?: false`, então apagar deixaria FK pendurada. Sair de circulação é
  `archive` (`ativo: false`), reversível por `restore`.

  Não confundir com `Records.AttendanceType` (particular/reembolso/convênio): a UI do
  protótipo usa o mesmo rótulo "tipo de atendimento" para as duas coisas (doc 20 §0).
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Directory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # Paletas fechadas do protótipo, validadas no servidor: o cliente não escolhe hex/ícone
  # livre. Mesmo espírito do whitelist `@papeis` do MembersController — a fronteira HTTP
  # não confia no client (09 §8).
  #
  # **Esta é a autoridade da paleta** — quem recusa com 422 é o `one_of` daqui. A tela repete a
  # lista em `web/src/lib/appointment-types.ts` (`TYPE_COLORS`/`TYPE_ICONS`) para só *oferecer* o
  # que a API aceita, e não há compilador que ligue os dois lados: são linguagens diferentes, e o
  # container da API não enxerga `web/` (nem o contrário). O que existe no lugar é a tripwire de
  # `appointment_type_test.exs` — mudar a lista aqui deixa um teste vermelho pedindo, por escrito,
  # que a outra ponta seja mudada junto.
  @cores ~w(#0FB5A6 #0072B2 #009E73 #CC79A7 #7A52CC #D55E00 #E69F00 #2B7FFF)
  @icones ~w(Activity ClipboardList StretchHorizontal Users RefreshCw HeartPulse Dumbbell
             Footprints Hand Bone)

  @doc "A paleta de cores aceita (a mesma que o `one_of` valida)."
  def cores, do: @cores

  @doc "A paleta de ícones aceita (a mesma que o `one_of` valida)."
  def icones, do: @icones

  postgres do
    table "appointment_types"
    repo Api.Repo

    # Apagar a clínica apaga seu catálogo: o tenant é a clínica; sem ela o tipo não existe.
    references do
      reference :clinic, on_delete: :delete
    end

    # **Não há `check_constraint` de "capacidade sse grupo", e isso é decisão** (doc 92, P2-7).
    #
    # A auditoria propôs endurecer no banco a coerência que as duas `validate` abaixo já exigem.
    # Aplicada, ela quebrou a suíte — e o teste que caiu explica por quê: `Api.Scheduling`
    # mantém um fallback **defensivo** para turma sem teto (`Clinic.cap_turma_padrao`), escrito
    # exatamente para a linha que veio de fora das ações. Ver o moduledoc de
    # `Api.Scheduling.Appointment.Validations.GroupCapacity`: *"o fallback é defensivo — vale
    # para linha escrita fora dessas ações. Tipo individual não tem teto nenhum: a validação sai
    # calada."*
    #
    # Ou seja: `capacidade sse grupo` é regra **da ação**, não invariante **do dado**, e o
    # sistema foi desenhado para tolerar a linha frouxa em vez de recusá-la. Pôr o `CHECK` aqui
    # proibiria o único estado para o qual o fallback existe.

    # `clinic_id` não é indexado por padrão, e TODA query desta tabela filtra por ele
    # (atributo + RLS). Sem o índice, cada leitura vira seq scan (auditoria doc 13, causa C).
    custom_indexes do
      index [:clinic_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:nome, :duracao_minutos, :cor, :icon, :grupo, :capacidade]
    end

    # `require_atomic? false` nas 3: o `SetTenantGuc` seta a GUC de tenant num
    # `before_action`, e hook de before_action é incompatível com update atômico. O custo é
    # nulo aqui — o controller já busca o registro antes de escrever (fetch-then-update para
    # poder devolver 404), então já era leitura+escrita de qualquer jeito.
    update :update do
      primary? true
      accept [:nome, :duracao_minutos, :cor, :icon, :grupo, :capacidade]
      require_atomic? false
    end

    # T2: "excluir" é arquivar. Não aceita campo nenhum — só a transição de estado.
    update :archive do
      accept []
      require_atomic? false
      change set_attribute(:ativo, false)
    end

    update :restore do
      accept []
      require_atomic? false
      change set_attribute(:ativo, true)
    end
  end

  # ADR-016 / T8: qualquer membro ativo lê o catálogo (a agenda inteira depende dele); só
  # owner/admin escrevem. O `clinic_id` vem do tenant ativo, nunca do corpo.
  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type([:create, :update]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin], clinic_from: :tenant}
    end
  end

  preparations do
    # Ordem estável do catálogo (doc 20: `inserted_at: :asc`, igual Membros). Mora no
    # recurso — e não só no wrapper de leitura — porque sem ORDER BY o Postgres devolve as
    # linhas na ordem que quiser: o teste do seed flagrou isso piscando (a ordem "certa"
    # saía por sorte). Assim todo leitor recebe ordem determinística.
    prepare build(sort: [inserted_at: :asc])
  end

  changes do
    # Toda escrita seta a GUC de tenant dentro da própria transação: a injeção automática do
    # `Api.Repo.on_transaction_begin/1` só alcança leitura, e sem GUC a RLS barra o
    # INSERT/UPDATE. Ver o moduledoc do change — é sutil e a suíte não pega (BYPASSRLS).
    change Api.Tenancy.SetTenantGuc

    # A trilha (doc 63). Mudar a duração ou o preço de um tipo reverbera em todo agendamento
    # futuro e no que a recepção cobra; arquivar tira a opção da tela sem dizer quem.
    change {Api.Audit.Capture, resource: :appointment_type, label: :nome},
      on: [:create, :update, :destroy]
  end

  validations do
    # Paleta fechada. Só em create/update: `archive`/`restore` não tocam nesses campos, e a
    # linha já gravada é válida por construção.
    validate one_of(:cor, @cores), on: [:create, :update, :destroy]
    validate one_of(:icon, @icones), on: [:create, :update, :destroy]

    # Capacidade presente **sse** grupo (01:474). Sem isso caberia turma sem teto ou
    # atendimento individual com "capacidade 6", que a agenda não saberia interpretar.
    validate present(:capacidade), where: [attribute_equals(:grupo, true)]
    validate absent(:capacidade), where: [attribute_equals(:grupo, false)]
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :nome, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 60]

    # 5..480: o passo da grade (clinic.slot_minutos) NÃO limita a duração — D3 separa os
    # dois, e o próprio protótipo tem slot 15 com duração 50.
    attribute :duracao_minutos, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 5, max: Api.Scheduling.Duration.max_minutos()]

    attribute :cor, :string, allow_nil?: false, public?: true
    attribute :icon, :string, allow_nil?: false, public?: true
    attribute :grupo, :boolean, allow_nil?: false, default: false, public?: true
    attribute :capacidade, :integer, public?: true, constraints: [min: 2, max: 50]

    # T2: arquivado some da lista, mas continua referenciável pelo histórico da agenda.
    attribute :ativo, :boolean, allow_nil?: false, default: true, public?: true

    timestamps()
  end

  relationships do
    # clinic_id é a coluna de tenant (FK -> clinics.id, garante integridade).
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
  end

  calculations do
    calculate :sigla, :string, Api.Directory.AppointmentType.Calculations.Sigla do
      public? true
    end
  end

  identities do
    # T7: dois "Sessão" seriam indistinguíveis na agenda e colidiriam na sigla derivada.
    # Com tenancy por atributo o Ash inclui o `clinic_id` na unicidade automaticamente,
    # então isto é "único por clínica", não global (ver a migration).
    #
    # `pre_check?` não é luxo: sob RLS o Postgres **omite o DETAIL** do unique_violation
    # (poderia vazar linha invisível), e o AshPostgres lê `error.postgres.detail` para
    # transformar a violação em erro de campo — sem DETAIL, estoura `KeyError` e o 422 vira
    # 500. Checando antes do INSERT, o caminho normal nunca encosta na constraint. O índice
    # único continua no banco como rede de segurança (corrida entre dois POSTs simultâneos).
    identity :unique_nome, [:nome] do
      pre_check? true
      message "já existe um tipo com esse nome"
    end
  end
end
