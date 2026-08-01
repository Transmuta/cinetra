defmodule Api.Messaging.WebhookEvent do
  @moduledoc """
  Evento de webhook **já visto** — a defesa contra replay que a assinatura da Zernio não dá
  (doc 96, S-7).

  ## Por que ela precisou existir

  O `Api.Messaging.ZernioSignature` assina só o corpo: sem timestamp no material assinado, **um
  payload capturado continua válido para sempre**. O argumento que sustentava isso era que todo
  efeito de webhook é idempotente — e ele tinha um furo, porque `Api.Messaging.revoke_opt_out/3`
  existe: entre o `SAIR` original e o replay cabe uma revogação, e o replay a desfaz. O paciente
  pede no balcão para voltar a receber, a recepção reativa, e ele para de receber de novo, sem
  erro em lugar nenhum.

  O moduledoc do `ZernioSignature` já dizia que a tabela seria necessária "no dia em que um evento
  tiver efeito não-idempotente". A condição estava satisfeita e ninguém tinha notado: não é o
  evento que deixou de ser idempotente, é que passou a existir uma ação **do outro lado** que o
  desfaz.

  ## A chave é o SHA-256 do corpo cru, não um id do provider

  Deliberado, e a razão é que não depende de documentação que não temos: a Zernio não promete
  campo de id de evento (doc 65 §6), e mesmo o `provider_message_id` ela não garante que seja o
  mesmo do envio. O corpo cru é o que de fato foi assinado e o que de fato é reentregue — é a
  identidade mais honesta que existe aqui, e vale igual para os dois providers.

  A consequência a conhecer: **dois eventos legítimos com corpo byte a byte igual contam como
  um.** Isso é aceitável hoje porque todo efeito de webhook é idempotente por construção — dois
  `delivered` da mesma mensagem são no-op, dois `SAIR` do mesmo número são o mesmo opt-out. É a
  mesma precondição do moduledoc do `ZernioSignature`, agora escrita nos dois lugares: um evento
  futuro com efeito **acumulativo** (cobrar, criar linha, disparar mensagem) precisa de chave
  própria antes de entrar.

  ## Sem `clinic_id`, e portanto sem RLS

  O evento chega **antes** de existir tenant — é justamente o problema que o `Api.Messaging.Webhooks`
  resolve primeiro. Não há coluna de clínica para uma policy comparar, e o conteúdo (um digest e o
  nome do provider) não é dado de paciente. Por isso esta tabela fica fora da varredura por-tenant
  do `Api.RlsSmokeTest`.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Messaging,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "webhook_events"
    repo Api.Repo
  end

  actions do
    defaults [:read]

    read :por_corpo do
      description "Este corpo já foi visto deste provider?"

      argument :provider, :string, allow_nil?: false
      argument :digest, :string, allow_nil?: false

      filter expr(provider == ^arg(:provider) and digest == ^arg(:digest))
    end

    create :registrar do
      description "Marca este corpo de evento como já processado."

      accept [:provider, :digest]

      # O upsert é o que fecha a corrida: duas reentregas simultâneas do mesmo corpo chegariam as
      # duas ao `INSERT`, e sem `ON CONFLICT` a segunda estouraria `unique_violation` — virando
      # 500 num endpoint que precisa responder 200 em 5 s. `upsert_fields []` porque conflito não
      # muda nada: a linha que vale é a da primeira vez que vimos o evento.
      upsert? true
      upsert_identity :um_por_corpo
      upsert_fields []
    end
  end

  policies do
    # Ninguém alcança isto pela fronteira: quem grava é o controller de webhook, sem sessão e com
    # `authorize?: false`. Sem policy permissiva toda ação seria 403, inclusive a interna — é o
    # mesmo desenho de `Api.Messaging.OptOut`.
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # `"zernio"` ou `"resend"`. String e não enum pela mesma razão do `origem` do `OptOut`: cada
    # BSP novo viraria migration.
    attribute :provider, :string, allow_nil?: false, public?: true, constraints: [max_length: 20]

    # SHA-256 em hexadecimal minúsculo — 64 caracteres, sempre.
    attribute :digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    # Só `inserted_at`: a linha nunca é editada, e é por ele que a poda a alcança.
    create_timestamp :inserted_at
  end

  identities do
    identity :um_por_corpo, [:provider, :digest]
  end
end
