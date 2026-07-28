defmodule Api.Packages.Package do
  @moduledoc """
  O **pacote** — a unidade central de uma clínica de fisioterapia (doc 25/02 §1.5, RN-18…RN-31).
  Um bloco de N sessões vendido a um paciente, materializado como N agendamentos reais na agenda.

  Recurso por-tenant por atributo (`clinic_id`, ADR-017), como `Api.Scheduling`.

  ## O pacote é individual; a sessão pode ser em grupo (revisão 2026-07-24)

  Um pacote pertence a **um** paciente (`patient_id`). A sessão que ele gera pode ser em grupo —
  um pacote de Pilates de 10 sessões, atendidas em turma, onde nem todos os participantes estão
  em pacote. Por isso o vínculo sessão↔pacote **não** mora no `Appointment`, e sim na `Attendance`
  de cada participante (`Attendance.package_id`). A contagem é sempre por participante.

  ## `usadas` é DERIVADO, nunca coluna (RN-28)

  O protótipo mantinha `p.usadas` na mão ([`:326`](../../../../interface/Movimento.dc.html#L326)) e
  dessincronizava. Aqui é um `count` sobre as `Attendance` do pacote que **consomem** sessão:

    * concluída **sempre** consome (RN-29);
    * falta consome **só** se o pacote é punitivo **e** a falta não foi justificada (RN-30/31);
    * prevista/cancelada nunca consomem.

  ## Falta punitiva é do pacote, sem fallback (revisão 2026-07-24)

  `falta_punitiva` é `allow_nil? false` — definida na criação, imutável depois. O antigo padrão
  global de clínica (`clinic.falta_consome_padrao` / `noShowConsome`) foi **removido**: não há para
  onde cair, e o filtro de `usadas` não subconta. A regra foi combinada com o paciente quando o
  pacote foi vendido, e vale por aquele pacote.

  ## O que esta fatia ainda NÃO faz

  Nasce com `create`/`read` e os derivados. A materialização da série (via `Api.Packages.Series` +
  job), o débito ligado às transições, e o pausar/retomar reprojetando vêm nos passos seguintes da
  Frente 5. As ações de ciclo de vida (`:pause`/`:resume`/`:cancel`/`:adjust_grade`/…) entram com
  elas.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Packages,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "packages"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # Paciente com pacote não é apagável — Patient arquiva (como em Attendance).
      reference :patient, on_delete: :restrict
      reference :appointment_type, on_delete: :restrict
    end

    check_constraints do
      check_constraint :total,
        name: "packages_total_positive",
        check: "total > 0",
        message: "O total de sessões precisa ser positivo."

      # O teto também no banco, como o piso: a constraint do atributo protege a entrada da API, e
      # esta protege o dado de qualquer caminho (`Ash.Seed`, script, psql). Ver a nota do atributo.
      check_constraint :total,
        name: "packages_total_max",
        check: "total <= 120",
        message: "O total de sessões passa do máximo (120)."
    end

    custom_indexes do
      index [:clinic_id, :patient_id]
      index [:appointment_type_id], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :nome,
        :total,
        :falta_punitiva,
        :cor,
        :data_inicio,
        :patient_id,
        :appointment_type_id
      ]

      # A grade nasce junto (has_one). `type: :create` porque o pacote e a grade são criados na
      # mesma transação — não existe pacote sem grade.
      argument :grade, :map, allow_nil?: false
      change manage_relationship(:grade, :schedule, type: :create)

      # Enfileira a materialização da série (doc 04 §6). `forcar` vira `encaixe` no job. O
      # `Oban.insert` roda no `after_action`, dentro da transação da criação: não há pacote sem job.
      # `false` (o default) cria o pacote sem materializar — útil para teste do recurso isolado.
      argument :materialize?, :boolean, default: false
      argument :forcar, :boolean, default: false
      change Api.Packages.Package.Changes.EnqueueMaterialization
    end

    # As transições de estado do pacote. Só viram o `status` — o trabalho sobre as sessões
    # (segurar/liberar na agenda) mora nos wrappers do domínio (`Api.Packages`), que orquestram as
    # duas escritas na mesma transação, no molde de `update_clinic_hours`. `require_atomic? false`
    # pelo `SetTenantGuc` (before_action), como as demais escritas do projeto.
    update :mark_paused do
      require_atomic? false
      change set_attribute(:status, :pausado)
    end

    update :mark_active do
      require_atomic? false
      change set_attribute(:status, :ativo)
    end

    update :mark_cancelled do
      require_atomic? false
      change set_attribute(:status, :cancelado)
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

    # A trilha (doc 63). Pausar, cancelar e retomar mudam o que o paciente tem direito a
    # receber. Dano contido em relação aos demais (o pacote é parcialmente reconstituível pelas
    # `Attendance` que ele materializa, que também são auditadas), mas é escrita de negócio e
    # entra pela mesma porta.
    change {Api.Audit.Capture,
            resource: :package,
            label: :nome,
            meta: [:patient_id, :appointment_type_id, :status, :total]},
           on: [:create, :update, :destroy]
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    # Nome do pacote na ficha (ex.: "Pilates 10"). Do `nome` do protótipo.
    attribute :nome, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 120, trim?: true]

    # Total de sessões ÚTEIS (não conta feriado pulado). Editável (+/−) depois, no mesmo registro.
    #
    # O **teto** não é estético: `total` é o que dimensiona as duas operações mais pesadas do
    # sistema — a materialização (N agendamentos criados pelo job) e a massa por pacote (N escritas
    # numa transação única, segurando conexão do pool e os locks da exclusion constraint). Medido
    # depois do hoist do invariante (doc 43 §5a): **16,6 queries por sessão** no caminho de turma.
    # Sem teto, um `500` digitado no lugar de `50` viraria ~8.000 queries e ~15 s de transação —
    # tempo suficiente para estourar o request E fazer quem tentasse agendar aquele profissional
    # esperar na fila. Com 120, o pior caso fica em ~2.000 queries (~2 s local).
    #
    # 120 é decisão de produto, não limite técnico: são 2×/semana por 14 meses. Acima disso, na
    # clínica que este sistema atende, é erro de digitação — e é melhor recusar na entrada do que
    # descobrir no lock.
    attribute :total, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1, max: 120]

    # A punição é do pacote e obrigatória — ver o moduledoc.
    attribute :falta_punitiva, :boolean, allow_nil?: false, public?: true

    # Cor do pacote na agenda/ficha (do `cor` do protótipo).
    attribute :cor, :string, allow_nil?: false, public?: true

    # A data-âncora da série (RN-21). A materialização projeta a partir daqui.
    attribute :data_inicio, :date, allow_nil?: false, public?: true

    attribute :status, Api.Packages.PackageStatus,
      allow_nil?: false,
      default: :ativo,
      public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :patient, Api.Records.Patient, allow_nil?: false
    belongs_to :appointment_type, Api.Directory.AppointmentType, allow_nil?: false

    has_one :schedule, Api.Packages.PackageSchedule

    # A série, por participante (revisão 2026-07-24). Cross-domínio: `Attendance` mora em
    # `Api.Scheduling` e carrega `package_id` sem FK (precedente de `Patient.prefs`), então o
    # vínculo é por `destination_attribute` explícito.
    has_many :attendances, Api.Scheduling.Attendance do
      destination_attribute :package_id
    end
  end

  calculations do
    # `Math.max(0, total - usadas)` de `pkgRemaining` ([`:327`](../../../../interface/Movimento.dc.html#L327)).
    calculate :restantes, :integer, expr(if total - usadas > 0, do: total - usadas, else: 0)

    # "Acabando" = ativo e faltam 1 ou 2 (o aviso da ficha).
    calculate :acabando, :boolean, expr(status == :ativo and restantes > 0 and restantes <= 2)
  end

  aggregates do
    # RN-28: consumo derivado. Conta as attendances que consomem — concluída sempre; falta só se
    # punitiva e não justificada (RN-29/30/31). Sem fallback de clínica (revisão 2026-07-24):
    # `falta_punitiva` é obrigatória, então `parent(falta_punitiva)` é sempre true/false.
    count :usadas, :attendances do
      filter expr(
               status == :concluida or
                 (status == :faltou and falta_justificada == false and
                    parent(falta_punitiva) == true)
             )
    end
  end
end
