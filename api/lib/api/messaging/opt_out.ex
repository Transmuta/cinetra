defmodule Api.Messaging.OptOut do
  @moduledoc """
  "Não me mande mais" (doc 52 §10). A lista é **nossa**, não do provider.

  ## Por que não delegar ao provider

  A Gupshup tem gestão própria de opt-out, e o Resend tem descadastro. Nenhuma das duas serve
  sozinha, por dois motivos (§10.1):

    * a recepção precisa **ver na timeline** por que nada saiu — lista que mora no provider é
      invisível na tela, e silêncio na tela é pior do que não ter a funcionalidade;
    * somos multi-tenant. Uma lista no nível da conta do provider vale para todas as clínicas de
      uma vez, sem que ninguém tenha decidido isso.

  ## A chave é o DESTINO, não o paciente

  Deliberado, e as duas razões são concretas:

    * o webhook de entrada sabe o **número/endereço que respondeu**, não quem é o paciente. É o
      mesmo problema de "evento sem `clinic_id`" do §2, e se resolve no mesmo lugar;
    * um número serve **mais de uma ficha** no balcão (mãe e filho, casal). Preso à ficha que
      disparou, o "SAIR" deixaria o outro paciente recebendo no mesmo aparelho — e é o aparelho
      que pediu para parar.

  ## `clinic_id` anulável não é preguiça (C10)

  Nulo = **global**, preenchido = daquela clínica. Segue o C11: na v1 há um número único da
  Cinetra, então o paciente vê um remetente só e "SAIR" só pode significar tudo — não temos como
  perguntar de qual clínica ele fala. Quando (e se) uma clínica tiver número próprio, o opt-out
  daquele número nasce com `clinic_id` e a regra de resolução muda **sem migração**.

  Consequência que vale conhecer: este é o único recurso do projeto que **não** é estritamente
  por-tenant. Por isso a leitura do `Dispatch` procura os dois casos (`is_nil(clinic_id) or
  clinic_id == ^clinic`), e a **RLS da tabela tem uma cláusula a mais**: além do
  `clinic_id = <GUC>` de sempre, ela aceita `clinic_id IS NULL`, senão a linha global sumiria da
  leitura e continuaríamos mandando para quem pediu para parar (migration `MessagingRls`).

  Ler um opt-out global de outro tenant é, portanto, possível — e é a intenção: o que ele revela é
  um endereço que pediu para não ser contatado, informação que existe justamente para ser
  respeitada por todo mundo. Pela fronteira HTTP ninguém o lê: não há rota, e a policy do recurso
  proíbe toda ação.

  ## Revogar é legítimo — com nome e hora

  A política da Meta aceita opt-in obtido por **qualquer canal**, inclusive "pode mandar no meu
  WhatsApp, sim" dito no balcão. Por isso existe `revogado_em`/`revogado_por_id`: reativação sem
  registro é o tipo de coisa que ninguém consegue explicar depois.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Messaging,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "message_opt_outs"
    repo Api.Repo

    references do
      # Nulo = global (ver o moduledoc). A clínica sai → o opt-out dela sai junto; o global fica.
      reference :clinic, on_delete: :delete
      reference :revogado_por, on_delete: :nilify
    end

    custom_indexes do
      index [:clinic_id], all_tenants?: true
      index [:revogado_por_id], all_tenants?: true
    end

    # O SQL do `where` da identity `:vigente_por_destino`, exigido pelo AshPostgres para usá-la
    # como alvo de upsert: ele precisa repetir o predicado no `ON CONFLICT (…) WHERE …`, e não
    # traduz o `expr` sozinho nesse ponto.
    #
    # O `::timestamp` é a lição do doc 35 cobrada de novo (ver o índice parcial de
    # `notifications`): o AshPostgres emite `revogado_em::timestamp IS NULL` nas leituras, e o
    # Postgres não prova a implicação através do cast. O predicado do índice, o da leitura e este
    # aqui têm de ser **o mesmo texto** — se divergirem, o índice fica íntegro e nunca é
    # escolhido, e o `ON CONFLICT` deixa de inferi-lo.
    identity_wheres_to_sql vigente_por_destino: "(revogado_em)::timestamp IS NULL"
  end

  # Sem `AshPaperTrail` pela mesma razão da `Message`: o registro já é o histórico. Um opt-out
  # nunca é apagado nem editado — nasce e, no máximo, é revogado, e a revogação carimba
  # `revogado_em`/`revogado_por_id` na própria linha. Não há mudança que a trilha contaria e a
  # tabela não conta.

  actions do
    defaults [:read]

    read :vigentes do
      description "Os opt-outs em vigor para um destino num canal (global + o da clínica)."

      argument :canal, Api.Messaging.MessageChannel, allow_nil?: false
      argument :destino, :string, allow_nil?: false
      argument :clinic_id, :uuid, allow_nil?: true

      filter expr(
               canal == ^arg(:canal) and destino == ^arg(:destino) and is_nil(revogado_em) and
                 (is_nil(clinic_id) or clinic_id == ^arg(:clinic_id))
             )
    end

    create :registrar do
      description "Registra que este destino pediu para parar."

      accept [:clinic_id, :canal, :destino, :origem, :motivo]

      # **Upsert, e não read-then-write** (doc 96, A-5). As fontes repetem por desenho: a Zernio
      # reentrega o mesmo evento até 7× em 24 h, o Resend reentrega o `complained` se o webhook
      # demorar, e o paciente clica duas vezes no descadastro. O guard que existia em
      # `Api.Messaging.opt_out/4` — "já está na lista? então não grava" — é *check-then-act*: duas
      # entregas simultâneas leem "não" as duas e gravam as duas. Sem índice único, nada barra.
      #
      # `upsert_fields []` é deliberado: conflito não muda nada. A `origem` e o `motivo` que valem
      # são os do **primeiro** pedido — é a hora em que o paciente pediu para parar, e reescrevê-la
      # com a de uma reentrega do provider seria falsear o registro. Com a lista vazia, o
      # AshPostgres cai nas próprias chaves do conflito (`SET canal = EXCLUDED.canal, …`), o que é
      # um no-op que ainda devolve a linha — inclusive sem tocar em `updated_at`.
      upsert? true
      upsert_identity :vigente_por_destino
      upsert_fields []

      # A GUC de tenant, como TODA escrita de recurso com RLS (doc 96, T-2).
      #
      # O comentário em `Api.Messaging` diz que `OptOut` "não é por-tenant (é o único do
      # projeto)". Isso é verdade **no Ash** e falso **no Postgres**: a tabela tem RLS, com a
      # policy `clinic_id IS NULL OR clinic_id = current_setting(...)`. Sem a GUC, só as linhas
      # globais são visíveis — e as duas ações abaixo eram as únicas escritas do projeto sem
      # `SetTenantGuc`.
      #
      # Hoje isso é latente porque os dois produtores gravam opt-out GLOBAL. No dia em que uma
      # clínica tiver número próprio (o cenário C10/C11 previsto no moduledoc), `opted_out?`
      # passaria a responder `false` para opt-out por-clínica — ou seja, o sistema voltaria a
      # mandar mensagem paga para quem pediu para parar.
      change Api.Tenancy.SetTenantGuc
    end

    update :revogar do
      description "O paciente pediu para voltar a receber (§10.1, regra 3)."

      accept [:revogado_por_id]

      # O `SetTenantGuc` seta a GUC num `before_action`, incompatível com update atômico — a
      # mesma razão do `require_atomic? false` em toda escrita por-tenant do projeto.
      require_atomic? false

      # `&DateTime.utc_now/0` e não `expr(now())`: a expressão só é avaliada no caminho atômico
      # (vira `now()` no SQL), e esta ação não vai por ele. Fora do atômico o Ash tenta gravar a
      # *expressão* como valor e recusa o cast — com um erro que não diz isso ("Could not cast
      # input to datetime. Value: now()").
      change set_attribute(:revogado_em, &DateTime.utc_now/0)
      change Api.Tenancy.SetTenantGuc
    end
  end

  policies do
    # Ninguém lê nem escreve isto pela fronteira: quem registra é o webhook e o link de
    # descadastro (sem sessão, `authorize?: false`); quem revoga é o `Api.Messaging`, com o
    # actor guardado na fronteira HTTP. Sem policy permissiva, toda ação seria 403 — inclusive
    # as internas, que não passam por aqui.
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :canal, Api.Messaging.MessageChannel, allow_nil?: false, public?: true

    # E-mail normalizado (minúsculas) ou telefone em E.164. A normalização é do `Dispatch`, para
    # a comparação não depender de como o dado foi digitado.
    attribute :destino, :string, allow_nil?: false, public?: true, constraints: [max_length: 160]

    # De onde veio o pedido: `"link"`, `"spam"`, `"palavra_chave"`, `"bloqueio"`, `"balcao"`.
    # String e não enum: a fase 2 acrescenta origens do WhatsApp, e um enum aqui viraria
    # migration a cada BSP.
    attribute :origem, :string, allow_nil?: false, public?: true, constraints: [max_length: 40]
    attribute :motivo, :string, public?: true, constraints: [max_length: 300]

    attribute :revogado_em, :utc_datetime, public?: true

    timestamps()
  end

  relationships do
    # Nulo = global. Ver o moduledoc — é o único recurso do projeto onde isso é verdade.
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: true
    belongs_to :revogado_por, Api.Accounts.User
  end

  # A unicidade é dos **vigentes**, não do destino para sempre (doc 96, A-5).
  #
  # O recorte por `is_nil(revogado_em)` é o que preserva o ciclo legítimo "parar → voltar → parar
  # de novo": a segunda parada nasce como linha nova, e a revogação anterior continua no banco com
  # nome e hora. Um índice único simples proibiria o ciclo — ou, num upsert que sobrescrevesse,
  # apagaria a revogação. Este recurso não tem `AshPaperTrail` justamente porque a linha *é* o
  # histórico; um índice que o apague desfaz essa decisão pela porta dos fundos.
  #
  # `nils_distinct? false` porque `clinic_id` nulo é o caso NORMAL aqui, não a exceção: nulo =
  # opt-out global (C10/C11 no moduledoc), que é o que a v1 grava o tempo todo. No default do
  # Postgres dois nulos não colidem, e a constraint não pegaria justamente o caso que existe.
  #
  # Sem `pre_check?`: o caminho é upsert, então a colisão é resolvida pelo `ON CONFLICT` e nunca
  # vira `unique_violation`. (O `pre_check?` de `Patient` existe por outro motivo — sob RLS o
  # Postgres omite o DETAIL do erro e o AshPostgres o lê; aqui não há erro para ler.)
  identities do
    identity :vigente_por_destino, [:canal, :destino, :clinic_id] do
      where expr(is_nil(revogado_em))
      nils_distinct? false
    end
  end
end
