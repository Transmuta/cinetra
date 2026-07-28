defmodule Api.Messaging.Svix do
  @moduledoc """
  Verificação da assinatura de webhook no padrão **Svix** — que é o que o Resend usa (doc 52 §2.1).

  ## O que se assina

  O HMAC-SHA256 é sobre `"<svix-id>.<svix-timestamp>.<corpo cru>"`, com o segredo do endpoint
  (`whsec_...`, cuja parte após o prefixo é base64). O resultado vai no header `svix-signature`
  como `v1,<base64>` — podendo haver **várias** separadas por espaço, porque o Svix mantém as
  assinaturas antiga e nova durante uma rotação de segredo. Aceitar qualquer uma que bata é o
  comportamento correto; exigir a primeira quebraria toda rotação.

  ## Comparação em tempo constante

  `Plug.Crypto.secure_compare/2`, não `==`. Comparação byte a byte que sai no primeiro byte
  diferente vaza, pelo tempo de resposta, quanto do prefixo estava certo — e assinatura é
  exatamente o caso em que um atacante pode repetir a medida quantas vezes quiser.

  ## Tolerância de tempo

  Um replay de ontem, com assinatura legítima, precisa ser recusado — senão qualquer captura do
  payload vira uma reentrega infinita. A tolerância padrão do Svix é de 5 minutos para os dois
  lados (relógio de servidor adianta e atrasa).
  """
  @tolerancia_segundos 300

  @doc """
  A requisição é autêntica?

  Devolve `:ok` ou `{:error, motivo}` — os motivos existem para o log, não para a resposta: a
  resposta é sempre a mesma, senão ela vira um oráculo que diz ao atacante o que ajustar.
  """
  def verificar(corpo, headers, secret, agora \\ nil)

  def verificar(_corpo, _headers, secret, _agora) when secret in [nil, ""],
    do: {:error, :sem_segredo}

  def verificar(corpo, headers, secret, agora) do
    with {:ok, id} <- header(headers, "svix-id"),
         {:ok, timestamp} <- header(headers, "svix-timestamp"),
         {:ok, assinaturas} <- header(headers, "svix-signature"),
         :ok <- recente?(timestamp, agora || DateTime.utc_now()),
         {:ok, chave} <- decodificar(secret) do
      esperada = :crypto.mac(:hmac, :sha256, chave, "#{id}.#{timestamp}.#{corpo}")

      if alguma_bate?(assinaturas, esperada),
        do: :ok,
        else: {:error, :assinatura_invalida}
    end
  end

  # `v1,<base64> v1,<base64>` — várias durante rotação de segredo (ver o moduledoc).
  defp alguma_bate?(header, esperada) do
    header
    |> String.split(" ", trim: true)
    |> Enum.any?(fn parte ->
      case String.split(parte, ",", parts: 2) do
        ["v1", assinatura] -> confere?(assinatura, esperada)
        _ -> false
      end
    end)
  end

  defp confere?(assinatura_base64, esperada) do
    case Base.decode64(assinatura_base64) do
      {:ok, recebida} -> Plug.Crypto.secure_compare(recebida, esperada)
      :error -> false
    end
  end

  defp recente?(timestamp, agora) do
    case Integer.parse(timestamp) do
      {segundos, ""} ->
        if abs(DateTime.to_unix(agora) - segundos) <= @tolerancia_segundos,
          do: :ok,
          else: {:error, :fora_da_janela}

      _ ->
        {:error, :timestamp_invalido}
    end
  end

  # O segredo chega como `whsec_<base64>`; o prefixo é rótulo, não parte da chave.
  defp decodificar("whsec_" <> base64), do: decodificar(base64)

  defp decodificar(base64) do
    case Base.decode64(base64) do
      {:ok, chave} -> {:ok, chave}
      :error -> {:error, :segredo_invalido}
    end
  end

  defp header(headers, nome) do
    case List.keyfind(headers, nome, 0) do
      {^nome, valor} -> {:ok, valor}
      _ -> {:error, {:header_ausente, nome}}
    end
  end
end
