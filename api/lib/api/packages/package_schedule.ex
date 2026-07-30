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

    custom_indexes do
      index [:clinic_id, :package_id]
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

    policy action_type([:create, :update]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao, :profissional], clinic_from: :tenant}
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

    # 0=domingo … 6=sábado (LocalTime.dow). A constraint fecha o range; o `Series` recusa dow
    # fora dele de qualquer forma, mas o banco não deve aceitar 7.
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
end
