defmodule Api.Scheduling.SlotHold do
  @moduledoc """
  Reserva de vaga com TTL (doc 09 §6.2, `04 §7.2`) — o recurso que fecha o **GAP-16**: no
  protótipo, "Oferecer" ([`:2596`](../../../interface/Movimento.dc.html#L2596)) só pré-preenche
  um modal e **nada é reservado** entre oferecer e confirmar, então dois atendentes caem na mesma
  vaga. Aqui `offer` cria um hold de 10 min (D8); a conversão o consome.

  Mora em `Api.Scheduling` (não em `Api.Waitlist`) porque a garantia é a **mesma** do
  agendamento: uma exclusion constraint sobre `(professional_id, tsrange(starts_at, ends_at))`,
  irmã de `appointments_no_overlap`. Recurso por-tenant por atributo (`clinic_id`, ADR-017).

  ## A corrida, e por que o banco é a autoridade (não o `now()` da constraint)

  A constraint `slot_holds_no_overlap` cobre **todos** os holds vivos, **sem** predicado de
  tempo: `now()` é `STABLE`, não `IMMUTABLE`, e o Postgres recusa criar um índice com
  `WHERE expires_at > now()` (doc 09 §6.2, DDL corrigido). A expiração vive na DML: a `offer`
  apaga os vencidos daquele profissional (`PurgeExpired`) **antes** de inserir, na mesma
  transação. Dois atendentes na mesma vaga: o primeiro insere; o segundo, depois da purga, bate
  na constraint e leva `409 slot_held` **imediato** (traduzido no wrapper `Api.Waitlist.offer_slot/3`).

  ## `tsrange`, não `tstzrange`

  Mesma correção de `appointments_no_overlap` (doc 25 §4): `:utc_datetime` do Ash vira
  `timestamp(0) without time zone`, e `tstzrange` exigiria um cast `STABLE` que o índice recusa
  (ERROR 42P17). O Ash garante UTC em toda escrita, então `tsrange` compara os mesmos instantes.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "slot_holds"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # O profissional não pode sumir sob um hold (arquiva, não exclui) — como no agendamento.
      reference :professional, on_delete: :restrict
      # O hold morre com o item da fila (convertido ou removido).
      reference :waitlist_entry, on_delete: :delete
      # Quem segurou. Se o usuário some, o hold some junto (é efêmero, 10 min).
      reference :held_by, on_delete: :delete
    end

    custom_indexes do
      index [:clinic_id, :professional_id, :starts_at]
      # Apoio ao cascade das FKs sem índice sob ADR-017 (mesma razão de `appointments`).
      index [:waitlist_entry_id], all_tenants?: true
      index [:held_by_id], all_tenants?: true
    end

    # Traduz o `exclusion_violation` num erro de campo do Ash (evita o 500 cru do Postgrex; sob
    # RLS o DETAIL vem omitido → `KeyError`). A fronteira o promove a `409 slot_held`: o wrapper
    # `Api.Waitlist.offer_slot/3` reconhece este erro, busca quem segurou e devolve o 409 com meta.
    exclusion_constraint_names [
      {:starts_at, "slot_holds_no_overlap", "Este horário já está reservado."}
    ]
  end

  @slot_held_message "Este horário já está reservado."

  @doc """
  A mensagem exata que a violação de `slot_holds_no_overlap` produz — o identificador que o
  wrapper `Api.Waitlist.offer_slot/3` reconhece para promover ao `409 slot_held` (fonte única,
  como `Appointment.schedule_conflict_message/0`).
  """
  def slot_held_message, do: @slot_held_message

  actions do
    defaults [:read]

    # POST /waitlist/:id/offer — segura a vaga por 10 min. Purga os vencidos do profissional
    # antes de inserir (a garantia da corrida), deriva `ends_at`/`expires_at`, e amarra o autor.
    create :offer do
      primary? true
      accept [:starts_at, :professional_id, :waitlist_entry_id]

      # A vaga tem a duração de varredura do motor (o item de fila não carrega tipo).
      argument :duration_minutos, :integer, default: 50

      # O `professional_id` tem de ser da clínica ativa: a constraint global (ADR-017) faria de
      # um id alheio um vetor cross-tenant (bate-volta E5).
      validate Api.Scheduling.SlotHold.Validations.ProfessionalInClinic

      change Api.Scheduling.SlotHold.Changes.PurgeExpired
      change Api.Scheduling.SlotHold.Changes.ComputeHoldWindow
      change relate_actor(:held_by)
      change Api.Tenancy.SetTenantGuc
    end

    # Libera a vaga (a conversão consome; o backstop Oban limpa o que ninguém consumiu).
    destroy :release do
      primary? true
      require_atomic? false
      change Api.Tenancy.SetTenantGuc
    end
  end

  # Todo membro que agenda pode segurar/liberar vaga (é o mesmo público de `:schedule`).
  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type([:create, :destroy]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao, :profissional], clinic_from: :tenant}
    end
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :starts_at, :utc_datetime, allow_nil?: false, public?: true
    attribute :ends_at, :utc_datetime, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :professional, Api.Directory.Professional, allow_nil?: false
    belongs_to :waitlist_entry, Api.Waitlist.WaitlistEntry, allow_nil?: false
    belongs_to :held_by, Api.Accounts.User, allow_nil?: false
  end
end
