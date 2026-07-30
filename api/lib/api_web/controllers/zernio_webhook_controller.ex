defmodule ApiWeb.ZernioWebhookController do
  @moduledoc """
  O webhook da Zernio — entrega e resposta do WhatsApp (doc 65 §4).

  Irmão do `ApiWeb.ResendWebhookController`, e as decisões são as mesmas pelas mesmas razões:
  rota pública sem sessão, protegida pela **assinatura** conferida antes de qualquer leitura de
  banco; 200 para evento que não processou (erro faria o provider reentregar para sempre algo que
  nunca será processável); 401 só para assinatura inválida, onde a reentrega é o comportamento
  certo porque a causa pode ser um segredo desatualizado do nosso lado; e `fail closed` sem
  segredo configurado.

  ## A diferença que não é cosmética: ack em 5 segundos

  A Zernio considera falha qualquer resposta que passe de **5 s** e reentrega até 7 vezes. O
  processamento aqui é curto (uma busca por id e um update), mas é o tipo de coisa que degrada
  sem ninguém notar — se um dia ele crescer, a saída é enfileirar e responder, não otimizar o
  caminho síncrono.
  """
  use ApiWeb, :controller

  require Logger

  alias Api.Messaging.Webhooks
  alias Api.Messaging.ZernioSignature
  alias ApiWeb.Plugs.CacheRawBody

  # POST /webhooks/zernio
  def create(conn, params) do
    corpo = CacheRawBody.raw_body(conn) || ""

    case ZernioSignature.verificar(corpo, conn.req_headers, segredo()) do
      :ok ->
        Webhooks.processar_zernio(params)
        json(conn, %{ok: true})

      {:error, motivo} ->
        # O motivo vai para o log, **não** para a resposta: uma resposta que distingue "sem
        # header" de "assinatura errada" diz ao atacante o que ajustar na tentativa seguinte.
        Logger.warning("webhook da Zernio recusado: #{inspect(motivo)}")

        conn |> put_status(:unauthorized) |> json(%{error: "assinatura_invalida"})
    end
  end

  defp segredo, do: Application.get_env(:api, Api.Messaging, [])[:zernio_webhook_secret]
end
