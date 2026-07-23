defmodule Api.Notifications.Notification do
  @moduledoc """
  Uma notificação in-app **por usuário** (doc 31). É a peça que faltava: o tempo real da agenda
  (`AgendaNotifier`) é efêmero e por-clínica; isto é o registro assíncrono, persistido e
  destinado a *um* usuário — "enquanto você não estava olhando, aconteceu algo com o seu
  trabalho" (doc 31 §1).

  ## Por-tenant, mas destinada a um usuário

  Recurso por-tenant por atributo (`clinic_id`, ADR-017/018 — RLS igual ao resto). O
  destinatário (`recipient`) é o `User` **global**: a mesma pessoa que atende em duas clínicas vê,
  em cada tenant, as notificações daquele tenant. A leitura é recortada na policy por
  `recipient_id == actor`, então dois membros da mesma clínica não veem a caixa um do outro.

  ## Texto denormalizado (título/corpo gravados)

  `title`/`body` são gravados no momento do evento, não recalculados por join. Uma notificação é
  o registro do que aconteceu: se o agendamento for depois remarcado ou o paciente renomeado, a
  linha do histórico não deve mudar sob os pés. `data` carrega o mínimo para a UI navegar
  (`appointment_id`, `date`, `actor`).

  ## Criação é de sistema

  Não há policy de `create`: a caixa não é escrita pela UI, e sim pelo `Api.Notifications.Fanout`
  (após o commit do evento de origem), com `authorize?: false`. A `SetTenantGuc` põe a GUC na
  transação da própria escrita para a RLS aceitar o INSERT (mesma razão de todo recurso por-tenant).
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Notifications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "notifications"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete

      # O destinatário some → a caixa dele some junto (a notificação não sobrevive ao usuário).
      reference :recipient, on_delete: :delete
    end

    custom_indexes do
      # O acesso quente: a caixa de um usuário na clínica ativa, não-lidas primeiro, recente no topo.
      index [:clinic_id, :recipient_id, :read_at]

      # Apoio ao cascade da FK de destinatário sem índice próprio sob ADR-017 (como em `slot_holds`).
      index [:recipient_id], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    # As não-lidas (o badge e o "marcar todas"). `is_nil` de verdade — `read_at == nil` viraria
    # `= NULL` no SQL e não casaria nunca.
    read :unread do
      filter expr(is_nil(read_at))
      prepare build(sort: [inserted_at: :desc])
    end

    # Sistema (Fanout, authorize?: false). Não há policy de create — a UI nunca escreve aqui.
    create :notify do
      accept [:recipient_id, :kind, :title, :body, :data]
      change Api.Tenancy.SetTenantGuc
    end

    # Marcar como lida (idempotente: remarcar não reescreve o instante). Só o dono, pela policy.
    update :mark_read do
      accept []
      require_atomic? false
      change Api.Tenancy.SetTenantGuc
      change Api.Notifications.Notification.Changes.StampReadAtOnce
    end
  end

  policies do
    # A caixa é privada: cada um só lê e marca a própria.
    policy action_type(:read) do
      authorize_if expr(recipient_id == ^actor(:id))
    end

    policy action(:mark_read) do
      authorize_if expr(recipient_id == ^actor(:id))
    end
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, Api.Notifications.NotificationKind, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, allow_nil?: false, public?: true

    # Carga para a UI navegar (appointment_id, date, actor). Sem lógica de domínio — só payload.
    attribute :data, :map, allow_nil?: false, default: %{}, public?: true

    # `nil` = não-lida (é o que o badge conta). Um instante = lida.
    attribute :read_at, :utc_datetime, allow_nil?: true, public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :recipient, Api.Accounts.User, allow_nil?: false
  end
end
