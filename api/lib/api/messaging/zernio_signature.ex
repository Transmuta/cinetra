defmodule Api.Messaging.ZernioSignature do
  @moduledoc """
  Verificação da assinatura de webhook da **Zernio** (doc 65 §4).

  ## O que se assina

  HMAC-SHA256 do **corpo cru**, com o segredo do endpoint, em hexadecimal minúsculo no header
  `x-zernio-signature`. Sem prefixo `sha256=`, sem timestamp, sem lista de assinaturas.

  É mais simples que o Svix do Resend (`Api.Messaging.Svix`) — e mais fraco. As duas diferenças
  importam e estão registradas aqui porque nenhuma delas é escolha nossa:

  ## Não há janela de tempo, e isso é um buraco de replay

  O Svix assina `id.timestamp.corpo` e recusa evento de ontem; aqui não há timestamp nenhum no
  material assinado, então **um payload capturado continua válido para sempre**. Quem tiver um
  corpo assinado legítimo pode reentregá-lo quando quiser.

  **Quem fecha isso é `Api.Messaging.WebhookEvent`** — a tabela de corpos já vistos, consultada
  pelo `ApiWeb.ZernioWebhookController` antes de processar. Ela é a metade que faltava da
  autenticação deste endpoint: a assinatura diz *quem* mandou, e ela diz *se já aconteceu*.

  ### Por que a idempotência dos efeitos não bastava (doc 96, S-7)

  Este texto já dizia que replay não muda o banco, porque o avanço de estado é monotônico
  (`Api.Messaging.MessageStatus.avanca?/2`) e o opt-out era verificado antes de gravar. O
  argumento estava incompleto, e o furo não era um evento novo — era uma ação **do outro lado**:
  `Api.Messaging.revoke_opt_out/3` desfaz um opt-out. Entre o `SAIR` original e o replay cabe uma
  revogação, e o replay a desfaz, ressilenciando quem tinha pedido para voltar a receber.

  A condição que este módulo punha como gatilho para a tabela ("se um dia um evento passar a ter
  efeito não-idempotente") estava, portanto, satisfeita havia tempo — só não pelo caminho que o
  texto vigiava.

  ## Comparação em tempo constante

  `Plug.Crypto.secure_compare/2`, não `==`. Comparação byte a byte que sai no primeiro byte
  diferente vaza, pelo tempo de resposta, quanto do prefixo estava certo — e assinatura é
  exatamente o caso em que um atacante pode repetir a medida quantas vezes quiser.
  """

  @doc """
  A requisição é autêntica?

  Devolve `:ok` ou `{:error, motivo}` — os motivos existem para o log, não para a resposta: a
  resposta é sempre a mesma, senão ela vira um oráculo que diz ao atacante o que ajustar.
  """
  def verificar(corpo, headers, secret)

  def verificar(_corpo, _headers, secret) when secret in [nil, ""], do: {:error, :sem_segredo}

  def verificar(corpo, headers, secret) do
    with {:ok, recebida} <- header(headers, "x-zernio-signature") do
      esperada = :crypto.mac(:hmac, :sha256, secret, corpo) |> Base.encode16(case: :lower)

      # `String.downcase` na assinatura recebida, não na esperada: hex maiúsculo é a mesma
      # assinatura, e recusá-lo seria recusar entrega legítima por causa de formatação. O valor
      # vem do atacante em potencial, então normalizá-lo não vaza nada — o segredo não passa por
      # aqui.
      if Plug.Crypto.secure_compare(String.downcase(recebida), esperada),
        do: :ok,
        else: {:error, :assinatura_invalida}
    end
  end

  defp header(headers, nome) do
    case List.keyfind(headers, nome, 0) do
      {^nome, valor} when is_binary(valor) and valor != "" -> {:ok, valor}
      _ -> {:error, {:header_ausente, nome}}
    end
  end
end
