defmodule ApiWeb.Plugs.CacheRawBody do
  @moduledoc """
  Guarda o corpo **cru** da requisição para as rotas que precisam verificá-lo byte a byte.

  ## Por que isso é necessário

  Assinatura de webhook (Svix, no Resend) é um HMAC sobre os **bytes exatos** que o provider
  enviou. Depois que o `Plug.Parsers` decodifica o JSON, reserializar o mapa produz bytes
  *diferentes* — ordem de chaves, escapes, espaços — e a assinatura não fecha. O sintoma é o pior
  possível para depurar: todo webhook legítimo recusado com "assinatura inválida", sem nada de
  errado no segredo.

  ## Por que só em algumas rotas

  Guardar o corpo de **toda** requisição significa manter cada upload e cada payload em memória
  duas vezes. Este body reader só armazena quando o caminho está na lista — hoje, o webhook.

  Instalado como `body_reader` do `Plug.Parsers` (é o único ponto em que se pode ver os bytes
  antes da decodificação).
  """

  # Os caminhos que precisam do corpo cru. Lista explícita, e não um prefixo: um prefixo
  # `/webhooks` faria qualquer rota nova por baixo dele passar a reter corpo sem ninguém decidir.
  @caminhos ["/webhooks/resend"]

  @doc "Body reader do `Plug.Parsers`: lê o corpo e o guarda em `conn.private` quando é rota de webhook."
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, corpo, conn} -> {:ok, corpo, guardar(conn, corpo)}
      {:more, corpo, conn} -> {:more, corpo, guardar(conn, corpo)}
      outro -> outro
    end
  end

  @doc "O corpo cru guardado, ou `nil` se a rota não é das que retêm."
  def raw_body(conn), do: conn.private[:raw_body]

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
