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
    extensions: [AshPaperTrail.Resource]

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
    # `version_extensions` injeta o authorizer no `use Ash.Resource` gerado, `mixin` injeta as
    # policies no corpo dele (ler é owner·admin; escrever, ninguém). Ver
    # `Api.Scheduling.TrailPolicies`.
    version_extensions authorizers: [Ash.Policy.Authorizer]
    mixin Api.Scheduling.TrailPolicies
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:patient_id, :appointment_id]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type(:create) do
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
