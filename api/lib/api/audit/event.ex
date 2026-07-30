defmodule Api.Audit.Event do
  @moduledoc """
  Uma linha da trilha: **um evento auditável**, de qualquer recurso do sistema (doc 63, D-Aud3).

  Substitui o modelo de consulta do `AshPaperTrail` (doc 25 §11), que era uma tabela de versões
  **por recurso**. Com dois recursos irmãos aquilo passava; com doze, não existiria "o que
  aconteceu na clínica hoje" — o admin visitaria doze abas, cada uma com sua paginação, e
  reordenaria de cabeça.

  ## O diff vem pronto, e isso não é otimização

  `diff` é gravado **resolvido** (`[%{field, from, to}]`), no `after_action`, onde o changeset
  ainda tem o antes (`changeset.data`) e o depois (o resultado). O AshPaperTrail fazia o oposto:
  `:changes_only` guardava só o valor novo e a tela reconstruía o "de X" **encadeando** a versão
  anterior do mesmo registro.

  Encadear deixou de ser possível. A retenção passou a 90 dias (D-Aud5) e a versão anterior
  pode ter sido podada — o "de X" sumiria das entradas mais antigas da janela, em silêncio e
  sem nada ficar vermelho. Resolver na escrita torna cada linha **autossuficiente**: a poda não
  a machuca, a leitura não faz a segunda consulta que `list_audit_log/2` fazia, e a redação de
  campo sensível (D-Aud4) acontece antes de o valor ser gravado — não como filtro de leitura,
  que seria uma proteção chegando tarde.

  ## Só `clinic_id` é chave estrangeira

  `record_id` e `user_id` são `uuid` crus, de propósito — a mesma razão já escrita em
  `Api.Records.AttachmentEvent` (a tabela que este recurso absorveu): **o registro precisa
  sobreviver ao que ele registra**. Uma FK
  com `CASCADE` apagaria a prova junto com o dado; com `RESTRICT`, tornaria o dado indeletável —
  que é literalmente o bug (c) do doc 26, o que custou `reference_source? false` ao PaperTrail e
  o que a eliminação da LGPD (F8/D-1) vai ter de desfazer.

  `label` e `user_label` são o instantâneo do nome no momento do evento, pela mesma lógica: a
  linha continua legível — *"Ana revogou o acesso de Carlos"* — depois que Ana e Carlos não
  existem mais. É o que `Api.Notifications.Notification` já faz com título/corpo.

  ## Escrita é de sistema

  Gravado por `Api.Audit.Capture` com `authorize?: false`; `SetTenantGuc` põe a GUC na transação
  da própria escrita para a RLS aceitar o INSERT. De fora, **ninguém** escreve: a policy é
  `forbid_if always()`, explícita e não por omissão — trilha que a aplicação autenticada pode
  editar não é trilha.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "audit_events"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
    end

    custom_indexes do
      # O feed da clínica. `clinic_id` lidera (ADR-017, obrigatório sob RLS), e **`id` entra no
      # índice** porque ele é parte da ordenação, não enfeite: a leitura ordena por
      # `at DESC, id DESC` para ter ordem TOTAL (sob paginação, duas linhas do mesmo instante
      # repetiriam ou sumiriam entre páginas).
      #
      # Sem o `id` aqui, o banco não conseguia servir a ordenação e punha um nó de `Sort` por
      # cima — medido pelo bate-volta em **28×** (2,52 ms · 19 buffers contra 0,090 ms · 9). E o
      # caso ruim é comum nesta tabela justamente por causa do relógio injetado: `at` vem de
      # `scope.now`, **estável por request**, então uma massa de 200 sessões grava 200 linhas com
      # o mesmo `at` — um grupo que o `Sort` tem de materializar inteiro.
      #
      # DDL em ASC de propósito: `clinic_id` é igualdade, então o btree serve o `DESC` lendo ao
      # contrário (Index Scan Backward). Um índice DESC seria redundante — é a mesma leitura já
      # medida no índice da caixa de notificações.
      index [:clinic_id, :at, :id], name: "audit_events_feed_index"

      # "O histórico deste paciente" / "deste agendamento" — o deep-link da ficha e o filtro por
      # registro. `resource` antes de `record_id` porque uuid não colide entre recursos, mas o
      # par é o que a consulta sempre traz junto.
      index [:clinic_id, :resource, :record_id, :at], name: "audit_events_record_index"

      # O filtro por autor — que hoje NÃO existe por falta deste índice (D-Aud2: Seq Scan de
      # 50k linhas). Com uma tabela só ele passa a caber, e o custo de escrita que assustava se
      # dilui porque a retenção de 90 dias (D-Aud5) limita a tabela por construção.
      index [:clinic_id, :user_id, :at], name: "audit_events_author_index"

      # As duas FACETAS da tela. Sem elas, o recorte por ação ou por tipo de registro caía no
      # `feed_index` (que só conhece `clinic_id`) e varria o recorte inteiro para depois ordenar:
      # medido pelo bate-volta em **14,4 ms e 7.784 buffers** contra 0,090 ms e 9 buffers da
      # página sem filtro. A ironia é que o pior caso era a resposta mais barata — `?acao=` de
      # uma ação rara (um `revoke_access` em 90 dias) lia tudo para devolver nada.
      #
      # `at` fecha os dois porque o feed sempre ordena por ele; sem essa coluna o índice
      # resolveria o `WHERE` e devolveria o trabalho de ordenar.
      index [:clinic_id, :action, :at], name: "audit_events_action_index"
      index [:clinic_id, :resource, :at], name: "audit_events_resource_index"
    end
  end

  actions do
    defaults [:read]

    # A gravação. Chamada só por `Api.Audit.Capture`/`Api.Audit` com `authorize?: false`.
    create :record do
      accept [
        :resource,
        :record_id,
        :label,
        :action,
        :action_type,
        :user_id,
        :user_label,
        :at,
        :diff,
        :meta
      ]
    end

    @doc """
    O feed: uma página da trilha da clínica, do mais recente para o mais antigo.

    Os filtros (recurso, registro, autor, ação, período) NÃO moram aqui — são opcionais e
    montados condicionalmente por `Api.Audit.list_events/2`, para que o mesmo `read` sirva o
    feed cronológico e o histórico de um registro só. Mesma divisão do `TrailMixin` que este
    recurso aposenta, e pela mesma razão: `filter expr(coluna …)` precisa do nome da coluna no
    escopo certo.
    """
    read :feed do
      pagination offset?: true, countable: true, default_limit: 50, max_page_size: 200
      prepare build(sort: [at: :desc, id: :desc])
    end

    # Existe evento igual a este dentro da janela de dedup? (D-Aud6)
    #
    # É a consulta que impede que abrir a ficha do mesmo paciente três vezes em cinco minutos
    # grave três linhas. Um índice-hit por abertura de ficha, em vez de um `INSERT` — que era
    # exatamente a objeção contra auditar a leitura na tela mais usada da recepção.
    read :recent_duplicate do
      argument :resource, Api.Audit.ResourceKind, allow_nil?: false
      argument :record_id, :uuid, allow_nil?: false
      argument :action, :string, allow_nil?: false
      argument :user_id, :uuid
      argument :since, :utc_datetime_usec, allow_nil?: false

      filter expr(
               resource == ^arg(:resource) and record_id == ^arg(:record_id) and
                 action == ^arg(:action) and user_id == ^arg(:user_id) and at >= ^arg(:since)
             )
    end

    # A gêmea da `:recent_duplicate`, para os eventos que **não têm registro** — hoje só
    # `:seguranca`, cuja chave natural é o CAMINHO tentado, não um id.
    #
    # Precisa existir como ação própria: `:recent_duplicate` exige `record_id` não-nulo, e a
    # guarda de dedup curto-circuitava em `record_id == nil` devolvendo "não registrado". O
    # resultado era que a dedup do 403 — anunciada em dois comentários — **nunca rodava**, e
    # cada resposta negada virava uma linha (medido: 100 requests → 100 linhas).
    read :recent_duplicate_by_label do
      argument :resource, Api.Audit.ResourceKind, allow_nil?: false
      argument :label, :string, allow_nil?: false
      argument :action, :string, allow_nil?: false
      argument :user_id, :uuid
      argument :since, :utc_datetime_usec, allow_nil?: false

      filter expr(
               resource == ^arg(:resource) and label == ^arg(:label) and
                 action == ^arg(:action) and user_id == ^arg(:user_id) and at >= ^arg(:since)
             )
    end
  end

  policies do
    # Ler a trilha é owner·admin — a mesma régua de sempre (doc 25 §11.2, armadilha 3). Recepção
    # e profissional não leem o histórico da clínica: ele carrega a agenda inteira, os papéis e
    # agora também quem abriu qual ficha.
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin], clinic_from: :tenant}
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
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

    attribute :resource, Api.Audit.ResourceKind, allow_nil?: false, public?: true
    attribute :action_type, Api.Audit.ActionKind, allow_nil?: false, public?: true

    # O nome da ação Ash (`schedule`, `revoke_access`, `visualizou_ficha`). String e não átomo:
    # a trilha guarda o que aconteceu, e uma ação APOSENTADA continua tendo linhas antigas com o
    # nome dela — foi a lição dos `mark_completed`/`set_falta_justificada` do doc 25.
    attribute :action, :string, allow_nil?: false, public?: true, constraints: [max_length: 60]

    # Colunas cruas, sem FK — ver o moduledoc. `record_id` é nulo em `:seguranca` (a tentativa
    # negada nem sempre mira um registro identificável).
    attribute :record_id, :uuid, public?: true
    attribute :user_id, :uuid, public?: true

    # Instantâneos do nome no momento do evento.
    attribute :label, :string, public?: true, constraints: [max_length: 200]
    attribute :user_label, :string, public?: true, constraints: [max_length: 200]

    # O relógio é o do escopo (ADR-009), não `utc_now` — é o que torna testável a janela de
    # dedup da D-Aud6 sem o teste depender do relógio de parede.
    attribute :at, :utc_datetime_usec, allow_nil?: false, public?: true

    # `[%{"field" => _, "from" => _, "to" => _, "redacted" => _}]`, já resolvido na escrita.
    # Lista vazia é legítima: um `:read` não muda nada e um `:destroy` não tem "depois".
    attribute :diff, {:array, :map}, allow_nil?: false, default: [], public?: true

    # Contexto para a linha e para o link ("ver na agenda"): `patient_id`, `professional_id`,
    # `starts_at`, `appointment_id`. Mapa livre de propósito — o que a tela precisa saber para
    # navegar varia por recurso, e promover cada um a coluna encheria a tabela de nulos.
    attribute :meta, :map, allow_nil?: false, default: %{}, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
  end
end
