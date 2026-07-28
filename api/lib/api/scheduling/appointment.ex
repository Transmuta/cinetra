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

  `pkg_hold` e `version` entram agora porque mudam tabela depois (doc 25 §0): pacote é a Fatia 3,
  locking otimista é a Entrega 4.

  Havia aqui um terceiro gancho, `package_id`, e ele **não existe mais** (Onda 5): a A2 decidiu
  que pacote é por **participante** (D11 — não existe pacote de turma), o vínculo passou a nascer
  na `Attendance`, e esta coluna ficou 0 de 10.212 linhas. Quem quiser sinalizar "este bloco vem
  de pacote" deriva de `participants`, que é onde o dado está.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource],
    # RN-56: as mutações viram evento de tempo real. Fica só no `Appointment` — `:add_participant`
    # também cria `Attendance`, e um notifier lá em cima emitiria o mesmo evento duas vezes.
    notifiers: [
      Api.Scheduling.AgendaNotifier,
      Api.Notifications.Notifier,
      # Doc 52 §7: agendamento criado → confirmação ao paciente, pós-commit e best-effort.
      Api.Messaging.Notifier
    ]

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

      # H64 (Onda 5): era `NO ACTION` por **omissão**, não por escolha — e omissão aqui significa
      # "nenhum usuário que já criou um agendamento pode ser apagado", que é exatamente o que a
      # eliminação da LGPD (F8) precisará fazer. `created_by` é autoria, não parte do dado: o
      # bloco sobrevive sem ele, e quem criou continua na trilha do AshPaperTrail.
      reference :created_by, on_delete: :nilify
    end

    # A duração positiva era invariante só de APLICAÇÃO: `ComputeEndsAt` deriva `ends_at` da
    # duração, e as duas fontes têm `min: 5` (`duration_minutos` aqui, `duracao_minutos` no tipo).
    # Nada disso alcança quem escreve por fora da ação — `Ash.Seed`, um seed, um `INSERT` de
    # manutenção — e um bloco degenerado (`ends_at == starts_at`) é invisível: some de toda leitura
    # que use sobreposição de range (`tsrange(s, s, '[)')` é o range VAZIO, e vazio não sobrepõe
    # nada), sem erro nenhum. Achado do bate-volta desta leva: hoje há 0 linhas assim, e é
    # exatamente por isso que a hora de fechar a porta é agora, com a tabela limpa.
    check_constraints do
      check_constraint :ends_at,
        name: "appointments_ends_after_starts",
        check: "ends_at > starts_at",
        message: "A duração precisa ser positiva."

      # O teto (A2, doc 36 §6.2) é o irmão do CHECK acima, e existe pelo motivo oposto: não é a
      # leitura que some por dado degenerado, é a leitura que passou a **depender** do teto. O
      # `:in_range` corta a varredura em `starts_at > from − 8h` (ver
      # `Preparations.WindowLowerBound`), corte só válido enquanto nenhum bloco durar mais que
      # isso. Como `max: 480` nas duas fontes de duração é invariante de aplicação, sem este CHECK
      # bastaria um `INSERT` de manutenção com 10h para produzir um agendamento que existe no
      # banco e não aparece na agenda.
      check_constraint :ends_at,
        name: "appointments_duration_within_cap",
        check:
          "ends_at <= starts_at + interval '#{Api.Scheduling.Duration.max_minutos()} minutes'",
        message: "A duração não pode passar de 8 horas."
    end

    custom_indexes do
      # ADR-017: `clinic_id` lidera todo índice de recurso por-tenant.
      index [:clinic_id, :professional_id, :starts_at]
      index [:clinic_id, :starts_at]
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

      # Mesma classe do achado acima, para `professional_id` (D-F, doc 30). O composto
      # `(clinic_id, professional_id, starts_at)` lidera por `clinic_id` e não serve a um
      # `WHERE professional_id = $1` puro; o gist da exclusion (`appointments_no_overlap`) é
      # parcial. Atenuado — profissional **arquiva** em vez de excluir, então a checagem de FK
      # do DELETE quase nunca dispara — mas o btree dedicado é barato e fecha o buraco.
      index [:professional_id], all_tenants?: true
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

    # `on_delete: :nilify` (H64, Onda 5): o default do AshPaperTrail é `:nothing`, que faz a
    # trilha **travar** o `DELETE` do usuário — a versão guarda quem mexeu, e é justamente o
    # registro que a eliminação da LGPD (F8) precisará apagar. Perder o vínculo com o ator não
    # apaga a versão: o diff continua lá, só sem o `belongs_to` resolvendo o nome.
    belongs_to_actor :user, Api.Accounts.User, domain: Api.Accounts, on_delete: :nilify

    # O recurso de versão nasceria SEM authorizer — e `authorize?: true` sobre ele seria um
    # no-op, a porta dos fundos da A7. As duas opções abaixo são do DSL do AshPaperTrail:
    # `version_extensions` injeta o authorizer no `use Ash.Resource` gerado, `mixin` injeta no
    # corpo dele as policies (ler é owner·admin; escrever, ninguém) E a leitura paginada
    # `:audit_log` da tela de auditoria (§11.4). Ver `Api.Scheduling.TrailMixin`.
    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin Api.Scheduling.TrailMixin

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

      # Fecha a varredura por baixo (A2). Não muda o resultado — só o plano. Ver o moduledoc.
      prepare Api.Scheduling.Preparations.WindowLowerBound

      # `id` desempata: `starts_at` repete muito (turma, mesmo horário em profissionais
      # diferentes), e sem desempate a ordem entre empatados é indefinida — o que além de
      # instável quebraria o keyset, que precisa de um cursor total para não pular nem repetir
      # linha na fronteira da página.
      prepare build(sort: [starts_at: :asc, id: :asc])

      # D-C (doc 30): hoje a janela é limitada pelo teto de 31 dias do controller (~2.5k linhas),
      # mas a Fatia 3 (Pacotes) reusa este mesmo read com janelas bem maiores. `required?: false`
      # de propósito: quem não passa `page:` continua recebendo a lista inteira (a agenda do dia
      # renderiza tudo), então nada muda para os chamadores atuais — a paginação fica disponível
      # para quem precisar. O keyset é o que habilita `Ash.stream!` sobre esta ação, que é a
      # forma de a série de pacote varrer muitos agendamentos sem carregar todos na memória.
      pagination offset?: true,
                 keyset?: true,
                 required?: false,
                 default_limit: 100,
                 max_page_size: 1000
    end

    create :schedule do
      primary? true
      accept [:starts_at, :professional_id, :appointment_type_id, :obs, :duration_minutos]

      argument :patient_ids, {:array, :uuid}, allow_nil?: false
      # `encaixe` é argumento e não atributo aceito porque quem pode marcá-lo é decidido por
      # policy (A9, abaixo): `owner`·`admin`·`recepcao` sim, `profissional` não — e é o
      # argumento (não o atributo) que a policy julga, porque só ele existe antes dos changes.
      argument :encaixe, :boolean, default: false

      # O pacote que origina a sessão (doc 41 etapa 2). Nulo = sessão avulsa/particular. Carimba a
      # presença na mesma escrita, em vez do `set_package` de fora que a materialização fazia.
      argument :package_id, :uuid

      # Paciente de outra clínica não vira participante desta agenda.
      validate Api.Scheduling.Appointment.Validations.PatientsInClinic
      validate Api.Scheduling.Appointment.Validations.PatientsActive
      validate Api.Scheduling.Appointment.Validations.PackageBelongsToPatient

      # Tipo arquivado / profissional inativo (doc 25 §7). Só aqui: o passado não é revalidado.
      validate Api.Scheduling.Appointment.Validations.ReferencesActive
      validate Api.Scheduling.Appointment.Validations.GroupCapacity

      change set_attribute(:encaixe, arg(:encaixe))
      change Api.Scheduling.Appointment.Changes.ComputeEndsAt
      change Api.Scheduling.Appointment.Changes.CheckAvailability

      change Api.Scheduling.Appointment.Changes.ManageParticipants
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

      # Idem `:schedule` — é por aqui que a série de um pacote entra numa turma que já existe
      # (o caso comum do Pilates), carimbando só a presença que entrou.
      argument :package_id, :uuid

      validate Api.Scheduling.Appointment.Validations.PatientsInClinic
      validate Api.Scheduling.Appointment.Validations.PatientsActive
      validate Api.Scheduling.Appointment.Validations.PackageBelongsToPatient
      validate Api.Scheduling.Appointment.Validations.GroupCapacity

      change Api.Scheduling.Appointment.Changes.ManageParticipants
    end

    # O outro lado do `:add_participant` (doc 41 etapa 3, contrato 09 §3.1.1 ponto 3): tira um
    # participante sem tocar nos colegas. É o que a massa por pacote precisa — cancelar o bloco
    # cancelaria a sessão de todo mundo, que é o bug que o `pkgOf` do protótipo produzia.
    #
    # A escrita é ancorada no BLOCO (e não um destroy solto na `Attendance`) por três razões: as
    # policies A7/A8 já moram aqui; a `version` bumpa, invalidando o cliente que tinha a
    # composição antiga; e o `AgendaNotifier` só escuta o `Appointment` — é daqui que sai o
    # `participant_removed` do contrato de wire.
    update :remove_participant do
      require_atomic? false

      argument :patient_ids, {:array, :uuid}, allow_nil?: false

      change Api.Scheduling.Appointment.Changes.RemoveParticipants
      change Api.Scheduling.Appointment.Changes.BumpVersion
    end

    # ---- Ciclo de vida (Entrega 4, doc 25 §9 / §8d) ----
    #
    # Ações **nomeadas**, nunca `PATCH` de `status` (doc 25 §3): a intenção — remarcou,
    # concluiu, faltou, cancelou, reabriu — é o que a trilha (`store_action_name?`) grava e o que
    # o cliente casa no evento de tempo real. Todas `require_atomic? false` porque `SetTenantGuc`
    # é `before_action` (mesma razão de `archive`/`deactivate` no diretório), e todas avançam o
    # `version` (locking otimista, guard de 409 no wrapper do domínio).

    # Remarca o bloco (arraste e modal). GAP-03 corrigido (D-E4.3): valida expediente igual ao
    # formulário — o protótipo só validava sobreposição no arraste. A não-sobreposição continua
    # sendo do banco (exclusion constraint); "Mover como encaixe" manda `encaixe: true`.
    update :reschedule do
      require_atomic? false
      accept [:starts_at, :professional_id]
      argument :encaixe, :boolean

      # Remarcar ESCOLHE profissional (a ação aceita `professional_id`), então vale a mesma
      # pergunta de `:schedule` — e só ela: o tipo vem do bloco que já existe, e checá-lo aqui
      # quebraria o §7 ("existente continua válido"). Ver o moduledoc de `ReferencesActive`.
      validate {Api.Scheduling.Appointment.Validations.ReferencesActive, only: [:profissional]}

      change Api.Scheduling.Appointment.Changes.SetEncaixeIfGiven
      change Api.Scheduling.Appointment.Changes.ShiftEndsAt
      change Api.Scheduling.Appointment.Changes.CheckAvailability
      change Api.Scheduling.Appointment.Changes.BumpVersion

      # A presença carrega uma cópia do horário do bloco (doc 43 §4) — remarcar move as duas.
      change Api.Scheduling.Appointment.Changes.SyncSessionStartsAt
    end

    # Cancelar preserva o registro (doc 25 §3, "sem hard delete"). Motivo opcional (D4).
    # Segura/solta uma sessão de pacote (RN-05/RN-23). `pkg_hold: true` a tira da agenda (o
    # `prepare build(filter: [pkg_hold: false])` do `:in_range`); `false` a devolve. Não mexe em
    # status nem em `version`: pausar não é cancelar, e a presença segue `:prevista`. Chamada pela
    # pausa/retomada do pacote (`Api.Packages`), com `authorize?: false` (o domínio já autorizou).
    update :set_pkg_hold do
      require_atomic? false
      accept [:pkg_hold]
    end

    update :cancel do
      require_atomic? false

      # Cancela-se um bloco aberto (inclusive futuro); um já-concluído/faltou/cancelado não (F4).
      validate {Api.Scheduling.Appointment.Validations.StatusIn,
                from: Api.Scheduling.AppointmentStatus.abertos()}

      accept [:cancel_reason]
      change set_attribute(:status, :cancelado)
      change {Api.Scheduling.Appointment.Changes.CascadeToAttendances, status: :cancelada}
      change Api.Scheduling.Appointment.Changes.BumpVersion
    end

    # Reabrir → agendado (D-E4.2): desfaz um clique errado. Zera `falta_justificada` e devolve
    # as presenças a `:prevista`, então o agregado de faltas do paciente recua junto.
    update :reopen do
      require_atomic? false
      # Só reabre o que está FECHADO (F4): reabrir um já-agendado era no-op que ainda bumpava a
      # versão e escrevia "reabriu" na trilha.
      validate {Api.Scheduling.Appointment.Validations.StatusIn,
                from: [:concluido, :faltou, :cancelado]}

      change set_attribute(:status, :agendado)
      change set_attribute(:cancel_reason, nil)

      change {Api.Scheduling.Appointment.Changes.CascadeToAttendances,
              status: :prevista, reset_justificada?: true}

      change Api.Scheduling.Appointment.Changes.BumpVersion
    end

    # Rollup do desfecho a partir das presenças (Frente 6/A2, doc 41). Interna: só a
    # `Attendance.Changes.RollupBlockStatus` a chama (`authorize?: false`), depois de uma
    # transição de presença. Sempre bumpa a `version` — mexer numa presença é mexer no bloco —, o
    # que também dispara o `AgendaNotifier`. Não passa por `SessionStarted`/`StatusIn`: o gate é
    # da presença; o bloco só reflete.
    update :apply_participant_rollup do
      require_atomic? false
      accept [:status]
      change Api.Scheduling.Appointment.Changes.BumpVersion
    end

    # Excluir (soft-delete, doc 40): tira da vista um lançamento feito por engano. Só o que
    # **não aconteceu** — `agendado`/`confirmado`/`cancelado`; `concluido`/`faltou`/`em_atendimento`
    # não, porque debitam pacote e cascatearam presença (para desfazer um "faltou" errado o
    # caminho é reabrir → excluir). NÃO cascateia para as presenças: elas são `:prevista` ou
    # `:cancelada` nesses três status, nunca `:faltou`, então nunca alimentaram o agregado
    # `Patient.faltas` — e o bloco sai das leituras levando-as junto (só acessíveis por ele).
    update :exclude do
      require_atomic? false

      validate {Api.Scheduling.Appointment.Validations.StatusIn,
                from: [:agendado, :confirmado, :cancelado]}

      change Api.Scheduling.Appointment.Changes.StampExcludedAt
      change Api.Scheduling.Appointment.Changes.BumpVersion
    end
  end

  # As ações de escrita, para as policies abaixo não repetirem a lista.
  @write_actions [
    :schedule,
    :add_participant,
    :remove_participant,
    :reschedule,
    :cancel,
    :reopen,
    :exclude
  ]
  # Onde `encaixe` pode ser marcado — os únicos caminhos que a A9 precisa guardar.
  @encaixe_actions [:schedule, :add_participant, :reschedule]

  policies do
    # A7/D1: todo membro lê, mas o `profissional` só enxerga a própria agenda — e o
    # FilterCheck FECHA (lista vazia) quando o membro é profissional sem `professional_id`,
    # em vez de degradar para "sem filtro". `Membership.professional_id` é `allow_nil? true`
    # ("UUID mole"), então esse caso existe de verdade.
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    # A8: recepção é quem agenda — o par admin/membro de hoje não serve. A lista `@write_actions`
    # cobre o merge (A-D4, `:add_participant`) e todo o ciclo de vida da Entrega 4: casar por
    # `action_type` deixaria alguma delas sem policy, e ação sem policy é ação proibida (403).
    policy action(@write_actions) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao, :profissional], clinic_from: :tenant}
    end

    # A7 **na escrita**. As policies do Ash são AND entre si: esta só se aplica quando o actor
    # é `profissional`, e então exige a própria coluna. Sem ela o profissional não conseguia
    # LER a agenda do colega mas escrevia nela às cegas, mandando outro `professional_id`.
    # Vale para todo o ciclo de vida: nas transições de status o `professional_id` não muda
    # (o check lê o valor atual do bloco, que já é o dele), e na remarcação impede mover o
    # bloco para a coluna de um colega.
    policy [
      action(@write_actions),
      {Api.Accounts.Checks.HasClinicRole, roles: [:profissional], clinic_from: :tenant}
    ] do
      authorize_if Api.Scheduling.Appointment.Checks.OwnProfessionalColumn
    end

    # A9: encaixe é de recepção para cima. `encaixe = true` isenta a linha da exclusion
    # constraint (A5) — sem esta policy, o papel menos privilegiado desligava a proteção
    # contra dupla-marcação mandando um booleano no corpo.
    # Em `:add_participant` o mesmo argumento fura o teto da turma (A-D3); na remarcação volta a
    # isentar a constraint. A decisão de quem pode furar um limite combinado é a mesma.
    policy [
      action(@encaixe_actions),
      Api.Scheduling.Appointment.Checks.CreatingEncaixe
    ] do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao], clinic_from: :tenant}
    end
  end

  preparations do
    # RN-05: sessão "segurada" por pacote não é agendamento visível. Filtrar aqui, e não em cada
    # leitor, é o que garante o "some de tudo". Condicional (módulo, não `build(filter:)`) porque a
    # retomada do pacote precisa reler as próprias seguradas — ver `HideHeld`.
    prepare Api.Scheduling.Preparations.HideHeld

    # Soft-delete (doc 40): o excluído some de TODA leitura num lugar só — agenda, relatório,
    # `SlotFinder`, releitura do canal. Um `prepare` global (não um filtro por leitor) é o que
    # impede uma query nova de vazar o excluído. `SlotFinder` lê com `authorize?: false`, mas
    # preparations não são policies — rodam sempre, então o corte vale lá também. Módulo (não
    # `build(filter: [excluded_at: nil])`) porque o keyword vira `= NULL` e zera a leitura — ver
    # o moduledoc de `HideExcluded`.
    prepare Api.Scheduling.Preparations.HideExcluded

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
    # O teto vem de `Api.Scheduling.Duration` — a leitura depende dele (A2), não é limite de tela.
    attribute :duration_minutos, :integer,
      public?: true,
      constraints: [min: 5, max: Api.Scheduling.Duration.max_minutos()]

    attribute :cancel_reason, :string, public?: true, constraints: [max_length: 300]

    # Locking otimista — consumido só na Entrega 4, mas a coluna nasce agora.
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true

    attribute :pkg_hold, :boolean, allow_nil?: false, default: false, public?: true

    # Soft-delete (doc 40): exclusão de lançamento feito por engano. Marca a hora e o registro
    # SOME de toda leitura (o `prepare` de `excluded_at IS NULL` abaixo), mas a linha e a trilha
    # ficam — distinto de cancelar (que aconteceu e conta no relatório). Uma coluna, não um 7º
    # status: o predicado da `appointments_no_overlap` também ganha `AND excluded_at IS NULL`
    # (migration), então o horário de um bloco excluído volta a ser agendável.
    attribute :excluded_at, :utc_datetime, public?: true

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
