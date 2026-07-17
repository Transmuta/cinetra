defmodule Api.Scheduling.ClinicHours do
  @moduledoc """
  O horário semanal da clínica (doc 22 §2) — o expediente. Uma linha por dia-da-semana
  (`dow` 0=domingo … 6=sábado); `periods` é a lista de períodos `[["08:00","12:00"], …]` desse
  dia, e `[]` = fechado. Recurso **por-tenant** via atributo (`strategy :attribute`, ADR-017),
  espelhando `AppointmentType`: tabela única `clinic_hours` com a coluna `clinic_id`, RLS em
  migration própria (ADR-018).

  Clínica nova nasce com a semana do protótipo — ver
  `Api.Accounts.Clinic.Changes.SeedClinicHours` (Seg–Sex 08–12/13–18, Sáb manhã, Dom fechado).

  A tela edita a semana inteira e salva de uma vez; a persistência é linha-a-linha por `dow`,
  via `set_day` (upsert na identidade `one_per_dow`). O wrapper de domínio
  `Api.Scheduling.update_clinic_hours/2` valida a semana toda **antes** de escrever, então
  nenhuma escrita falha no meio (o motor de conflitos com a agenda fica para depois — doc 22
  §6/H2).
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "clinic_hours"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
    end

    # Sem índice standalone em `clinic_id`: a identidade única `one_per_dow` é um índice
    # `(clinic_id, dow)` que já lidera por `clinic_id`, cobrindo todo lookup por tenant e o
    # cascade da FK. Um índice só de `clinic_id` seria peso morto (bate-volta F3).
  end

  actions do
    defaults [:read]

    # `set_day` grava (ou sobrescreve) o horário de um dia. Upsert na `one_per_dow` porque a
    # tela reenvia dias já existentes; e é o mesmo caminho do seed. `require_atomic? false`:
    # o `SetTenantGuc` seta a GUC num `before_action`, incompatível com escrita atômica.
    create :set_day do
      primary? true
      upsert? true
      upsert_identity :one_per_dow
      accept [:dow, :periods]
      change Api.Directory.Changes.SetTenantGuc
    end
  end

  # ADR-016 / doc 22 H7: qualquer membro ativo lê o expediente (a agenda inteira depende
  # dele); só owner/admin escrevem. O `clinic_id` vem do tenant, nunca do corpo.
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
    # Ordem estável (por dia-da-semana). O wire é um mapa `{dow => periods}` — a ordem não
    # viaja —, mas os testes e qualquer leitor determinístico agradecem.
    prepare build(sort: [dow: :asc])
  end

  validations do
    validate {Api.Scheduling.Validations.ValidPeriods, attribute: :periods}, on: [:create]
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

    # Pares "HH:MM" sempre de tamanho 2 → o array multidimensional do Postgres é sempre
    # retangular (Nx2), então `{:array, {:array, :string}}` persiste sem jagged. `[]` = fechado.
    attribute :periods, {:array, {:array, :string}},
      allow_nil?: false,
      default: [],
      public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
  end

  identities do
    # Um registro por dia-da-semana por clínica (o `clinic_id` entra na unicidade
    # automaticamente, tenancy por atributo). É o alvo do upsert de `set_day`.
    identity :one_per_dow, [:dow]
  end
end
