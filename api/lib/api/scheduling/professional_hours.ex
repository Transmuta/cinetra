defmodule Api.Scheduling.ProfessionalHours do
  @moduledoc """
  A grade semanal de **um profissional** (correção g, `01 §4.3`) — uma linha por
  dia-da-semana (`dow` 0=domingo … 6=sábado), com um `modo` explícito:

    * `:herda`   — nesse dia o profissional atende no horário da clínica (herda o expediente);
    * `:custom`  — atende nos próprios `periods` (que precisam **caber dentro** da clínica);
    * `:fechado` — não atende nesse dia (o `null` explícito do `avail[dow]` do protótipo).

  Isto resolve o duplo-sentido do `prof.avail` do protótipo (que dependia da flag
  `followClinic`, [`:840`](../../../interface/Movimento.dc.html#L840)) numa representação única:
  `Professional.segue_horario_clinica` decide o *default* e esta grade guarda o que difere,
  preservando a distinção significativa entre "fechado explícito" (`:fechado`) e "não disse
  nada, herda a clínica" (linha ausente / `:herda`) — RN-10.

  Recurso **por-tenant** via atributo (`strategy :attribute`, ADR-017), espelhando
  `ClinicHours`: tabela única `professional_hours` com `clinic_id`, RLS em migration própria
  (ADR-018). A tela edita a grade inteira e salva de uma vez; a persistência é linha-a-linha
  por `dow` via `set_day` (upsert na identidade `one_per_prof_dow`). O wrapper de domínio
  `Api.Scheduling.update_professional_hours/3` valida a semana toda **antes** de escrever —
  inclusive o invariante prof ⊆ clínica —, então nenhuma escrita falha no meio.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "professional_hours"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # Apagar o profissional apaga sua grade.
      reference :professional, on_delete: :delete
    end

    check_constraints do
      # O gêmeo de `clinic_hours_dow_range` — ver a nota lá. Mesmo domínio (0..6), mesmo modo de
      # falha silencioso.
      check_constraint :dow,
        name: "professional_hours_dow_range",
        check: "dow BETWEEN 0 AND 6",
        message: "Dia da semana precisa estar entre 0 (domingo) e 6 (sábado)."
    end

    # Sem índice standalone em `clinic_id`: a identidade `one_per_prof_dow` `(clinic_id,
    # professional_id, dow)` já lidera por `clinic_id`, cobrindo o lookup por tenant. O índice
    # que apoia o cascade da FK de `professional_id` é escrito à mão na migration (como em
    # `ScheduleException`): sob tenancy por atributo o Ash prefixaria `clinic_id`, e um
    # `(clinic_id, professional_id, dow)` não serve o lookup só-`professional_id` do cascade.
  end

  actions do
    defaults [:read]

    # `set_day` grava (ou sobrescreve) a grade de um dia. Upsert na `one_per_prof_dow` porque a
    # tela reenvia dias já existentes. `SetTenantGuc` num `before_action` seta a GUC para a RLS.
    create :set_day do
      primary? true
      upsert? true
      upsert_identity :one_per_prof_dow
      accept [:professional_id, :dow, :modo, :periods]
      change Api.Tenancy.SetTenantGuc
    end
  end

  # ADR-016: qualquer membro ativo lê (a agenda depende da grade); só owner/admin escrevem.
  # O `clinic_id` vem do tenant, nunca do corpo.
  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type(:create) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin], clinic_from: :tenant}
    end
  end

  preparations do
    prepare build(sort: [dow: :asc])
  end

  changes do
    # A trilha (doc 63). A grade do profissional é o outro lado do expediente: `modo`
    # (herda/custom/fechado) decide se o dia dele existe na agenda.
    change {Api.Audit.Capture,
            resource: :professional_hours, meta: [:professional_id, :dow, :modo]},
           on: [:create, :update, :destroy]
  end

  validations do
    validate {Api.Scheduling.Validations.ProfessionalDayPeriods, []}, on: [:create]
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :dow, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0, max: 6]

    attribute :modo, Api.Scheduling.WeekdayMode, allow_nil?: false, public?: true

    # Pares "HH:MM" (retangular Nx2). Só é preenchido quando `modo == :custom`; `[]` nos demais.
    attribute :periods, {:array, {:array, :string}},
      allow_nil?: false,
      default: [],
      public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :professional, Api.Directory.Professional, allow_nil?: false
  end

  identities do
    # Uma linha por (profissional, dia-da-semana). O `clinic_id` entra na unicidade
    # automaticamente (tenancy por atributo). Alvo do upsert de `set_day`.
    #
    # `pre_check?` (como no nome único de `AppointmentType`): sob RLS o Postgres omite o DETAIL
    # do unique_violation, e sem ele o AshPostgres estoura `KeyError` → 500 no lugar do 422.
    identity :one_per_prof_dow, [:professional_id, :dow] do
      pre_check? true
      message "já existe grade para esse dia"
    end
  end
end
