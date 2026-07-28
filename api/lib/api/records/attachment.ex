defmodule Api.Records.Attachment do
  @moduledoc """
  Anexo de paciente — laudo, exame, guia de convênio, termo assinado. Recurso **por-tenant** por
  atributo (`strategy :attribute` sobre `clinic_id`, ADR-017), irmão estrutural de `Patient`.

  A linha guarda **metadado**; os bytes moram em bucket privado no Cloudflare R2 (`Api.Storage`).
  A ligação entre os dois é a coluna `chave`, que é derivada de ids e nunca do nome do arquivo
  (`Api.Records.Attachment.Conteudo.chave/4` explica por quê).

  ## Quem pode (decisão de produto, 2026-07-27)

  **Owner, admin e recepção** — para tudo: ver, baixar, subir, renomear e remover. O
  `profissional` **não** enxerga anexo, e essa é a primeira regra de leitura da ficha que não é
  "todo membro ativo" (D16 vale para o cadastro; anexo é a exceção). A lista está em
  `@papeis` logo abaixo, num lugar só: mudar quem vê é mudar uma linha.

  > Consequência a conhecer: o fisioterapeuta que atende não abre o laudo do próprio paciente
  > pelo sistema. Foi escolha explícita de quem decide o produto, não descuido do modelo.

  ## Por que as FKs são `RESTRICT`, contra o padrão da casa

  Todo filho de `clinics` no projeto é `CASCADE` — "apagar a clínica leva tudo dela". Aqui não, e
  o mesmo vale para `patients`:

  **Um `CASCADE` apagaria a linha e deixaria os bytes.** O `DELETE` cascateante acontece dentro do
  Postgres, sem passar pela aplicação — ou seja, sem o `Api.Storage.delete/1` que tira o objeto do
  bucket. O resultado seria laudo no R2 sem nenhuma linha apontando para ele: dado de saúde
  invisível ao sistema, fora de qualquer policy, que só um inventário manual do bucket
  encontraria. É exatamente o órfão que o desenho de `Api.Storage` (que por isso não tem `list`)
  se propôs a tornar impossível.

  `RESTRICT` transforma isso numa trava: para apagar um paciente ou uma clínica é **obrigatório**
  passar pela aplicação e remover os anexos primeiro — que é o caminho que apaga os bytes. Quando
  o F8 (eliminação da LGPD, [`50 §D-1`](../../../docs/50-debitos-tecnicos.md)) entrar, é essa
  ordem que ele terá de respeitar.

  `uploaded_by` é `SET NULL`: autoria é informativa, o anexo sobrevive à saída de quem o subiu
  (mesma decisão do H64, Onda 5).

  ## O ciclo de vida, e por que a linha nasce antes dos bytes

      start  →  linha :pendente + URL assinada  →  browser faz PUT no R2  →  confirm

  A ordem não é acidental: com a linha primeiro, **objeto sem linha** deixa de ser possível. O
  que sobra é linha-sem-objeto (o usuário fechou a aba no meio), que é visível por consulta ao
  banco e podada por `Api.Housekeeping.PruneAttachments`. O erro que sobra é o barato.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Records,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  # A lista de papéis com acesso a anexo. Uma constante, e não `[:owner, :admin, :recepcao]`
  # repetido em cada policy, porque é a linha que muda se a decisão de produto virar.
  @papeis [:owner, :admin, :recepcao]

  def papeis, do: @papeis

  postgres do
    table "attachments"
    repo Api.Repo

    references do
      # RESTRICT nas duas: ver o moduledoc. Não é conservadorismo — é o que obriga a remoção a
      # passar pela aplicação, que é quem sabe apagar os bytes no R2.
      reference :clinic, on_delete: :restrict
      reference :patient, on_delete: :restrict
      reference :uploaded_by, on_delete: :nilify
    end

    custom_indexes do
      # Serve o recorte por tenant (coluna líder, obrigatório sob RLS), a listagem da ficha
      # (`WHERE clinic_id = _ AND patient_id = _ ORDER BY inserted_at`) e a checagem do
      # `DELETE` de `clinics` — três usos, um índice.
      index [:clinic_id, :patient_id, :inserted_at]

      # As duas outras FKs precisam de índice em que elas **liderem**: é o que a checagem do
      # `DELETE` do pai usa (`WHERE fk = $1`), e o que `on_delete_test.exs` exige. Aqui vale a
      # pena mesmo sem volume — a tabela é de escrita rara (alguns anexos por paciente na vida),
      # então o custo por INSERT é irrelevante, ao contrário do caso do D-2.
      index [:patient_id], all_tenants?: true
      index [:uploaded_by_id], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    # Os anexos disponíveis de um paciente, do mais novo para o mais antigo.
    read :for_patient do
      argument :patient_id, :uuid, allow_nil?: false

      # `:pendente` fica de fora: é linha de upload em andamento (ou abandonado), não anexo.
      filter expr(patient_id == ^arg(:patient_id) and status == :disponivel)
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    # Abre o upload: cria a linha `:pendente`. Só `Api.Records.start_attachment/3` chama.
    create :start do
      # `:id` e `:chave` entram prontos porque a chave é **derivada do id**, e o id precisa
      # existir antes de a chave poder ser calculada. Quem os calcula é o wrapper do domínio,
      # que tem escopo, paciente resolvido e as regras de `Conteudo`. Nenhum dos dois vem de
      # parâmetro de request — o controller não os aceita.
      accept [:id, :nome, :content_type, :bytes, :patient_id, :chave]
      change relate_actor(:uploaded_by, allow_nil?: true)
    end

    # Fecha o upload depois da conferência: grava o tamanho e o tipo REAIS.
    update :confirm do
      accept [:bytes, :content_type]
      require_atomic? false
      change set_attribute(:status, :disponivel)
    end

    # Renomeia — só o rótulo. A chave do objeto no bucket é imutável.
    update :rename do
      accept [:nome]
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end

  # Owner, admin e recepção fazem tudo; os demais, nada. Uma policy só (não uma por
  # `action_type`) porque leitura e escrita têm exatamente a mesma lista — separá-las sugeriria
  # uma distinção que não existe, e é assim que as duas divergem com o tempo.
  policies do
    policy always() do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: @papeis, clinic_from: :tenant}
    end
  end

  changes do
    # Toda escrita seta a GUC de tenant dentro da própria transação — sem ela a RLS barra o
    # INSERT/UPDATE no servidor real (NOBYPASSRLS) e o `mix test` não acusa (o sandbox conecta
    # como `postgres`, BYPASSRLS).
    #
    # `on:` explícito porque o padrão do Ash é `[:create, :update]` — ele omite `destroy` de
    # propósito ("most changes don't make sense for a destroy"). Aqui faz: `delete_attachment/2`
    # chama a code interface fora de `in_clinic` (envolvê-la abriria transação por fora e viraria
    # 500 no caminho de erro — ver o moduledoc do `SetTenantGuc`), então quem põe a GUC na
    # transação do DELETE é esta change. Sem o `:destroy`, remover anexo respondia 400 no
    # servidor real com `''::uuid`, e a suíte não via: a GUC do `autorizar/3` fica pendurada no
    # sandbox, que roda o teste inteiro numa transação só.
    change Api.Tenancy.SetTenantGuc, on: [:create, :update, :destroy]
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    # `writable?: true` porque a **chave do objeto deriva do id** e precisa estar pronta já no
    # INSERT (ver `Api.Records.start_attachment/3`): sem poder informar o id, a chave só poderia
    # ser calculada num UPDATE posterior, abrindo uma janela em que a linha existe sem destino.
    # Só a ação `:start` o aceita, e só o wrapper do domínio a chama.
    uuid_v7_primary_key :id, writable?: true

    # O nome que a clínica vê e **pode editar** (renomear). Não tem relação com a chave do
    # objeto: renomear é um UPDATE numa coluna, nunca uma cópia de 50 MB no bucket.
    attribute :nome, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 200]

    # O caminho no bucket. Não é `public?`: o cliente não tem o que fazer com ele, e ele carrega
    # os ids de clínica e paciente.
    attribute :chave, :string, allow_nil?: false, constraints: [max_length: 300]

    # O tipo **conferido** por magic bytes na confirmação (até lá, o declarado pelo cliente).
    attribute :content_type, :string, allow_nil?: false, public?: true

    attribute :bytes, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :status, Api.Records.AttachmentStatus,
      allow_nil?: false,
      public?: true,
      default: :pendente

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :patient, Api.Records.Patient, allow_nil?: false

    # Quem subiu. `allow_nil?` porque o `SET NULL` da FK precisa de uma coluna que aceite nulo —
    # e porque a autoria some quando o usuário é removido, sem levar o anexo junto.
    belongs_to :uploaded_by, Api.Accounts.User
  end
end
