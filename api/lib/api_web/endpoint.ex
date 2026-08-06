defmodule ApiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :api

  # Sessão no cookie, CIFRADA e assinada (AEAD). Sem o :encryption_salt o cookie era só
  # assinado: íntegro, mas legível por base64 puro (a chave `user_token` e o JWT inteiro
  # à mostra para quem tivesse o valor). Os salts não são segredo — só derivam chaves
  # distintas do secret_key_base; trocá-los derruba as sessões ativas (doc 14 §2).
  #
  # `secure: true` e `max_age` não vinham do gerador e faltavam por omissão, não por decisão
  # (doc 96, S-8). O impacto prático é contido — o browser só toca esta API em `/socket`, e o BFF
  # reemite o cookie no domínio dele —, mas "contido por acidente de topologia" não é uma garantia:
  # basta alguém expor a API direto no Traefik para o cookie de sessão viajar em claro.
  #
  # `secure: true` não quebra a comunicação BFF↔API: ela é server-to-server e nunca lê este cookie
  # pelo browser. O `max_age` fecha o cookie de sessão eterno — 30 dias, o mesmo horizonte do
  # token que ele carrega.
  @session_options [
    store: :cookie,
    key: "_api_key",
    signing_salt: "QExDiC7H",
    encryption_salt: "319wcRWM",
    same_site: "Lax",
    secure: true,
    max_age: 60 * 60 * 24 * 30
  ]

  # O tempo real da agenda (ADR-004, Entrega 3). Autenticação pelo token efêmero, não pela
  # sessão — ver `ApiWeb.UserSocket`. Sem `longpoll`: o cliente é o pacote `phoenix` no
  # browser, e o fallback só acrescentaria superfície.
  #
  # `auth_token: true` (S2, Onda 5) faz o token chegar pelo subprotocolo `Sec-WebSocket-Protocol`
  # em vez da query string, onde vazava para log de proxy. É o mesmo interruptor dos dois lados:
  # sem ele aqui, o `authToken:` do cliente é ignorado e ninguém conecta.
  #
  # **A opção é do SOCKET, não do `websocket:`.** Escrita como `websocket: [auth_token: true]` ela
  # é silenciosamente anulada: o `put_auth_token/2` do Phoenix faz
  # `Keyword.put(websocket, :auth_token, opts[:auth_token])`, e com a chave ausente aqui fora o
  # `opts[:auth_token]` é `nil` — sobrescrevendo o `true` de dentro. O sintoma é 403 no handshake
  # com tudo verde no `mix test`, porque o `Phoenix.ChannelTest` injeta `connect_info` direto e
  # nunca passa pelo transporte. Achado ao vivo, no browser.
  socket "/socket", ApiWeb.UserSocket, auth_token: true, websocket: true, longpoll: false

  # `Plug.Static` e `Plug.MethodOverride` saíram (doc 96, M-3): são scaffolding de `mix phx.new`
  # numa API que só fala JSON. O primeiro servia `priv/static` — medido, `GET /robots.txt`
  # respondia 200 — e o segundo lê `_method` do corpo do formulário, que nenhuma rota deste
  # projeto usa. Superfície pública sem função é superfície a manter e a auditar.

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug AshPhoenix.Plug.CheckCodegenStatus
  end

  plug Plug.RequestId
  # Logo depois do `RequestId`, e pela mesma razão: carimbar o identificador no Logger antes de
  # qualquer plug que possa logar. O span já existe aqui — quem o abriu foi o
  # `opentelemetry_bandit`, no evento de início da requisição, antes de o Bandit chamar o plug.
  plug ApiWeb.Plugs.TraceMetadata
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # **O estágio de borda do rate limit, aqui e não no router** (doc 96, L-2).
  #
  # Ele já foi pipeline do router, e ali chegava tarde: `Plug.Parsers` roda logo abaixo, é plug do
  # endpoint, e portanto vinha ANTES — uma requisição destinada a levar 429 já tinha lido e
  # decodificado o corpo inteiro (até 8 MB). "Cortar a enxurrada antes do trabalho" só é verdade
  # deste lado da linha.
  #
  # Depois do `Plug.Telemetry` de propósito: a requisição barrada ainda precisa ser medida e
  # logada, senão o 429 vira o buraco de observabilidade que L-5 acabou de fechar.
  #
  # As isenções (`/webhooks`, health checks) são do próprio plug — ver `@sem_teto_de_borda`.
  plug ApiWeb.Plugs.RateLimitGlobal, stage: :edge

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    # Doc 52 §10.2: o webhook do Resend assina os **bytes** do corpo. Depois da decodificação,
    # reserializar o mapa produz bytes diferentes e a assinatura nunca fecha. Este body reader
    # retém o corpo cru — só nas rotas que precisam dele (ver o módulo).
    body_reader: {ApiWeb.Plugs.CacheRawBody, :read_body, []}

  plug Plug.Head
  plug Plug.Session, @session_options

  # Guarda o corpo da resposta das requisições RECUSADAS, para o `RequestLogger` logá-lo
  # (ADR-025). Precisa ficar aqui, imediatamente antes do router: `register_before_send/2` roda
  # os callbacks na ordem INVERSA do registro, então este é o último a ser registrado e o
  # primeiro a rodar — vê o corpo antes de qualquer outro plug ter chance de mexer nele.
  plug ApiWeb.Plugs.CapturarResposta

  plug ApiWeb.Router
end
