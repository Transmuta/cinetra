defmodule Api.Packages.PackageSchedule do
  @moduledoc """
  A **grade** de um pacote (doc 01 §4.4, `{dows, horarios, profId}` do protótipo,
  [`:117`](../../../../interface/Movimento.dc.html#L117)): em que dias da semana e a que horas as
  sessões caem, e com qual profissional. É o insumo de `Api.Packages.Series` — quem materializa a
  série lê daqui.

  `has_one` do pacote: uma grade por pacote. Recurso por-tenant por atributo (`clinic_id`,
  ADR-017), como o resto de `Api.Packages`.

  ## `horarios` é um mapa `dow => "HH:MM"`

  Guardado como `:map` (JSONB) porque a chave é o dia da semana e o valor o horário daquele dia —
  a grade pode ter horário diferente por dia (seg 08:00, qua 09:00). As chaves chegam do JSON como
  **string** (`"1"`), e é assim que ficam; o `Series` normaliza para inteiro ao projetar.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Packages,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "package_schedules"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # A grade não sobrevive ao pacote.
      reference :package, on_delete: :delete
      # Profissional não some sob uma grade — arquiva (como em Appointment).
      reference :professional, on_delete: :restrict
    end

    check_constraints do
      # O comentário do atributo `dows` afirmava, desde sempre, que "a constraint fecha o range".
      # Ela não existia (doc 92, P2-7) — e documentação que contradiz o banco é pior que a
      # ausência das duas, porque quem lê o código conclui que está coberto e não olha de novo.
      #
      # `<@` (contido em) porque `dows` é array: cada elemento precisa estar em 0..6. Um `7` aqui
      # não estoura nada — vira uma sessão que o `Series` recusa projetar, com o pacote vendido e
      # a agenda vazia.
      check_constraint :dows,
        name: "package_schedules_dows_range",
        check: "dows <@ ARRAY[0,1,2,3,4,5,6]::bigint[]",
        message: "Dia da semana precisa estar entre 0 (domingo) e 6 (sábado)."
    end

    custom_indexes do
      # `[:clinic_id, :package_id]` saiu daqui: virou o índice ÚNICO da identity
      # `:one_schedule_per_package` (mesmas colunas, mesma ordem), e manter os dois seria
      # redundância pura — peso de escrita sem leitura nova.
      index [:professional_id], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:dows, :horarios, :professional_id]
    end

    update :update do
      primary? true
      accept [:dows, :horarios, :professional_id]

      # `SetTenantGuc` roda dentro da transação (RLS) e não é atômico — como no resto do projeto.
      require_atomic? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    # A grade da série é o que decide onde as sessões caem na agenda — mesma lista do `Package`
    # e do `Appointment` desde 2026-08-04 (doc 103).
    policy action_type([:create, :update]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao], clinic_from: :tenant}
    end
  end

  changes do
    change Api.Tenancy.SetTenantGuc
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    # 0=domingo … 6=sábado (LocalTime.dow). A constraint `package_schedules_dows_range` fecha o
    # range; o `Series` recusa dow fora dele de qualquer forma, mas o banco não deve aceitar 7.
    #
    # Esta frase esteve **errada por meses**: ela afirmava a constraint, e a constraint não
    # existia (doc 92, P2-7 — só chegou na Onda 3). Fica o registro, porque documentação que
    # contradiz o banco é pior que a ausência das duas: quem lê conclui que está coberto.
    attribute :dows, {:array, :integer}, allow_nil?: false, public?: true

    # dow => "HH:MM". Chaves string (vindas do JSON); o Series normaliza.
    attribute :horarios, :map, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :package, Api.Packages.Package, allow_nil?: false
    belongs_to :professional, Api.Directory.Professional, allow_nil?: false
  end

  identities do
    # `has_one :schedule` é uma promessa que só o banco pode cumprir. O índice que existia era
    # `CREATE INDEX` comum — ele acelerava a leitura e aceitava a duplicata; com duas grades,
    # `has_one` devolve uma arbitrária e a série é reprojetada pela linha errada, sem erro no
    # caminho (doc 92, P1-2).
    #
    # `pre_check?` pela mesma razão das irmãs (`WaitlistEntry`, `AppointmentType`): sob RLS o
    # Postgres omite o DETAIL do unique_violation, e sem ele o Ash levanta `KeyError` → 500 em
    # vez de 422.
    identity :one_schedule_per_package, [:package_id] do
      pre_check? true
      message "este pacote já tem uma grade"
    end
  end
end
