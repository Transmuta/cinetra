defmodule Api.Waitlist.AvailabilityRule do
  @moduledoc """
  Uma regra de disponibilidade de um item da fila (doc 25 §1, `01 §4.5`): "este paciente pode
  vir às segundas e quartas de 09–11" ou "no dia 15/07 de 08–12". Recorrente por dias-da-semana
  (`:semana`) ou pontual numa data (`:data`), cada uma com 1..N faixas de horário.

  Recurso **por-tenant** por atributo (`clinic_id`, ADR-017) e **sempre dono de um
  `WaitlistEntry`** — nunca acessado sozinho. Nasce, muda e some junto do item da fila, via
  `manage_relationship` (`type: :direct_control`), exatamente como `Attendance` nasce de
  `Appointment`. Por isso não tem code interface própria nem policy própria de escrita: quem
  autoriza é a ação do `WaitlistEntry` que a gerencia.

  A forma (`dows` só em `:semana`, `data` só em `:data`, faixas válidas) é conferida pela
  validação `RuleShape`; a **expiração** de uma regra `:data` no passado é decisão do motor
  `SlotFinder` (relógio injetável, ADR-009), não uma constraint.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Waitlist,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "availability_rules"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # Apagar o item da fila apaga suas regras.
      reference :waitlist_entry, on_delete: :delete
    end

    custom_indexes do
      # O acesso é sempre "as regras deste item"; o índice de apoio ao cascade da FK é escrito à
      # mão na migration (mesma razão de `schedule_exceptions`): sob tenancy por atributo o Ash
      # prefixaria `clinic_id`, e `(clinic_id, waitlist_entry_id)` não serve o lookup
      # só-`waitlist_entry_id` do cascade.
      index [:waitlist_entry_id], all_tenants?: true

      # Apoio ao cascade da FK `clinic_id` (achado-h do doc 26, pego no bate-volta E5): apagar uma
      # clínica faz o Postgres checar `WHERE clinic_id = $1` nesta tabela, e sem índice era seq
      # scan. Todas as irmãs (`waitlist_entries`, `slot_holds`) já têm um composto liderado por
      # `clinic_id`; esta era a única sem. Raro (remoção de tenant inteiro), mas fecha o padrão.
      index [:clinic_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:tipo, :dows, :data, :periodos]
      change Api.Tenancy.SetTenantGuc
    end

    # `require_atomic? false`: `SetTenantGuc` é `before_action` (a GUC precisa estar setada para
    # a RLS aceitar a escrita), incompatível com update/destroy atômico — como em `Attendance`.
    update :update do
      primary? true
      require_atomic? false
      accept [:tipo, :dows, :data, :periodos]
      change Api.Tenancy.SetTenantGuc
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change Api.Tenancy.SetTenantGuc
    end
  end

  # Ler é qualquer membro (as regras vêm carregadas com o item). Escrever não é ação direta de
  # ninguém: só o `WaitlistEntry` gerencia, dentro da própria transação já autorizada.
  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    # `always()` era uma afirmação sobre quem chama ("só o `WaitlistEntry` gerencia"), não uma
    # garantia — e afirmação não é policy (doc 96, A-1). `accessing_from` expressa a invariante
    # real: a escrita só é autorizada quando vem pela relação `:rules` do `WaitlistEntry`, cuja
    # própria policy já cobrou papel e tenant. Chamada direta ao recurso passa a ser recusada.
    policy action_type([:create, :update, :destroy]) do
      authorize_if accessing_from(Api.Waitlist.WaitlistEntry, :rules)
    end
  end

  changes do
    # A trilha (doc 63) — e ela precisa morar **aqui**, não no `WaitlistEntry` (doc 101, M9).
    #
    # O pai já tem o `Capture` dele, mas o diff de um recurso Ash é sobre **atributos**: escrita
    # que chega por `manage_relationship` não aparece nele. Medido: trocar a disponibilidade de um
    # item da fila ("segundas 09–11" virando "sextas 13–18") gravava no `waitlist_entry` uma linha
    # de `update` com `diff: []` e mais nada. A mudança que de fato importa para quem audita a fila
    # — quando o paciente disse que pode vir — não deixava rastro.
    #
    # `on: [:create, :update, :destroy]` porque `type: :direct_control` faz as três: a edição
    # substitui o conjunto, então uma regra trocada são um destroy e um create, e é justamente esse
    # par que conta a história.
    change {Api.Audit.Capture,
            resource: :availability_rule, meta: [:waitlist_entry_id, :tipo, :dows, :data]},
           on: [:create, :update, :destroy]
  end

  validations do
    validate {Api.Waitlist.AvailabilityRule.Validations.RuleShape, []}, on: [:create, :update]
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tipo, Api.Waitlist.RuleType, allow_nil?: false, public?: true

    # Dias-da-semana (0=domingo..6=sábado, como `ClinicHours.dow`). Só em `:semana`.
    attribute :dows, {:array, :integer},
      allow_nil?: false,
      default: [],
      public?: true,
      constraints: [items: [min: 0, max: 6]]

    # Data específica. Só em `:data`.
    attribute :data, :date, public?: true

    # Faixas de horário retangulares (pares `["HH:MM","HH:MM"]`), como `ScheduleException.periods`.
    attribute :periodos, {:array, {:array, :string}},
      allow_nil?: false,
      default: [],
      public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :waitlist_entry, Api.Waitlist.WaitlistEntry, allow_nil?: false
  end
end
