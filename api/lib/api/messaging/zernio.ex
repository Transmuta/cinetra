defmodule Api.Messaging.Zernio do
  @moduledoc """
  O transporte de **WhatsApp** (doc 52 §9, fase 2), pela API da Zernio.

  Implementa `Api.Messaging.Transport`: recebe a `Message` e o corpo já renderizado, devolve
  `{:ok, "zernio", id}` ou `{:error, motivo}`. Quem decide *se* manda e *por onde* continua sendo
  o `Api.Messaging.Dispatch` — aqui só se entrega.

  ## Uma conversa é aberta com template, não com texto

  O endpoint é `POST /inbox/conversations`, e não o de mandar mensagem numa conversa existente.
  A razão é da Meta, não da Zernio: **o WhatsApp não permite texto livre para abrir conversa**.
  Fora da janela de 24 h de atendimento só sai template HSM aprovado, e é isso que toda mensagem
  nossa é — confirmação, lembrete, remarcação e cancelamento nascem de um agendamento, nunca de
  alguém digitando.

  Chamar este endpoint para um número com quem já existe thread manda o template para dentro dela.
  Ou seja: **um caminho só**, com ou sem conversa aberta. É o que dispensa guardar `conversationId`
  do nosso lado e o que faz a reabertura depois das 24 h não ser um caso especial.

  ## Os parâmetros do template são uma lista plana, e a ordem é contrato

  A Zernio repassa `templateParams` como um array único: primeiro as variáveis do cabeçalho de
  texto, depois as do corpo, depois **um valor por botão de URL dinâmica**, na ordem dos botões.
  Não há nome de variável no envio — se a ordem daqui divergir da ordem aprovada na Meta, a
  mensagem sai com a data no lugar do nome e ninguém percebe pelo código de retorno (a API aceita:
  a contagem bate).

  Por isso a ordem é montada num lugar só, `Api.Messaging.Templates.render_whatsapp/2`, junto do
  texto aprovado — e o teste que a protege compara com o texto do template, não com uma lista
  literal repetida no teste.

  ## O telefone vai em dígitos

  `participantId` é o telefone "em formato internacional (dígitos, com código do país)". O nosso
  `destino` é E.164 com `+` (é assim que o `OptOut` compara), então o `+` sai aqui — na borda,
  não no modelo.

  ## `Idempotency-Key` é aposta barata

  A janela entre "o provider aceitou" e "gravamos `:enviado`" é a que duplica mensagem numa
  retentativa do Oban (ver `Api.Messaging.SendJob`). A Zernio documenta `Idempotency-Key` em
  vários endpoints de escrita; mandamos o id da nossa mensagem. Se este endpoint honrar, a janela
  fecha; se ignorar, o header é inerte. **Não conte com ela** enquanto a primeira chamada real não
  provar — está na lista do doc 65 §6.

  ## O que este módulo NÃO faz

  Não cria template na Meta (isso é `mix cinetra.whatsapp.templates`, uma vez por conta, com lead
  time de dias) e não lê conversa. Ler a caixa de entrada do WhatsApp seria outra funcionalidade —
  e, pelo §9.1.5, é a que reabriria a decisão do número compartilhado.
  """
  @behaviour Api.Messaging.Transport

  require Logger

  @base_url_padrao "https://zernio.com/api/v1"
  @timeout 15_000

  @impl true
  def configurado? do
    config = config()

    preenchido?(config[:api_key]) and preenchido?(config[:account_id])
  end

  @impl true
  def entregar(message, corpo)

  def entregar(%{destino: destino, id: message_id} = message, %{
        nome: nome,
        idioma: idioma,
        params: params
      }) do
    corpo = %{
      accountId: conta(message),
      participantId: somente_digitos(destino),
      templateName: nome,
      templateLanguage: idioma,
      templateParams: params
    }

    :post
    |> requisicao("/inbox/conversations", corpo, message_id)
    |> interpretar()
  end

  # Corpo que não é template (um `render_email/2` que vazou para cá) nunca deve virar chamada: o
  # WhatsApp recusaria, mas só depois de gastar a rede e de o erro chegar à recepção como algo
  # ininteligível. Falhar aqui nomeia a causa.
  def entregar(_message, _corpo), do: {:error, "mensagem de WhatsApp sem template renderizado"}

  @doc """
  A conta (o número) pela qual esta clínica fala.

  O §9.1.4 pede que o número seja **configuração por clínica desde o primeiro dia**, mesmo com
  todas apontando para o mesmo: assim "a clínica nº 2 quer o número dela" vira um `UPDATE`, não
  uma refatoração. `Clinic.zernio_account_id` nulo cai no número compartilhado da Cinetra, que
  vem do ambiente.
  """
  def conta(%{vars: %{"zernio_account_id" => id}}) when is_binary(id) and id != "", do: id
  def conta(_message), do: config()[:account_id]

  @doc """
  Submete um template à aprovação da Meta (`POST /whatsapp/templates`).

  Fora do caminho de envio de propósito: roda **uma vez por conta**, pela mix task, e tem lead
  time de dias do outro lado. Devolve `{:ok, corpo}` ou `{:error, motivo}`.
  """
  def criar_template(payload) when is_map(payload) do
    case requisicao(:post, "/whatsapp/templates", payload, nil) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      outro -> interpretar(outro)
    end
  end

  # ---- interno ----

  # `:plug` só existe em teste (`Req.Test`), e é o que permite exercitar **este** módulo — o
  # mapeamento de status e de erro da Meta — sem rede e sem credencial. A alternativa seria
  # confiar num duplo do módulo inteiro, e aí o que o teste prova é o duplo.
  defp requisicao(metodo, caminho, corpo, idempotency_key) do
    config = config()

    [
      method: metodo,
      url: (config[:base_url] || @base_url_padrao) <> caminho,
      json: corpo,
      headers: cabecalhos(config, idempotency_key),
      retry: false,
      receive_timeout: config[:timeout] || @timeout
    ]
    |> then(&if(config[:plug], do: Keyword.put(&1, :plug, config[:plug]), else: &1))
    |> Req.request()
  end

  defp cabecalhos(config, idempotency_key) do
    [{"authorization", "Bearer #{config[:api_key]}"}]
    |> then(&if(idempotency_key, do: [{"idempotency-key", idempotency_key} | &1], else: &1))
  end

  defp interpretar({:ok, %{status: status, body: body}}) when status in 200..299 do
    case id_da_mensagem(body) do
      nil ->
        # Aceito sem id: a mensagem saiu, mas nenhum webhook de entrega vai achar esta linha
        # depois. Melhor `:enviado` sem rastro do que `:falhou` sobre algo que foi entregue.
        Logger.warning("zernio aceitou sem messageId")
        {:ok, "zernio", nil}

      id ->
        {:ok, "zernio", id}
    end
  end

  defp interpretar({:ok, %{status: status, body: body}}), do: {:error, motivo(status, body)}

  # Erro de rede/timeout: **levanta**, não devolve `{:error, _}`. É a distinção que o `SendJob`
  # usa — o que ele grava como falha não é retentado, e "a rede caiu" é exatamente o caso em que
  # a retentativa do Oban resolve sozinha. Gravar `:falhou` aqui queimaria as três tentativas
  # numa indisponibilidade de trinta segundos.
  defp interpretar({:error, motivo}) do
    raise "zernio indisponível: #{inspect(motivo)}"
  end

  defp id_da_mensagem(%{"data" => %{"messageId" => id}}) when is_binary(id) and id != "", do: id
  defp id_da_mensagem(%{"messageId" => id}) when is_binary(id) and id != "", do: id
  defp id_da_mensagem(_body), do: nil

  # O texto vai para a coluna `erro` e é traduzido na leitura por `Api.Messaging.Falhas`. Manter
  # `code` e `error` crus (e não uma frase nossa) é o que permite a tradução casar tanto o
  # vocabulário da Zernio quanto os códigos numéricos da Meta que ela repassa.
  defp motivo(status, %{"code" => code, "error" => erro}) when is_binary(code),
    do: "#{status} #{code}: #{texto(erro)}"

  defp motivo(status, %{"error" => erro}), do: "#{status}: #{texto(erro)}"
  defp motivo(status, %{"message" => msg}), do: "#{status}: #{texto(msg)}"
  defp motivo(status, corpo), do: "#{status}: #{texto(corpo)}"

  defp texto(valor) when is_binary(valor), do: String.slice(valor, 0, 200)
  defp texto(valor), do: valor |> inspect() |> String.slice(0, 200)

  defp somente_digitos(destino), do: Api.Texto.somente_digitos(destino)

  defp preenchido?(valor), do: is_binary(valor) and valor != ""

  defp config, do: Application.get_env(:api, __MODULE__, [])
end
