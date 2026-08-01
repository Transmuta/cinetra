defmodule ApiWeb.Plugs.CacheRawBody do
  @moduledoc """
  Guarda o corpo **cru** da requisição para as rotas que precisam verificá-lo byte a byte.

  ## Por que isso é necessário

  Assinatura de webhook (Svix no Resend, HMAC-SHA256 cru na Zernio) é um HMAC sobre os **bytes
  exatos** que o provider enviou. Depois que o `Plug.Parsers` decodifica o JSON, reserializar o
  mapa produz bytes *diferentes* — ordem de chaves, escapes, espaços — e a assinatura não fecha. O
  sintoma é o pior possível para depurar: todo webhook legítimo recusado com "assinatura
  inválida", sem nada de errado no segredo.

  ## Por que só em algumas rotas

  Guardar o corpo de **toda** requisição significa manter cada upload e cada payload em memória
  duas vezes. Este body reader só armazena quando o caminho está na lista — hoje, os dois
  webhooks de provider.

  Instalado como `body_reader` do `Plug.Parsers` (é o único ponto em que se pode ver os bytes
  antes da decodificação).
  """

  # Os caminhos que precisam do corpo cru. Lista explícita, e não um prefixo: um prefixo
  # `/webhooks` faria qualquer rota nova por baixo dele passar a reter corpo sem ninguém decidir.
  @caminhos ["/webhooks/resend", "/webhooks/zernio"]

  # Teto de corpo **próprio** para webhook (doc 96, L-1).
  #
  # `/webhooks/*` é o único caminho de escrita publicamente alcançável pelo Traefik, e está fora
  # dos dois estágios de rate limit por decisão registrada no router (a rajada de eventos de
  # entrega do mesmo IP do provider estouraria os 200/min). A decisão é boa; o efeito colateral
  # não tinha sido considerado: com o default de 8 MB do `Plug.Parsers`, cada requisição anônima
  # retinha ~8 MB de corpo cru em `conn.private[:raw_body]` **mais** o mapa decodificado. Medido:
  # um POST de 7,5 MB era lido e bufferizado inteiro antes de virar 401.
  #
  # 256 KB é ordens de grandeza acima de qualquer evento de Resend ou Zernio. O corte é
  # fail-closed por construção: corpo maior que o teto não fecha assinatura de qualquer forma.
  @max_webhook_bytes 256 * 1024

  @doc "Body reader do `Plug.Parsers`: lê o corpo e o guarda em `conn.private` quando é rota de webhook."
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, limitar(conn, opts)) do
      {:ok, corpo, conn} -> {:ok, corpo, guardar(conn, corpo)}
      {:more, corpo, conn} -> {:more, corpo, guardar(conn, corpo)}
      outro -> outro
    end
  end

  @doc "O corpo cru guardado, ou `nil` se a rota não é das que retêm."
  def raw_body(conn), do: conn.private[:raw_body]

  # O teto só se aplica às rotas de webhook: as autenticadas seguem com o limite global (upload
  # de anexo passa por aqui e é legitimamente grande).
  defp limitar(conn, opts) do
    if conn.request_path in @caminhos do
      Keyword.put(opts, :length, @max_webhook_bytes)
    else
      opts
    end
  end

  defp guardar(conn, corpo) do
    if conn.request_path in @caminhos do
      # Concatena porque `{:more, ...}` chega em pedaços: um corpo maior que o limite de leitura
      # viria truncado se cada pedaço substituísse o anterior — e a assinatura falharia só para
      # payloads grandes, que é o defeito que não aparece em teste com payload pequeno.
      Plug.Conn.put_private(conn, :raw_body, (conn.private[:raw_body] || "") <> corpo)
    else
      conn
    end
  end
end
