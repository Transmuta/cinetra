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
      # A caixa: as N mais recentes de um usuário nesta clínica (#55, P4 do doc 32 — o
      # `ORDER BY inserted_at` era um Sort). O DDL é ASC de propósito: as duas primeiras colunas
      # são igualdade, então o btree serve o `DESC` lendo ao contrário (Index Scan Backward) —
      # mesmo plano que o `session_starts_at` do doc 43 §7. Um índice DESC seria redundante.
      index [:clinic_id, :recipient_id, :inserted_at], name: "notifications_inbox_index"

      # O badge e a lista `?unread=1` — o caminho que o layout do web chama em TODA navegação.
      # Parcial porque não-lida é o conjunto pequeno (e encolhe a cada "marcar todas"): o índice
      # tem o tamanho da caixa por abrir, não o do histórico inteiro.
      #
      # ## O `::timestamp` no predicado NÃO é enfeite
      #
      # É a lição do doc 35 ("D-A — o diagnóstico correto") cobrada de novo. O AshPostgres emite
      #
      #     WHERE (n0."read_at"::timestamp IS NULL) AND clinic_id = $1 AND recipient_id = $2
      #
      # e o Postgres só usa um índice parcial quando prova que o predicado do índice **implica** o
      # da query. Ele não prova isso através do cast: com `where: "read_at IS NULL"` o índice fica
      # ali, íntegro, e **nunca é escolhido**. Medido pelo caminho da app, 40.071 linhas:
      #
      #     predicado sem o cast: Seq Scan,        1.542 buffers, 5,4 ms
      #     predicado com o cast: Index Only Scan,   184 buffers, 1,9 ms
      #
      # O preço é acoplar o índice a um detalhe de emissão do AshPostgres. Se um upgrade parar de
      # emitir o cast, este índice deixa de anexar **em silêncio** — nenhum teste fica vermelho.
      # A sonda é `pg_stat_user_indexes.idx_scan` antes/depois, rodando a leitura PELA app e lida
      # numa sessão nova (dentro da mesma conexão o snapshot de `pg_stat` vem cacheado).
      index [:clinic_id, :recipient_id, :inserted_at],
        where: "(read_at)::timestamp IS NULL",
        name: "notifications_unread_index"

      # Apoio ao cascade da FK de destinatário sem índice próprio sob ADR-017 (como em `slot_holds`).
      index [:recipient_id], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    # A caixa paginada (#54, P3 do doc 32). Sem teto, a lista crescia com o uso: a sonda com
    # volume mediu 20.065 linhas em 583 ms numa caixa de um ano. Os números de página são os de
    # `Api.Pagination` (50/200), como pacientes, trilha e fila.
    #
    # `:inbox` é ação própria em vez de paginação no `:read` porque o `:read` também serve o
    # `get_by: [:id]` do "marcar lida" — mesma separação de `Patient` (`:read` + `:list`).
    read :inbox do
      pagination offset?: true, countable: true, default_limit: 50, max_page_size: 200
      prepare build(sort: [inserted_at: :desc])
    end

    # As não-lidas (o badge e o "marcar todas"). `is_nil` de verdade — `read_at == nil` viraria
    # `= NULL` no SQL e não casaria nunca.
    #
    # Paginada pelo mesmo motivo, e com um ganho a mais: `countable` devolve o total do recorte
    # junto da página, então o badge sai da MESMA query que a lista — não de um `COUNT` à parte.
    read :unread do
      filter expr(is_nil(read_at))
      pagination offset?: true, countable: true, default_limit: 50, max_page_size: 200
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

    # "Marcar todas" numa UPDATE só (#53, P2 do doc 32). Ação própria, e não `bulk_update` sobre
    # o `:mark_read`, por dois motivos que se somam:
    #
    #   * o `:mark_read` é idempotente **por comparação** (o `StampReadAtOnce` lê o `read_at`
    #     atual para decidir), e ler registro a registro é justamente o round-trip que este item
    #     elimina. Aqui a idempotência vem do FILTRO do recorte (`read_at IS NULL`) — mesma
    #     garantia, feita no banco, sobre o conjunto inteiro;
    #   * o `SetTenantGuc` é um `before_action`, e hook derruba a ação do caminho atômico. Aqui
    #     ele não falta: quem chama é `Api.Notifications.mark_all_read/1`, que roda dentro do
    #     `in_clinic` — a GUC já está na transação antes do UPDATE (e o gate `:rls` prova).
    update :mark_all_read do
      accept []
      change set_attribute(:read_at, expr(now()))
    end

    # "Limpar tudo": apaga a caixa do dono, lida ou não. Mesmo desenho do `mark_all_read` — ação
    # sem hook nenhum, para o `Ash.bulk_destroy!` poder ir pelo caminho atômico (um DELETE só) e
    # para a policy filter-check virar cláusula do WHERE. Um hook aqui derrubaria as duas coisas.
    #
    # É destruição de verdade, não arquivamento: a caixa é um aviso, não um registro de domínio —
    # o que aconteceu está na agenda e na trilha de auditoria, que ninguém apaga daqui.
    destroy :clear do
    end
  end

  policies do
    # A caixa é privada: cada um só lê e marca a própria.
    policy action_type(:read) do
      authorize_if expr(recipient_id == ^actor(:id))
    end

    # Filter-check: no UPDATE em massa ela vira cláusula do `WHERE`, e é o que impede o
    # "marcar todas" de um usuário de alcançar a caixa do colega da mesma clínica.
    policy action([:mark_read, :mark_all_read]) do
      authorize_if expr(recipient_id == ^actor(:id))
    end

    # Mesmo recorte, e aqui ele é o que separa "esvaziei a minha caixa" de "apaguei a do colega".
    policy action_type(:destroy) do
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
