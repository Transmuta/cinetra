defmodule Api.Waitlist.WaitlistEntry do
  @moduledoc """
  Um paciente aguardando vaga para encaixe (doc 25 §1, `01 §4.5`). O item da fila: um paciente,
  uma prioridade, uma janela de preferência, os profissionais preferidos (0..N; vazio = qualquer)
  e 0..N regras de disponibilidade (`AvailabilityRule`). Recurso **por-tenant** por atributo
  (`clinic_id`, ADR-017), como todo o resto da agenda.

  ## Um item por paciente (upsert)

  O `addFila` do protótipo faz **upsert por paciente** ([`:1189`](../../../interface/Movimento.dc.html#L1189)):
  adicionar de novo o mesmo paciente **edita** o item existente em vez de duplicar. Aqui isso é a
  identity `one_entry_per_patient` + `upsert? true` na `:enqueue`. O `pre_check?` não é enfeite:
  sob RLS o Postgres omite o `DETAIL` do `unique_violation` e o AshPostgres estoura `KeyError` →
  500 em vez de um erro tratado — já mordeu em `appointment_type.ex` e `schedule_exception.ex`.

  ## `dias_na_fila` não mora aqui

  Quantos dias o paciente está na fila é derivado de `inserted_at` **no relógio do escopo**
  (ADR-009) e no fuso da clínica — computado na serialização (`ApiWeb.WaitlistJSON`), não como
  calculation de banco. `today()` em expressão Ash roda em UTC e erraria por um dia na virada; e
  o relógio injetável é o que torna a regra determinística no teste (correção h de `01 §4.5`).

  ## `obs` é texto puro (D-E5.1)

  A observação ("queixa aguda", "encaminhamento") **não é cifrada** — coerente com o `obs` do
  agendamento (A-D7) e a fatia de Pacientes, que reverteram a cifra de `06 §3.1`. Fica coberta
  pelas policies da fila, não por criptografia.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Waitlist,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    # D-E5.3: as mutações da fila viram sinal de tempo real (o cliente recarrega a lista).
    notifiers: [Api.Waitlist.WaitlistNotifier]

  postgres do
    table "waitlist_entries"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # Apagar o paciente apaga seu item de fila (é fila DELE).
      reference :patient, on_delete: :delete
    end

    custom_indexes do
      # A-D5 do doc 25 e o "quem cabe": lookup por paciente. `all_tenants?` para servir o cascade
      # da FK de `patient_id` (mesma razão de `appointments(created_by_id)`): sob ADR-017 o Ash
      # prefixaria `clinic_id` e o índice não serviria o `WHERE patient_id = $1` do Postgres.
      index [:patient_id], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    # POST /waitlist — `addFila` (upsert por paciente). Adicionar de novo o mesmo paciente edita
    # o item existente (identity `one_entry_per_patient`).
    create :enqueue do
      primary? true
      upsert? true
      upsert_identity :one_entry_per_patient
      accept [:patient_id, :prio, :janela, :obs, :professional_ids]

      # O `patient_id` tem de ser da clínica ativa: sem isto a fila aceitava um paciente alheio e
      # criava um item-fantasma (`patient: null` sob RLS) — bate-volta E5.
      validate Api.Waitlist.WaitlistEntry.Validations.PatientInClinic

      # As regras chegam como lista de mapas; `:direct_control` cria/atualiza/apaga para casar
      # com a entrada — no upsert isso **substitui** o conjunto de regras, fiel ao `{...f,...d}`
      # do `addFila`.
      argument :rules, {:array, :map}, default: []
      change manage_relationship(:rules, type: :direct_control)

      change Api.Tenancy.SetTenantGuc
    end

    # PATCH /waitlist/:id — editar um item existente (prioridade, janela, preferidos, regras).
    update :update do
      primary? true
      # `SetTenantGuc` é `before_action`, incompatível com update atômico (como no resto da agenda).
      require_atomic? false
      accept [:prio, :janela, :obs, :professional_ids]

      argument :rules, {:array, :map}
      change manage_relationship(:rules, type: :direct_control)

      change Api.Tenancy.SetTenantGuc
    end

    # DELETE /waitlist/:id — sair da fila (`:1186`). Destroy de verdade: o item some quando o
    # paciente é agendado (convert) ou removido à mão. As regras e holds vão junto pelo cascade.
    destroy :dequeue do
      primary? true
      require_atomic? false
      change Api.Tenancy.SetTenantGuc
    end
  end

  # A8: recepção é quem administra a fila. Molde do `Appointment` — **sem** recorte A7 (a fila
  # não é "do profissional"; um profissional pode ver a fila inteira da clínica).
  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type([:create, :update, :destroy]) do
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

    attribute :prio, Api.Waitlist.Priority,
      allow_nil?: false,
      default: :normal,
      public?: true

    attribute :janela, Api.Waitlist.TimeWindow,
      allow_nil?: false,
      default: :qualquer,
      public?: true

    # Queixa/observação em texto livre (0–500). Texto puro (D-E5.1).
    attribute :obs, :string, public?: true, constraints: [max_length: 500]

    # Profissionais preferidos (0..N). `{:array, :uuid}` **sem FK**, precedente de `Patient.prefs`.
    # Vazio = qualquer profissional (RN-37).
    attribute :professional_ids, {:array, :uuid},
      allow_nil?: false,
      default: [],
      public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :patient, Api.Records.Patient, allow_nil?: false

    has_many :rules, Api.Waitlist.AvailabilityRule
    has_many :holds, Api.Scheduling.SlotHold
  end

  identities do
    # `addFila` faz upsert-por-paciente [:1189]: no máximo um item por paciente. `pre_check?`
    # porque sob RLS o unique_violation vem sem DETAIL (→ 500 sem ele).
    identity :one_entry_per_patient, [:patient_id] do
      pre_check? true
      message "este paciente já está na fila"
    end
  end
end
