defmodule Api.Accounts.User do
  @moduledoc """
  A identidade global de login (ADR-014). Uma pessoa = um `User`, no schema público,
  ligada a N clínicas por N `Membership`s. Separado de `Professional` (que é por-tenant).

  Autenticação **sem senha** (ADR-015): Google OAuth + Magic Link. O `AshAuthentication`
  cuida dos tokens (recurso `Api.Accounts.Token`) e das estratégias; a resolução do tenant
  ativo e do papel vive na sessão/escopo (ver `ApiWeb.Plugs.LoadScope`), não aqui.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Api.Accounts.Token
      signing_secret Api.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      magic_link do
        identity_field :email
        registration_enabled? true
        # Callback GET direto assina a sessão (contrato 09 §8): o link do e-mail leva
        # ao `/auth/magic-link/callback?token=…`, sem página intermediária de interação.
        require_interaction? false

        sender Api.Accounts.User.Senders.SendMagicLinkEmail
      end

      # Google OAuth (ADR-015). URLs de authorize/token/userinfo são preset pelo Google;
      # client_id/secret/redirect_uri vêm de `Api.Secrets` (env). Registro = login (upsert
      # por e-mail verificado) via `register_with_google`.
      google do
        client_id Api.Secrets
        redirect_uri Api.Secrets
        client_secret Api.Secrets
        # Casa a pessoa pelo par (iss, sub) do Google, não pelo e-mail (mais estável/seguro).
        identity_resource Api.Accounts.UserIdentity
      end

      remember_me :remember_me
    end
  end

  # Global: o User é a identidade única e vive no schema público (sem `multitenancy`).
  postgres do
    table "users"
    repo Api.Repo
  end

  actions do
    defaults [:read]

    # Placeholder até a fatia de auth: cria/identifica o usuário pelo e-mail. Com
    # AshAuthentication, magic link/Google assumem o create real (upsert por e-mail).
    create :register do
      accept [:nome, :email]
      upsert? true
      upsert_identity :unique_email
    end

    # Tela "Meu perfil": a pessoa edita o próprio nome de exibição. O e-mail NÃO entra — ele é a
    # identidade de login passwordless (trocá-lo exigiria reverificar posse do novo e-mail).
    update :update_profile do
      accept [:nome]
    end

    @doc """
    Registra que esta pessoa passou pelos documentos legais **naquela versão** (`[D-14]`).

    Idempotente por versão: reaceitar a mesma versão **não** reescreve o instante da primeira —
    "quando aceitou a 1.0" é a pergunta, e sobrescrevê-la a cada login trocaria a resposta por
    "quando entrou pela última vez", que é outro dado e não serve de prova de nada. Versão nova
    carimba de novo, e é assim que se descobre quem ainda não viu o texto novo.
    """
    update :accept_terms do
      description "Carimba o aceite dos Termos/Privacidade na versão informada."

      accept []
      argument :versao, :string, allow_nil?: false, constraints: [max_length: 20]
      require_atomic? false

      change Api.Accounts.User.Changes.StampTermsAcceptance
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    create :sign_in_with_magic_link do
      description "Sign in or register a user with magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token"
        allow_nil? true
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email]

      # O token chega SELADO (cifrado na URL do e-mail); abre o selo e reescreve o
      # argumento :token com o JWT antes dos changes que o verificam.
      change Api.Accounts.User.Changes.UnsealMagicLinkToken
      # Allowlist: o jti do link tem que existir na tabela (a lib só exige presença na
      # sessão, não aqui) — sem isto, JWT bem assinado forjado offline logaria.
      change Api.Accounts.User.Changes.RequireMagicLinkTokenPresence
      # Uses the information from the token to create or sign in the user
      change AshAuthentication.Strategy.MagicLink.SignInChange
      # O nome do cadastro chega como claim assinado do token (quando informado em
      # "criar conta"); só na ausência dele defaultamos pela parte local do e-mail.
      change Api.Accounts.User.Changes.SetNomeFromToken
      change Api.Accounts.User.Changes.DefaultNomeFromEmail

      change {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenChange,
              strategy_name: :remember_me}

      metadata :token, :string do
        allow_nil? false
      end
    end

    # A foto de perfil, depois de baixada do Google e guardada no bucket (`AvatarSyncJob`).
    # Ação separada de `update_profile` porque quem a chama é o job, não a pessoa: nenhum dos
    # dois campos é editável na tela, e misturá-los abriria `avatar_key` (o endereço de um
    # objeto no R2) a um PATCH de request.
    update :set_avatar do
      accept []

      argument :avatar_key, :string, allow_nil?: true
      argument :avatar_origem, :string, allow_nil?: true

      change set_attribute(:avatar_key, arg(:avatar_key))
      change set_attribute(:avatar_origem, arg(:avatar_origem))
    end

    create :register_with_google do
      description "Registra ou identifica um usuário via Google OAuth (upsert por e-mail)."
      upsert? true
      upsert_identity :unique_email

      # `avatar_key`/`avatar_origem` NÃO entram: o login não sabe nada sobre a foto ainda (ela é
      # baixada depois, fora do request). Fora do `upsert_fields`, o que já está gravado
      # sobrevive ao próximo login — que é o comportamento desejado.
      upsert_fields [:email, :nome]

      argument :user_info, :map, allow_nil?: false
      argument :oauth_tokens, :map, allow_nil?: false

      change Api.Accounts.User.Changes.SetFromGoogleUserInfo
      # Enfileira a busca da foto (fora do request) quando o Google mandou uma que ainda não
      # temos. Antes da IdentityChange/GenerateTokenChange não faz diferença — é `after_action`.
      change Api.Accounts.User.Changes.SyncGoogleAvatar
      # Faz o upsert da UserIdentity (strategy + uid) e a liga ao usuário.
      change AshAuthentication.Strategy.OAuth2.IdentityChange
      change AshAuthentication.GenerateTokenChange
    end

    action :request_magic_link do
      argument :email, :ci_string do
        allow_nil? false
      end

      # Nome (opcional) informado no cadastro por magic link. Viaja assinado no token para
      # virar o nome do User no primeiro acesso (ver Api.Accounts.User.RequestMagicLink).
      argument :nome, :string, allow_nil?: true

      # Distingue LOGIN (false, o default) de CADASTRO (true). No login, e-mail SEM conta
      # recebe resposta neutra sem criar conta nem enviar link — evita virar cadastro
      # silencioso e enumerar quem tem conta. Só /criar-conta e o convite pedem register?.
      argument :register?, :boolean, allow_nil?: false, default: false

      run Api.Accounts.User.RequestMagicLink
    end
  end

  policies do
    # O próprio AshAuthentication precisa operar o recurso (upsert por token, lookup
    # por subject) sem passar por policy de negócio.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Entrypoints públicos de autenticação (ADR-015): a segurança está no token/OAuth
    # validado dentro da ação, não numa policy. Chamados direto pelo code interface
    # (controller), eles não recebem a flag de "interaction", então liberamos aqui.
    policy action([:request_magic_link, :sign_in_with_magic_link, :register_with_google]) do
      authorize_if always()
    end

    # "Meu perfil": a pessoa só edita a si mesma (filter check sobre o registro).
    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:id))
    end

    # O aceite é sobre a própria conta e mais ninguém — mesmo filtro do perfil. Registrar aceite
    # em nome de terceiro é forjar prova, e é por isso que esta linha existe mesmo sendo a
    # fronteira de autenticação (que já tem o usuário da sessão em mãos) a única a chamar.
    policy action(:accept_terms) do
      authorize_if expr(id == ^actor(:id))
    end

    # "Sair de todos os dispositivos": revoga todos os tokens do usuário. Ação genérica, então
    # a checagem é sobre o argumento `:user` do input (ver ActorIsTargetUser), não um filtro.
    policy action(:log_out_everywhere) do
      authorize_if Api.Accounts.User.Checks.ActorIsTargetUser
    end

    # Um usuário enxerga a si mesmo; além disso, qualquer membro ATIVO de uma clínica
    # enxerga os demais membros dela (a tela de Equipe & acessos é visível a todos e precisa
    # de nome/e-mail dos co-membros). Continua sendo isolamento por tenant: só se vê quem
    # compartilha uma clínica onde o actor é membro ativo — espelho da read policy do
    # Membership.
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))

      authorize_if expr(
                     exists(
                       memberships.clinic.memberships,
                       user_id == ^actor(:id) and status == :ativo
                     )
                   )
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :nome, :string, allow_nil?: false, public?: true

    # Case-insensitive **e** guardado em minúsculas. As duas coisas são diferentes, e só a
    # primeira vinha de graça: `:ci_string` (citext) faz `Ana@Example.com` e `ana@example.com`
    # COMPARAREM iguais — o login e a identity `unique_email` sempre estiveram certos —, mas a
    # coluna guardava a caixa que a pessoa digitou, e ela aparece em tudo que lê o valor cru: a
    # lista da equipe, o destinatário do e-mail, a trilha de auditoria.
    #
    # `casing: :lower` descarta a caixa no **cast do tipo**, e é por isso que ele mora aqui e não
    # numa change: pega os três caminhos que criam usuário (magic link, convite por e-mail e
    # Google) sem que nenhum deles precise lembrar da regra. É a mesma decisão de
    # `Api.Changes.Canonicalizar` para a ficha do paciente e do profissional (doc 89).
    attribute :email, :ci_string,
      allow_nil?: false,
      public?: true,
      constraints: [casing: :lower]

    # A foto de perfil vive no bucket privado (R2), como todo byte do projeto — nunca no Postgres
    # e nunca como link para o Google. Guardar a URL do Google pareceria mais simples e traria
    # três problemas: o browser do usuário passaria a discar para o `googleusercontent.com` em
    # toda tela (a CSP teria de abrir esse destino, e o Google veria quem está usando o app e
    # quando), o link morre quando a pessoa troca a foto lá, e o app perde o dado se o Google
    # tirar o acesso. Ver `Api.Accounts.AvatarSyncJob`.
    #
    # `avatar_key` é o endereço no bucket (derivado do id, `Api.Accounts.User.Avatar.chave/2`);
    # nulo = sem foto, e a tela cai nas iniciais.
    attribute :avatar_key, :string, public?: false

    # A URL da foto **no Google**, do jeito que veio no `user_info` quando o job a processou —
    # tendo ele guardado a foto **ou recusado**. Não é para exibir: junto com `avatar_key` nula,
    # ela é a resposta a "esta conta já passou pela busca de foto?", que é o gatilho de
    # `Api.Accounts.User.Changes.SyncGoogleAvatar`. Sem ela, uma conta cuja foto foi recusada
    # tentaria de novo a cada login — e a pessoa loga todo dia.
    attribute :avatar_origem, :string, public?: false

    # O aceite dos Termos e da Política de Privacidade (`[D-14]`, doc 101 A4).
    #
    # Antes disto o aceite era **presumido**: `/criar-conta` traz a nota "ao criar sua conta você
    # concorda com…", e nada era gravado. Em disputa, dava para mostrar que o texto estava na tela
    # naquela versão do código — não que *aquela pessoa* passou por ele em *determinada data*.
    #
    # `public? false` porque não é campo de formulário: quem os escreve é `:accept_terms`, com a
    # versão vinda de quem **exibiu** o texto (o BFF, de `web/src/lib/legal.ts`). A API não guarda
    # uma cópia do número da versão de propósito — seria o quinto espelho do A5, e o que
    # apodreceria em silêncio seria justamente o registro legal.
    attribute :termos_aceitos_em, :utc_datetime, public?: false

    attribute :termos_versao, :string, public?: false, constraints: [max_length: 20]

    timestamps()
  end

  relationships do
    has_many :memberships, Api.Accounts.Membership
  end

  identities do
    identity :unique_email, [:email]
  end
end
