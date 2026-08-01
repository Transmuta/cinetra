defmodule ApiWeb.ResendWebhookController do
  @moduledoc """
  O webhook de entrega do Resend (doc 52 §2.1/§10.2).

  ## A primeira rota pública sem sessão fora do auth

  Não passa por `:authenticated`, não tem `Api.Scope` e não sabe de qual clínica é o evento. O
  que a protege é a **assinatura** (`Api.Messaging.Svix`), conferida antes de qualquer leitura de
  banco. Errar isso não vaza dado — o corpo é do provider —, mas deixaria qualquer um mudar o
  estado de entrega de uma mensagem cujo id conhecesse.

  ## Responde 200 mesmo para evento que não processou

  Deliberado. O provider reentrega enquanto não receber 2xx, então um erro devolvido para algo
  que **nunca** será processável (mensagem de outro ambiente, linha já podada) vira reentrega
  eterna. Só a assinatura inválida responde 401 — aí a reentrega é o comportamento certo, porque
  a causa pode ser um segredo desatualizado do nosso lado.

  ## Sem segredo configurado, o endpoint recusa tudo

  `fail closed`. A alternativa — aceitar sem verificar quando não há segredo — transformaria um
  esquecimento de configuração num endpoint aberto de escrita, e o sintoma seria nenhum.
  """
  use ApiWeb, :controller

  require Logger

  alias Api.Messaging
  alias Api.Messaging.Svix
  alias Api.Messaging.Webhooks
  alias ApiWeb.Plugs.CacheRawBody

  # POST /webhooks/resend
  def create(conn, params) do
    corpo = CacheRawBody.raw_body(conn) || ""

    case Svix.verificar(corpo, conn.req_headers, segredo()) do
      :ok ->
        # A mesma barreira do irmão da Zernio (doc 96, S-7). Aqui ela é **cinto e suspensório**: o
        # Svix já valida timestamp com tolerância de 300 s, então o replay tardio não passa da
        # assinatura. Entra assim mesmo porque a propriedade "um evento é processado uma vez" não
        # deve depender de qual provider mandou — a diferença entre os dois é acidente de qual
        # biblioteca cada um escolheu, e uma barreira que existe só em um dos caminhos é a que
        # some quando alguém trocar de provider.
        if Messaging.webhook_visto("resend", corpo) == :novo do
          Webhooks.processar(params)
        end

        json(conn, %{ok: true})

      {:error, motivo} ->
        # O motivo vai para o log, **não** para a resposta: uma resposta que distingue "sem
        # header" de "assinatura errada" diz ao atacante o que ajustar na tentativa seguinte.
        Logger.warning("webhook do Resend recusado: #{inspect(motivo)}")

        conn |> put_status(:unauthorized) |> json(%{error: "assinatura_invalida"})
    end
  end

  defp segredo, do: Application.get_env(:api, Api.Messaging, [])[:resend_webhook_secret]
end
