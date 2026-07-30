defmodule Api.Scheduling.ScheduleException do
  @moduledoc """
  Exceção de data (doc 22 §2) — um feriado, um dia fechado ou um expediente reduzido numa data
  específica. **Polimórfico pelo dono**: `professional_id` nulo = exceção da **clínica** (vale
  para todos); preenchido = folga/horário pontual de um **profissional**. As da clínica vieram
  na fatia de Horário (doc 22 H1); as do profissional entram na fatia Profissionais — a mesma
  tabela e a mesma ação, só com o `professional_id` preenchido (sem migração de forma).

  Recurso **por-tenant** via atributo (`strategy :attribute`, ADR-017), com RLS em migration
  própria (ADR-018), espelhando `AppointmentType`.

  Ao contrário do `AppointmentType` (que arquiva), aqui **excluir é `destroy` de verdade**
  (doc 22 H4): uma exceção é uma linha de data sem FK dependente — apagar não deixa nada
  pendurado.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "schedule_exceptions"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # Apagar o profissional apaga suas exceções (folgas). Nas exceções da clínica é nulo.
      reference :professional, on_delete: :delete
    end

    # Sem índice standalone em `clinic_id`: a identidade `one_per_data_prof` `(clinic_id, data,
    # professional_id)` lidera por ele (bate-volta F3). O índice que apoia o cascade da FK de
    # `professional_id` (bate-volta F1) é escrito à mão na migration `..._professional_index`,
    # e não aqui: sob tenancy por atributo o Ash prefixaria `clinic_id`, e um `(clinic_id,
    # professional_id)` não serve o lookup só-`professional_id` que o cascade faz.
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      # `professional_id` nulo = exceção da CLÍNICA (feriado); preenchido = folga/horário
      # pontual de um profissional. Que o `professional_id` pertença ao tenant é conferido no
      # wrapper `create_professional_exception` (como o `ProfessionalInClinic` do convite) —
      # a FK só garante que é um profissional, não que é DESTA clínica.
      accept [:data, :nome, :tipo, :periods, :professional_id]
      change Api.Tenancy.SetTenantGuc

      # A3/D12 — o recheck dentro da ação. **Depois** do `SetTenantGuc`: a análise lê a agenda, e
      # sem a GUC setada a RLS devolveria zero linhas e ela concluiria que não há conflito nenhum.
      change Api.Scheduling.ScheduleException.Changes.CheckFutureConflicts
    end

    # `require_atomic? false`: o `SetTenantGuc` roda num `before_action` (a GUC precisa estar
    # setada para a RLS aceitar o DELETE), incompatível com destroy atômico.
    destroy :destroy do
      primary? true
      require_atomic? false
      change Api.Tenancy.SetTenantGuc
    end
  end

  # doc 22 H7: qualquer membro lê; só owner/admin escrevem. Espelha `ClinicHours`/`AppointmentType`.
  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type([:create, :destroy]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin], clinic_from: :tenant}
    end
  end

  preparations do
    prepare build(sort: [data: :asc])
  end

  changes do
    # A trilha (doc 63). Feriado da clínica e folga de profissional mudam a disponibilidade de
    # um dia inteiro; o `destroy` (desfazer a exceção) é tão auditável quanto o create, e é por
    # isso que o `on:` inclui `:destroy` — o default do Ash o omitiria.
    change {Api.Audit.Capture,
            resource: :schedule_exception, label: :nome, meta: [:data, :tipo, :professional_id]},
           on: [:create, :update, :destroy]
  end

  validations do
    # `periods` coerente com o `tipo` (horário exige períodos; fechado não tem), e a forma dos
    # períodos. Ver `ExceptionPeriods`.
    validate {Api.Scheduling.Validations.ExceptionPeriods, []}, on: [:create]
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :data, :date, allow_nil?: false, public?: true

    attribute :nome, :string, public?: true, constraints: [max_length: 120]

    attribute :tipo, Api.Scheduling.ExceptionKind, allow_nil?: false, public?: true

    # Só quando `:horario`. Retangular (pares) → persiste como `{:array, {:array, :string}}`.
    attribute :periods, {:array, {:array, :string}},
      allow_nil?: false,
      default: [],
      public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    # nulo ⇒ exceção da clínica; preenchido ⇒ do profissional (fatia futura, doc 22 §5).
    belongs_to :professional, Api.Directory.Professional, allow_nil?: true
  end

  identities do
    # doc 22 H3: uma exceção por data por dono. `nils_distinct? false` para que duas exceções
    # da clínica (professional_id NULL) na MESMA data colidam de fato — sem isso o Postgres
    # trata NULLs como distintos e a unicidade não valeria justo para as da clínica (PG15+).
    #
    # `pre_check?` (como no nome único de `AppointmentType`): sob RLS o Postgres omite o DETAIL
    # do unique_violation, e sem ele o AshPostgres estoura `KeyError` → 500 no lugar do 422.
    # Checando antes do INSERT, o caminho normal nunca encosta na constraint.
    identity :one_per_data_prof, [:data, :professional_id] do
      pre_check? true
      nils_distinct? false
      message "já existe uma exceção nessa data"
    end
  end
end
