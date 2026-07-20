defmodule Api.Scheduling.Appointment do
  @moduledoc """
  O slot da agenda (doc 25 §4) — um bloco de tempo de **um** profissional, com um ou mais
  participantes (`Attendance`). Recurso por-tenant via atributo (`clinic_id`, ADR-017),
  como `AppointmentType` e `Professional`.

  ## Tempo é absoluto aqui (A2)

  `starts_at`/`ends_at` são `:utc_datetime`, divergindo do protótipo (que guarda minuto-do-dia)
  — divergência já registrada em `12:158`. Duas razões: o `tstzrange` da exclusion constraint
  exige instante absoluto, e agendamento é um ponto na linha do tempo. A tradução de/para
  `"HH:MM"` local mora em `Api.Scheduling.LocalTime`, único lugar que conhece o fuso da clínica.

  ## A não-sobreposição é do banco, não daqui (A5)

  `appointments_no_overlap` é uma **exclusion constraint** (`EXCLUDE USING gist`), não uma
  validação: o cenário real são dois recepcionistas no mesmo slot, e só o banco resolve corrida
  (`04:7.1`). A pré-checagem de `Api.Scheduling.Conflicts` existe para **explicar** o conflito
  no formulário, não para garanti-lo — há janela TOCTOU entre checar e inserir.

  O predicado parcial da constraint (`WHERE encaixe = false AND status <> 'cancelado'`)
  implementa RN-12 (encaixe imune nos dois sentidos) e RN-13 (cancelado não conflita) **no
  próprio banco**, e o `'[)'` do range implementa "encostar fim-com-início não é conflito"
  (protótipo [`:832`]). `exclusion_constraint_names` abaixo é o que impede a violação de virar
  500: sem ela o Postgrex sobe cru e, sob RLS, o Postgres ainda **omite o DETAIL** — foi assim
  que o AshPostgres estourou `KeyError` duas vezes neste projeto.

  ## Ganchos que nascem sem UI

  `package_id`, `pkg_hold` e `version` entram agora porque mudam tabela depois (doc 25 §0):
  pacote é a Fatia 3, locking otimista é a Entrega 4. `package_id` é `:uuid` **sem FK**, no
  precedente de `Patient.prefs`.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource],
    # RN-56: as mutações viram evento de tempo real. Fica só no `Appointment` — `:add_participant`
    # também cria `Attendance`, e um notifier lá em cima emitiria o mesmo evento duas vezes.
    notifiers: [Api.Scheduling.AgendaNotifier]

  postgres do
    table "appointments"
    repo Api.Repo

    references do
      # O tenant é a clínica; sem ela o agendamento não existe.
      reference :clinic, on_delete: :delete
      # Profissional e tipo NÃO podem sumir sob um agendamento — é por isso que ambos
      # arquivam em vez de excluir (T2 / fatia Profissionais).
      reference :professional, on_delete: :restrict
      reference :appointment_type, on_delete: :restrict
    end

    custom_indexes do
      # ADR-017: `clinic_id` lidera todo índice de recurso por-tenant.
      index [:clinic_id, :professional_id, :starts_at]
      index [:clinic_id, :starts_at]
      # Gancho da Fatia 3; barato agora, caro de adicionar com a tabela cheia.
      index [:package_id]

      # Achado (h) do doc 26: FK sem índice faz o Postgres varrer `appointments` inteira a cada
      # DELETE do lado apontado, para checar se alguma linha ainda referencia. Tipo e
      # profissional **arquivam** em vez de excluir, o que atenua — mas `users` não tem essa
      # proteção, e um usuário removido varreria a tabela por causa de `created_by_id`.
      #
      # `all_tenants? true` é obrigatório aqui, e é a diferença entre resolver e fingir que
      # resolveu: sem ele o ADR-017 prefixa `clinic_id`, e um índice `(clinic_id, X)` NÃO serve
      # a `WHERE X = $1` — que é exatamente a forma da checagem de FK, feita pelo Postgres sem
      # nenhuma noção de tenant. O índice sairia, o gargalo ficaria.
      index [:appointment_type_id], all_tenants?: true
      index [:created_by_id], all_tenants?: true
    end

    # Traduz `exclusion_violation` da constraint num erro de campo do Ash (→ 422), em vez de
    # deixar o Postgrex subir cru (→ 500). O campo escolhido é `starts_at` por exigência do
    # Ecto (a violação precisa de uma chave), mas a fronteira HTTP **apaga** esse campo e
    # devolve `field: null` com `code: "schedule_conflict"` — pintar `starts_at` de vermelho
    # mentiria, o horário está certo, o mundo é que está ocupado (A10, `09:605`).
    exclusion_constraint_names [
      {:starts_at, "appointments_no_overlap", "Esse horário sobrepõe outro agendamento."}
    ]
  end

  @schedule_conflict_message "Esse horário sobrepõe outro agendamento."

  @doc """
  A mensagem exata que a violação de `appointments_no_overlap` produz.

  Existe como função, e não como string solta, porque a fronteira HTTP precisa **reconhecer**
  esse erro para promovê-lo ao `code: "schedule_conflict"` com `field: null` (A10). O Ecto só
  nos deixa configurar a mensagem, não um código — então ela é o identificador, e ter uma
  fonte única impede que editar o texto quebre o contrato silenciosamente.
  """
  def schedule_conflict_message, do: @schedule_conflict_message

  # A trilha (A-D6c, doc 25 §11). `:changes_only` e não o default `:snapshot`: snapshot grava
  # o registro inteiro a cada escrita, e com o `obs` isso multiplicaria dado potencialmente
  # clínico pelo número de edições (A-D13).
  paper_trail do
    change_tracking_mode :changes_only
    store_action_name? true
    # Guardaria os inputs da ação — incluindo `obs` — numa segunda coluna. Ver a nota de
    # retenção em doc 25 §11.3.
    store_action_inputs? false
    ignore_attributes [:inserted_at, :updated_at]

    # `clinic_id` PRECISA ser coluna real na tabela de versões: é o que a RLS filtra. Sem
    # isto ele ficaria enterrado no mapa `changes` e a tabela de versões seria um buraco por
    # fora do isolamento por clínica — com o histórico inteiro dentro (doc 25 §11.2).
    attributes_as_attributes [:clinic_id, :professional_id, :starts_at, :status]

    belongs_to_actor :user, Api.Accounts.User, domain: Api.Accounts

    # O recurso de versão nasceria SEM authorizer — e `authorize?: true` sobre ele seria um
    # no-op, a porta dos fundos da A7. As duas opções abaixo são do DSL do AshPaperTrail:
    # `version_extensions` injeta o authorizer no `use Ash.Resource` gerado, `mixin` injeta as
    # policies no corpo dele (ler é owner·admin; escrever, ninguém). Ver
    # `Api.Scheduling.TrailPolicies`.
    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin Api.Scheduling.TrailPolicies

    # Achado (c) do doc 26: com a FK padrão (`version_source_id` → `appointments`, sem
    # `ON DELETE`), apagar um agendamento estourava
    # `violates foreign key constraint "appointments_versions_version_source_id_fkey"` — a
    # trilha tornava o agendamento **indeletável**. Não morde na Entrega 1 (não há destroy, por
    # decisão), mas é o mecanismo concreto pelo qual um pedido de exclusão não se resolve.
    #
    # `false` é a saída que o próprio AshPaperTrail documenta para "allowing actual deletion of
    # data", e é a que preserva o histórico: a versão sobrevive órfã em vez de ser levada junto
    # por um cascade. Trilha que some quando o registro some não é trilha — e o doc 26 §6
    # registra um apagamento acidental de linhas de versão justamente para não repetir isso.
    reference_source? false
  end

  actions do
    defaults [:read]

    @doc """
    Agendamentos num intervalo absoluto. O intervalo vem do controller já convertido para UTC
    (a partir da data local pedida), porque só o controller conhece o fuso da clínica.
    """
    read :in_range do
      argument :from, :utc_datetime, allow_nil?: false
      argument :to, :utc_datetime, allow_nil?: false
      argument :professional_ids, {:array, :uuid}

      # Sobreposição com a janela, não contenção: um bloco que começa 07:50 e termina 08:40
      # pertence ao dia pedido mesmo que a janela comece 08:00.
      filter expr(starts_at < ^arg(:to) and ends_at > ^arg(:from))

      filter expr(
               is_nil(^arg(:professional_ids)) or
                 professional_id in ^arg(:professional_ids)
             )

      prepare build(sort: [starts_at: :asc])
    end

    create :schedule do
      primary? true
      accept [:starts_at, :professional_id, :appointment_type_id, :obs, :duration_minutos]

      argument :patient_ids, {:array, :uuid}, allow_nil?: false
      # `encaixe` é argumento e não atributo aceito porque quem pode marcá-lo é decidido por
      # policy (A9, abaixo): `owner`·`admin`·`recepcao` sim, `profissional` não — e é o
      # argumento (não o atributo) que a policy julga, porque só ele existe antes dos changes.
      argument :encaixe, :boolean, default: false

      # Paciente de outra clínica não vira participante desta agenda.
      validate Api.Scheduling.Appointment.Validations.PatientsInClinic
      validate Api.Scheduling.Appointment.Validations.PatientsActive

      # Tipo arquivado / profissional inativo (doc 25 §7). Só aqui: o passado não é revalidado.
      validate Api.Scheduling.Appointment.Validations.ReferencesActive
      validate Api.Scheduling.Appointment.Validations.GroupCapacity

      change set_attribute(:encaixe, arg(:encaixe))
      change Api.Scheduling.Appointment.Changes.ComputeEndsAt
      change Api.Scheduling.Appointment.Changes.CheckAvailability

      change manage_relationship(:patient_ids, :attendances,
               type: :create,
               value_is_key: :patient_id
             )
    end

    # Acrescenta participantes a uma turma que já existe — o outro lado do merge (A-D4).
    #
    # É para cá que `Api.Scheduling.schedule_appointment/2` delega quando acha turma
    # coincidente, e é por isso que o teto de capacidade mora numa validação compartilhada com
    # `:schedule`: um caminho só, em vez do teto validado na criação e furado na fusão (o bug
    # do protótipo).
    #
    # Não toca em `starts_at`, `ends_at` nem `encaixe`: entrar numa turma não remarca nem
    # reclassifica o bloco de ninguém.
    update :add_participant do
      # `SetTenantGuc` é `before_action`, e hook de before_action é incompatível com update
      # atômico — mesma razão de `archive`/`restore` em `AppointmentType`.
      require_atomic? false

      argument :patient_ids, {:array, :uuid}, allow_nil?: false

      # `encaixe` aqui **só fura o teto** (A-D3); de propósito não vira atributo. Marcar a
      # turma inteira como encaixe por causa de um participante extra a isentaria da exclusion
      # constraint — trocaria um limite operacional por um buraco na garantia de A5.
      argument :encaixe, :boolean, default: false

      validate Api.Scheduling.Appointment.Validations.PatientsInClinic
      validate Api.Scheduling.Appointment.Validations.PatientsActive
      validate Api.Scheduling.Appointment.Validations.GroupCapacity

      change manage_relationship(:patient_ids, :attendances,
               type: :create,
               value_is_key: :patient_id
             )
    end
  end

  policies do
    # A7/D1: todo membro lê, mas o `profissional` só enxerga a própria agenda — e o
    # FilterCheck FECHA (lista vazia) quando o membro é profissional sem `professional_id`,
    # em vez de degradar para "sem filtro". `Membership.professional_id` é `allow_nil? true`
    # ("UUID mole"), então esse caso existe de verdade.
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    # A8: recepção é quem agenda — o par admin/membro de hoje não serve.
    #
    # As três policies de escrita nomeiam as ações em vez de casar por `action_type`: desde o
    # merge (A-D4), agendar é `:schedule` **ou** `:add_participant`, e a segunda é um
    # `update`. Casar por tipo deixaria o caminho da fusão sem policy nenhuma — e ação sem
    # policy é ação proibida, ou seja, o merge nasceria morto e o erro apareceria como 403.
    policy action([:schedule, :add_participant]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao, :profissional], clinic_from: :tenant}
    end

    # A7 **na escrita**. As policies do Ash são AND entre si: esta só se aplica quando o actor
    # é `profissional`, e então exige a própria coluna. Sem ela o profissional não conseguia
    # LER a agenda do colega mas escrevia nela às cegas, mandando outro `professional_id`.
    policy [
      action([:schedule, :add_participant]),
      {Api.Accounts.Checks.HasClinicRole, roles: [:profissional], clinic_from: :tenant}
    ] do
      authorize_if Api.Scheduling.Appointment.Checks.OwnProfessionalColumn
    end

    # A9: encaixe é de recepção para cima. `encaixe = true` isenta a linha da exclusion
    # constraint (A5) — sem esta policy, o papel menos privilegiado desligava a proteção
    # contra dupla-marcação mandando um booleano no corpo.
    # Em `:add_participant` o mesmo argumento fura o teto da turma (A-D3) em vez de isentar a
    # constraint — e a decisão de quem pode furar um limite combinado é a mesma.
    policy [
      action([:schedule, :add_participant]),
      Api.Scheduling.Appointment.Checks.CreatingEncaixe
    ] do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao], clinic_from: :tenant}
    end
  end

  preparations do
    # RN-05: sessão "segurada" por pacote não é agendamento visível. Filtrar aqui, e não em
    # cada leitor, é o que garante o "some de tudo".
    prepare build(filter: [pkg_hold: false])

    # A7 na prática: recorta as linhas quando o actor é `profissional`.
    prepare Api.Scheduling.Preparations.OwnAgendaOnly
  end

  changes do
    change Api.Tenancy.SetTenantGuc
    # A-D6: coluna denormalizada para exibir "criado por" sem consultar a trilha. A trilha
    # continua sendo a autoridade sobre o histórico.
    change relate_actor(:created_by, allow_nil?: true), on: [:create]
  end

  validations do
    validate present(:starts_at)
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :starts_at, :utc_datetime, allow_nil?: false, public?: true
    attribute :ends_at, :utc_datetime, allow_nil?: false, public?: true

    attribute :status, Api.Scheduling.AppointmentStatus,
      allow_nil?: false,
      default: :agendado,
      public?: true

    # Predicado da exclusion constraint: encaixe não conflita e não é conflitado (RN-12).
    attribute :encaixe, :boolean, allow_nil?: false, default: false, public?: true

    # A-D7: "vem de muleta", "trazer exame". PODE conter dado clínico — não é prontuário
    # (ADR-013/D16), e a UI diz isso no placeholder.
    attribute :obs, :string, public?: true, constraints: [max_length: 500]

    # A-D8: sobrepõe o snapshot de `AppointmentType.duracao_minutos` quando presente. Sem
    # isto, "esta sessão vai demorar mais" obrigaria a criar um tipo novo e poluir o catálogo.
    attribute :duration_minutos, :integer, public?: true, constraints: [min: 5, max: 480]

    attribute :cancel_reason, :string, public?: true, constraints: [max_length: 300]

    # Locking otimista — consumido só na Entrega 4, mas a coluna nasce agora.
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true

    # Ganchos da Fatia 3 (pacotes). `package_id` sem FK, precedente de `Patient.prefs`.
    attribute :package_id, :uuid, public?: true
    attribute :pkg_hold, :boolean, allow_nil?: false, default: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :professional, Api.Directory.Professional, allow_nil?: false
    belongs_to :appointment_type, Api.Directory.AppointmentType, allow_nil?: false

    # Quem criou. Nullable porque seed/onboard escrevem sem actor.
    belongs_to :created_by, Api.Accounts.User

    has_many :attendances, Api.Scheduling.Attendance
  end
end
