defmodule Api.Scheduling.Attendance do
  @moduledoc """
  Presença de **um participante** num agendamento (doc 25 §4, D10/D11).

  É a peça que o protótipo não tem e que fecha o GAP-07 — *"a lacuna mais séria"* (`02:570`).
  Lá, a relação agendamento↔paciente vive no array `patientIds` e o vínculo com pacote num
  mapa `pkgOf` mantido à mão; presença individual numa turma simplesmente não é representável.
  Aqui cada participante tem status próprio: o bloco pode estar `:concluido` enquanto um
  participante `:faltou`.

  Nasce nesta fatia **sem UI de status** (a Entrega 4 é que mexe nas transições) porque sem ela
  a Fatia 3 teria de refazer a agenda inteira.

  `package_id` é por **participante**, não do agendamento (D11): não existe "pacote de turma" —
  cada paciente consome do seu.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource],
    # Só o da caixa de notificações, e só para a falta por participante (#46, doc 41 etapa 5): o
    # `AgendaNotifier` continua **fora** daqui de propósito, senão o evento de tempo real sairia
    # duas vezes (a presença muda e o rollup escreve o bloco). Ver o moduledoc do `Appointment`.
    notifiers: [Api.Notifications.Notifier]

  postgres do
    table "attendances"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # Sair da turma é destruir a `Attendance`; o bloco sumindo leva as suas junto.
      reference :appointment, on_delete: :delete
      # Paciente com histórico não é apagável — por isso `Patient` arquiva.
      reference :patient, on_delete: :restrict
    end

    custom_indexes do
      index [:clinic_id, :appointment_id]
      # A-D5 (avisar sobre paciente em dois lugares) e o agregado `Patient.faltas` leem por
      # paciente; sem este índice as duas viram seq scan.
      index [:clinic_id, :patient_id]
      index [:package_id]
    end
  end

  # A-D14: a trilha cobre `Appointment` **e** `Attendance`. Sem esta, "quem tirou o paciente
  # da turma?" fica sem resposta — adicionar/remover participante é escrita aqui, não lá.
  paper_trail do
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? false
    ignore_attributes [:inserted_at, :updated_at]
    attributes_as_attributes [:clinic_id, :appointment_id, :patient_id, :status]
    belongs_to_actor :user, Api.Accounts.User, domain: Api.Accounts

    # O recurso de versão nasceria SEM authorizer — e `authorize?: true` sobre ele seria um
    # no-op, a porta dos fundos da A7. As duas opções abaixo são do DSL do AshPaperTrail:
    # `version_extensions` injeta o authorizer no `use Ash.Resource` gerado, `mixin` injeta no
    # corpo dele as policies (ler é owner·admin; escrever, ninguém) E a leitura paginada
    # `:audit_log` da tela de auditoria (§11.4). Ver `Api.Scheduling.TrailMixin`.
    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin Api.Scheduling.TrailMixin

    # Mesmo motivo do `Appointment` (achado (c) do doc 26) — e aqui é ainda mais direto: a FK
    # de `attendances_versions` foi a que estourou de verdade ao limpar o banco. A trilha
    # sobrevive órfã em vez de bloquear a exclusão ou ser levada junto.
    reference_source? false
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      # `package_id` entra aqui (doc 41 etapa 2) porque quem cria a presença é o
      # `manage_relationship` do bloco (`Changes.ManageParticipants`): o vínculo com o pacote nasce
      # com ela, em vez de um `set_package` numa segunda escrita.
      accept [:patient_id, :appointment_id, :package_id]
    end

    # A presença acompanha o ciclo de vida do bloco (Entrega 4). Só é chamada **em cascata**,
    # de dentro da transação da ação do `Appointment` (ver `CascadeToAttendances`), com
    # `authorize?: false` — o bloco já autorizou. Aceita `status` e `falta_justificada` em
    # separado porque as transições mexem em um, a justificativa no outro.
    update :transition do
      require_atomic? false
      accept [:status, :falta_justificada]
    end

    # As transições de presença POR PARTICIPANTE (Frente 6/A2, doc 41). Substituem, na UI, as
    # ações de bloco (`Appointment.mark_completed`/`mark_missed`/`set_falta_justificada`): marca-se
    # cada presença, e o desfecho do bloco vira ROLLUP (`RollupBlockStatus`). O guard de horário
    # (`SessionStarted`) e o de versão (409) moram no wrapper do domínio (`transition_participant`),
    # como no bloco — a presença não tem `starts_at`, e ler o bloco aqui cairia antes do
    # `SetTenantGuc` (RLS). O `StatusIn` (genérico, lê `data.status`) fica aqui: é o F4 do QA.
    update :mark_present do
      require_atomic? false
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:prevista]}
      change set_attribute(:status, :concluida)
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    update :mark_absent do
      require_atomic? false
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:prevista]}
      change set_attribute(:status, :faltou)
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    # Desfaz um clique errado nesta presença: volta a `:prevista` e zera a justificativa, então o
    # agregado `Patient.faltas` e o `usadas` do pacote recuam junto.
    update :reopen_attendance do
      require_atomic? false
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:concluida, :faltou]}
      change set_attribute(:status, :prevista)
      change set_attribute(:falta_justificada, false)
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    # Justificar/desjustificar a falta desta presença (só quando faltou). Não mexe no status; o
    # rollup ainda roda (bumpa a versão do bloco e notifica), e é o que faz a falta parar de contar.
    update :justify_absence do
      require_atomic? false
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:faltou]}
      argument :justificada, :boolean, allow_nil?: false
      change set_attribute(:falta_justificada, arg(:justificada))
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    # Vincula a presença ao pacote (Fatia 3). Chamada pela materialização da série
    # (`Api.Packages.Materializer`) logo após criar a sessão: `package_id` é o vínculo por
    # participante (D11) que o contador `usadas` do pacote conta. Separada da `:create` porque a
    # criação da presença vem da cascata do `Appointment` (que não conhece pacote); o pacote a
    # carimba depois. `require_atomic?` false pelo `SetTenantGuc` (before_action), como as demais.
    update :set_package do
      require_atomic? false
      accept [:package_id]
    end

    # Sair da turma (doc 41 etapa 3). Chamada **em cascata**, de dentro da ação do bloco
    # (`Appointment.Changes.RemoveParticipants`), com `authorize?: false` — quem autoriza é o
    # bloco, e é lá que moram o guard do último participante e o `participant_removed`.
    # `require_atomic? false` pelo `SetTenantGuc` (before_action), como todas as escritas
    # por-tenant.
    destroy :remove do
      primary? true
      require_atomic? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao, :profissional], clinic_from: :tenant}
    end
  end

  preparations do
    # A7 vale para a agenda inteira, não só para o `Appointment`: sem este recorte, um
    # `profissional` que não enxerga o bloco do colega lia mesmo assim os pares
    # (appointment_id, patient_id) da clínica toda por aqui. `via: :appointment` porque o
    # `professional_id` mora no bloco, não no participante.
    prepare {Api.Scheduling.Preparations.OwnAgendaOnly, via: :appointment}
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

    attribute :status, Api.Scheduling.AttendanceStatus,
      allow_nil?: false,
      default: :prevista,
      public?: true

    # Entrega 4 (o bloco "Falta justificada" do drawer). Coluna agora, UI depois.
    attribute :falta_justificada, :boolean, allow_nil?: false, default: false, public?: true

    # Gancho da Fatia 3, sem FK (precedente de `Patient.prefs`).
    attribute :package_id, :uuid, public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :appointment, Api.Scheduling.Appointment, allow_nil?: false
    belongs_to :patient, Api.Records.Patient, allow_nil?: false
  end

  aggregates do
    # O instante da sessão, trazido do bloco para a própria presença — é por ele que o histórico
    # da ficha ordena (C13). Existe como **aggregate** porque `sort` por campo de relação não
    # desce para o SQL: sem ele, ordenar exigia carregar o histórico inteiro e usar `Enum.sort_by`,
    # que foi o que o bate-volta da Onda 3 mediu em 4.003 linhas para devolver 50.
    first :session_starts_at, :appointment, :starts_at
  end

  identities do
    # O mesmo paciente duas vezes na mesma turma é sempre erro (e quebraria o contador N/cap).
    #
    # `pre_check? true` não é enfeite: sob RLS o Postgres **omite o DETAIL** do
    # `unique_violation`, e o AshPostgres lê `error.postgres.detail` para transformar a
    # violação em erro de campo — sem DETAIL, estoura `KeyError` e o 422 vira 500. Já mordeu
    # em `appointment_type.ex:172` e `schedule_exception.ex:120`.
    identity :one_per_patient_per_appt, [:appointment_id, :patient_id] do
      pre_check? true
      message "este paciente já está neste agendamento"
    end
  end
end
