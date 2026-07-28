defmodule Api.Messaging.Webhooks do
  @moduledoc """
  O que fazer com um evento de entrega do provider (doc 52 §10.2) — a regra, separada da
  fronteira HTTP que a chama.

  ## O problema que este módulo resolve primeiro: **o evento chega sem tenant**

  O Resend não sabe o que é uma clínica. O que ele manda é o id da mensagem que ele mesmo
  devolveu no envio — e é por ele que se descobre de quem é a linha. A busca, portanto, precisa
  rodar **antes** de haver tenant, o que esbarra em duas camadas:

    * o Ash recusa query sem tenant em recurso por-tenant → `global? true` na multitenancy da
      `Message`, e um índice em `provider_message_id` com `all_tenants?: true`;
    * a RLS não casaria linha nenhuma sem GUC → a exceção estreita
      `Api.Repo.with_provider_message/2`, que alcança **uma** linha, já identificada por um
      payload autenticado (a policy está na migration `MessagingRls`, junto com a irmã: a
      resposta do paciente tem o mesmo problema e resolve com `Api.Repo.with_message/2`).

  Sem a segunda, o webhook responderia 200 sem fazer nada — para sempre, sem erro em lugar
  nenhum, e **verde no `mix test`**, onde o sandbox bypassa RLS. Todo o resto do trabalho já roda
  sob a GUC da clínica encontrada.

  É o mesmo problema que a fase 2 terá com a Gupshup, e a razão pela qual o doc 52 §2 insiste em
  exercitar o webhook já na fase 1: essa é a parte que não se descobre sem escrever.

  ## Idempotência sem tabela de eventos vistos

  O Resend reentrega o mesmo evento quando não recebe 2xx a tempo, então repetição é o caso
  normal. Não há tabela de `svix-id` já processados porque as duas escritas possíveis já são
  idempotentes por natureza:

    * **avanço de estado** é monotônico (`MessageStatus.avanca?/2`) — reaplicar `delivered` numa
      mensagem entregue é no-op;
    * **opt-out** é verificado antes de gravar (`Api.Messaging.opt_out/4`).

  Uma tabela a mais daria a mesma garantia com custo de escrita e de poda. O que ela acrescentaria
  é proteção contra *reprocessar* eventos muito antigos — e disso cuida a janela de tolerância da
  assinatura (`Api.Messaging.Svix`).

  ## `complained` é opt-out imediato, `bounced` não é

  A distinção é do §10.2 e é de produto, não de implementação:

    * **marcou como spam** → a pessoa disse, do jeito mais claro que existe, para parar. Vira
      opt-out sem perguntar;
    * **bounce** → o endereço não existe ou não aceita. Isso não é vontade de ninguém: é um
      destino inválido. Vira falha da mensagem, e a recepção corrige a ficha.

  Tratar bounce como opt-out silenciaria para sempre um paciente cujo e-mail foi digitado errado.
  """
  require Logger

  alias Api.Messaging

  # O que cada evento do Resend significa na nossa máquina (§4). `email.sent` não entra: o estado
  # `:enviado` já foi gravado por nós no momento em que o provider aceitou, e reafirmá-lo seria
  # trabalho sem informação nova.
  @estados %{
    "email.delivered" => :entregue,
    "email.bounced" => :falhou,
    "email.delivery_delayed" => nil,
    "email.complained" => nil
  }

  @doc """
  Processa um evento já **autenticado** (a assinatura é verificada na fronteira).

  Devolve sempre `:ok`. Evento de mensagem que não conhecemos — de outro ambiente apontando para
  o mesmo endpoint, ou de uma mensagem já podada — é ignorado de propósito: responder erro faria
  o provider reentregar para sempre algo que nunca vai ser processável.
  """
  def processar(%{"type" => tipo, "data" => dados}) do
    case localizar(dados) do
      {:ok, message} -> aplicar(tipo, message, dados)
      :error -> :ok
    end
  end

  def processar(_evento), do: :ok

  # A busca que **descobre** o tenant — ver o moduledoc. Roda sob a GUC do id do provider, que é a
  # exceção estreita da RLS (`Api.Repo.with_provider_message/2`): sem ela a policy de `messages`
  # não casaria linha nenhuma e o webhook responderia 200 sem fazer nada, para sempre.
  #
  # `authorize?: false` porque não há sessão; o que autoriza a chamada é a assinatura conferida
  # antes dela.
  defp localizar(%{"email_id" => id}) when is_binary(id) do
    Api.Repo.with_provider_message(id, fn ->
      case Messaging.get_message_by_provider_id(id, authorize?: false, not_found_error?: false) do
        {:ok, %{} = message} -> {:ok, message}
        _ -> :error
      end
    end)
    |> elem(1)
  end

  defp localizar(_dados), do: :error

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
end
