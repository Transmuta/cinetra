defmodule Api.Messaging.Webhooks do
  @moduledoc """
  O que fazer com um evento do provider (doc 52 §10.2, doc 65 §4) — a regra, separada da fronteira
  HTTP que a chama. Vale para os **dois** transportes: o Resend (e-mail) e a Zernio (WhatsApp).

  ## O problema que este módulo resolve primeiro: **o evento chega sem tenant**

  Nenhum dos dois providers sabe o que é uma clínica. O que eles mandam é o id da mensagem que
  eles mesmos devolveram no envio — e é por ele que se descobre de quem é a linha. A busca,
  portanto, precisa rodar **antes** de haver tenant, o que esbarra em duas camadas:

    * o Ash recusa query sem tenant em recurso por-tenant → `global? true` na multitenancy da
      `Message`, e um índice em `provider_message_id` com `all_tenants?: true`;
    * a RLS não casaria linha nenhuma sem GUC → a exceção estreita
      `Api.Repo.with_provider_message/2`, que alcança **uma** linha, já identificada por um
      payload autenticado (a policy está na migration `MessagingRls`, junto com a irmã: a
      resposta do paciente tem o mesmo problema e resolve com `Api.Repo.with_message/2`).

  Sem a segunda, o webhook responderia 200 sem fazer nada — para sempre, sem erro em lugar
  nenhum, e **verde no `mix test`**, onde o sandbox bypassa RLS. Todo o resto do trabalho já roda
  sob a GUC da clínica encontrada.

  O doc 52 §2 apostou que exercitar o webhook já na fase 1 pagaria a fase 2. Pagou: quando a
  Zernio entrou, esta parte — a que não se descobre sem escrever — já estava de pé, e o que
  sobrou foi um mapa de nomes de evento.

  ## Idempotência sem tabela de eventos vistos

  Os dois providers reentregam o mesmo evento quando não recebem 2xx a tempo (a Zernio tenta 7
  vezes, até 24 h), então repetição é o caso normal. Não há tabela de id já processado porque as
  duas escritas possíveis já são idempotentes por natureza:

    * **avanço de estado** é monotônico (`MessageStatus.avanca?/2`) — reaplicar `delivered` numa
      mensagem entregue é no-op;
    * **opt-out** é verificado antes de gravar (`Api.Messaging.opt_out/4`).

  Uma tabela a mais daria a mesma garantia com custo de escrita e de poda. O que ela acrescentaria
  é proteção contra *reprocessar* eventos muito antigos — e disso o Resend cuida pela janela de
  tolerância da assinatura (`Api.Messaging.Svix`). **A Zernio não tem essa janela**
  (`Api.Messaging.ZernioSignature` explica), então ali a idempotência é a única defesa: acrescentar
  um evento de efeito não-idempotente exige a tabela primeiro.

  ## `complained` é opt-out imediato, `bounced` não é

  A distinção é do §10.2 e é de produto, não de implementação:

    * **marcou como spam** → a pessoa disse, do jeito mais claro que existe, para parar. Vira
      opt-out sem perguntar;
    * **bounce** → o endereço não existe ou não aceita. Isso não é vontade de ninguém: é um
      destino inválido. Vira falha da mensagem, e a recepção corrige a ficha.

  Tratar bounce como opt-out silenciaria para sempre um paciente cujo e-mail foi digitado errado.

  No WhatsApp o par é outro: **palavra-chave** (`SAIR`, `PARE`, `STOP`, `CANCELAR`) é opt-out, e
  falha de entrega — inclusive "este número não tem WhatsApp" — é falha da mensagem. Mesma régua,
  vocabulário diferente.
  """
  require Logger

  alias Api.Messaging
  alias Api.Messaging.Dispatch

  # O que cada evento do Resend significa na nossa máquina (§4). `email.sent` não entra: o estado
  # `:enviado` já foi gravado por nós no momento em que o provider aceitou, e reafirmá-lo seria
  # trabalho sem informação nova.
  @estados %{
    "email.delivered" => :entregue,
    "email.bounced" => :falhou,
    "email.delivery_delayed" => nil,
    "email.complained" => nil
  }

  # O mesmo para a Zernio. `message.sent` fica de fora pela mesma razão que `email.sent`, e
  # `message.read` **existe de verdade** aqui — é o estado que o e-mail nunca alcança (C4 recusou
  # o pixel de rastreio), e a razão de `:lido` já estar na máquina desde a fase 1.
  @estados_zernio %{
    "message.delivered" => :entregue,
    "message.read" => :lido,
    "message.failed" => :falhou
  }

  # O que o paciente escreve para parar (doc 52 §10).
  #
  # A mensagem **inteira** tem de ser a palavra — não basta contê-la, nem tê-la como uma palavra
  # solta no meio. O contra-exemplo que decidiu isto está no teste: *"por favor, não pare de
  # mandar os lembretes"* contém `pare` como palavra inteira e quer dizer o **oposto**. Silenciar
  # quem pediu para continuar é o pior dos dois erros possíveis aqui, porque é invisível: a pessoa
  # simplesmente para de receber e ninguém sabe por quê.
  #
  # É também a convenção do canal: no WhatsApp o opt-out por palavra-chave é a mensagem inteira.
  # Quem quer sair escreve "SAIR", não uma frase.
  @palavras_de_saida ~w(sair pare parar stop cancelar descadastrar remover)

  @doc """
  Processa um evento do **Resend** já autenticado (a assinatura é verificada na fronteira).

  Devolve sempre `:ok`. Evento de mensagem que não conhecemos — de outro ambiente apontando para
  o mesmo endpoint, ou de uma mensagem já podada — é ignorado de propósito: responder erro faria
  o provider reentregar para sempre algo que nunca vai ser processável.
  """
  def processar(%{"type" => tipo, "data" => dados}) do
    case localizar(id_do_resend(dados)) do
      {:ok, message} -> aplicar(tipo, message, dados)
      :error -> :ok
    end
  end

  def processar(_evento), do: :ok

  @doc """
  Processa um evento da **Zernio** já autenticado.

  Mesmo contrato do `processar/1`: sempre `:ok`, e evento não reconhecido é silêncio deliberado.
  """
  def processar_zernio(%{"event" => "message.received"} = evento) do
    responder_entrada(evento)
  end

  def processar_zernio(%{"event" => tipo} = evento) do
    with estado when not is_nil(estado) <- Map.get(@estados_zernio, tipo),
         {:ok, message} <- localizar(ids_da_zernio(evento)) do
      avancar(message, estado, motivo_zernio(evento))
    else
      _ -> :ok
    end
  end

  def processar_zernio(_evento), do: :ok

  # ---- entrada (só a Zernio tem): o paciente escreveu ----

  # A resposta que importa (confirmar/remarcar) chega pelo **link assinado**, não por aqui — é o
  # C3, e num número compartilhado é o que diz de qual clínica o paciente fala (§9.1.4). O que
  # sobra para o texto livre é a única coisa que ele decide sozinho, sem contexto: parar de
  # receber.
  #
  # Global (sem `clinic_id`), pelo mesmo motivo do `complained`: com remetente único da Cinetra o
  # paciente pediu para a Cinetra parar, não para uma clínica. É o C10 sendo lido como o §9.1.1
  # previu — com um número só, opt-out global **é** o que a pessoa quis dizer.
  defp responder_entrada(evento) do
    with texto when is_binary(texto) <- texto_da_entrada(evento),
         true <- saida?(texto),
         destino when is_binary(destino) <- remetente(evento) do
      Messaging.opt_out(:whatsapp, destino, "palavra-chave", motivo: String.slice(texto, 0, 100))
    end

    :ok
  end

  defp saida?(texto) do
    texto
    |> String.downcase()
    |> String.replace(~r/[^\p{L}]/u, "")
    |> Kernel.in(@palavras_de_saida)
  end

  # O telefone precisa sair daqui no MESMO formato em que `destino` foi congelado no envio, senão
  # o opt-out grava uma linha que nunca casa com nada. Quem normaliza é o `Dispatch`, o mesmo
  # módulo que normalizou na hora de escolher o canal.
  defp remetente(evento) do
    evento
    |> caminhos([
      ["message", "sender", "id"],
      ["message", "sender", "username"],
      ["message", "senderId"],
      ["message", "from"],
      ["conversation", "participantId"]
    ])
    |> Enum.find_value(&Dispatch.normalizar(:whatsapp, &1))
  end

  defp texto_da_entrada(evento) do
    evento
    |> caminhos([["message", "text"], ["message", "message"], ["message", "body"]])
    |> List.first()
  end

  # ---- comum aos dois providers ----

  # A busca que **descobre** o tenant — ver o moduledoc. Roda sob a GUC do id do provider, que é a
  # exceção estreita da RLS (`Api.Repo.with_provider_message/2`): sem ela a policy de `messages`
  # não casaria linha nenhuma e o webhook responderia 200 sem fazer nada, para sempre.
  #
  # `authorize?: false` porque não há sessão; o que autoriza a chamada é a assinatura conferida
  # antes dela.
  #
  # Recebe uma **lista** de candidatos porque a Zernio não promete que o id do webhook seja o
  # mesmo que ela devolveu no envio (doc 65 §6, incerteza 2): tentar os dois campos plausíveis é
  # mais barato do que descobrir em produção que nenhum evento de entrega casa.
  defp localizar(candidatos) do
    candidatos
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.find_value(:error, fn id ->
      case buscar(id) do
        {:ok, message} -> {:ok, message}
        :error -> nil
      end
    end)
  end

  defp buscar(id) do
    Api.Repo.with_provider_message(id, fn ->
      case Messaging.get_message_by_provider_id(id, authorize?: false, not_found_error?: false) do
        {:ok, %{} = message} -> {:ok, message}
        _ -> :error
      end
    end)
    |> elem(1)
  end

  defp id_do_resend(%{"email_id" => id}), do: [id]
  defp id_do_resend(_dados), do: []

  defp ids_da_zernio(evento) do
    caminhos(evento, [
      ["message", "id"],
      ["message", "platformMessageId"],
      ["message", "providerMessageId"],
      ["messageId"]
    ])
  end

  defp aplicar("email.complained", message, _dados) do
    # Spam report: opt-out imediato, sem perguntar. Global (sem `clinic_id`) porque com remetente
    # único da Cinetra (C11) o paciente marcou "a Cinetra" como spam, não uma clínica específica.
    Messaging.opt_out(message.canal, message.destino, "spam", motivo: "marcou como spam")

    avancar(message, :falhou, "destinatário marcou como spam")
  end

  defp aplicar(tipo, message, dados) do
    case Map.get(@estados, tipo) do
      nil -> :ok
      estado -> avancar(message, estado, motivo(dados))
    end
  end

  defp avancar(message, estado, motivo) do
    Api.Repo.with_clinic(message.clinic_id, fn ->
      Messaging.do_advance_message!(message, %{novo_status: estado, erro: motivo},
        tenant: message.clinic_id,
        authorize?: false
      )
    end)

    :ok
  rescue
    erro ->
      Logger.warning("webhook não aplicou #{estado} em #{message.id}: #{Exception.message(erro)}")
      :ok
  end

  defp motivo(%{"reason" => texto}) when is_binary(texto), do: texto
  defp motivo(_dados), do: nil

  # O `errorCode` numérico da Meta viaja junto do texto de propósito: é ele que `Api.Messaging.Falhas`
  # casa para dizer "este número não tem WhatsApp" em vez de "não conseguimos entregar".
  defp motivo_zernio(evento) do
    codigo =
      evento
      |> caminhos([["error", "code"], ["message", "deliveryError", "code"]])
      |> List.first()

    texto =
      evento
      |> caminhos([
        ["error", "message"],
        ["error", "title"],
        ["message", "deliveryError", "message"]
      ])
      |> List.first()

    case {codigo, texto} do
      {nil, nil} -> nil
      {nil, texto} -> texto
      {codigo, nil} -> to_string(codigo)
      {codigo, texto} -> "#{codigo}: #{texto}"
    end
  end

  # Lê vários caminhos possíveis de um payload aninhado e devolve os que existem, na ordem pedida.
  # O payload de webhook é o contrato de terceiro que mais muda de forma sem aviso; escrever
  # `evento["message"]["id"]` direto estoura em `nil` no primeiro campo renomeado.
  #
  # Anda o caminho à mão em vez de `get_in/2` porque `get_in` **levanta** quando um nível
  # intermediário não é mapa (`message` chegar como string, por exemplo) — e derrubar o webhook
  # por causa da forma do payload alheio faz o provider reentregar o mesmo erro sete vezes.
  defp caminhos(mapa, listas) do
    Enum.flat_map(listas, fn caminho ->
      case percorrer(mapa, caminho) do
        nil -> []
        valor -> [valor]
      end
    end)
  end

  defp percorrer(valor, []), do: valor

  defp percorrer(mapa, [chave | resto]) when is_map(mapa),
    do: percorrer(Map.get(mapa, chave), resto)

  defp percorrer(_valor, _caminho), do: nil
end
