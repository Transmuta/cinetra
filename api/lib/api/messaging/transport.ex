defmodule Api.Messaging.Transport do
  @moduledoc """
  A porta de saída, por canal (doc 52 §2) — o **único** eixo em que "só muda quem envia" é
  verdade, e por isso o único que a fase 2 troca.

  Existe para que "o WhatsApp ainda não existe" não vire um `if` espalhado pelos gatilhos. O
  `Dispatch` pergunta `disponivel?/1` e trata canal sem transporte igual a paciente sem telefone
  — mesmo caminho, mesma explicação na tela. Ligar o WhatsApp na fase 2 foi implementar
  `entregar/2` e a configuração passar a existir: **nenhum chamador mudou**, que era a aposta
  registrada aqui na fase 1.

  ## Por que o e-mail está sempre disponível

  Porque o adapter `Local` (dev) e o `Test` (suíte) são transportes de verdade do ponto de vista
  de quem chama: aceitam a mensagem e devolvem sucesso. Perguntar "tem `RESEND_API_KEY`?" aqui
  faria o dev virar `:sem_canal` na tela — e o dev é justamente onde se quer ver a timeline
  funcionando. Quem decide para onde o e-mail vai é o adapter configurado, não este módulo.

  ## O WhatsApp exige duas chaves ligadas, não uma

  `disponivel?(:whatsapp)` é `habilitado E configurado`, e a redundância é deliberada:

    * `whatsapp_habilitado` é o **interruptor** — desligar o canal sem tirar credencial de lugar
      nenhum, que é o que se quer quando a Meta suspende um número às 3h da manhã;
    * `configurado?/0` do adapter é o **fato** — sem chave e sem conta não há o que ligar.

  Sem a segunda, um `WHATSAPP_HABILITADO=true` esquecido num ambiente sem credencial faria toda
  mensagem nascer `:falhou` em vez de sair pelo e-mail de reserva — e o desenho do C8 é
  exatamente que a reserva sirva quando o preferido não serve. É o mesmo raciocínio do
  `Api.Storage.configured?/0`: perguntar antes de oferecer, em vez de falhar por item.

  ## Este módulo é behaviour **e** fachada

  Mesma forma de `Api.Storage`, e pela mesma razão: o adapter é trocável por configuração (a
  `Api.Messaging.Zernio` em dev/prod, um duplo em memória na suíte) e o contrato de retorno
  precisa estar escrito num lugar só. A suíte não fala com a Zernio — se falasse, o gate de
  cobertura passaria a depender de um terceiro estar de pé.
  """

  @doc """
  Entrega a mensagem já renderizada. `{:ok, provider, provider_message_id}` ou `{:error, motivo}`.

  O `provider_message_id` é a chave que o webhook usa depois para achar a linha; adapter que não
  devolve id rende `nil`, e a mensagem simplesmente não recebe evento de entrega.
  """
  @callback entregar(message :: map(), corpo :: map()) ::
              {:ok, String.t(), String.t() | nil} | {:error, String.t()}

  @doc "Há credencial para este transporte funcionar? Ver o moduledoc."
  @callback configurado?() :: boolean()

  @doc """
  Há transporte de pé para este canal?

  `:whatsapp` responde `false` enquanto o interruptor estiver desligado **ou** faltar credencial —
  e nos dois casos o `Dispatch` cai para o e-mail pelo caminho normal, o mesmo de "paciente sem
  telefone".
  """
  def disponivel?(:email), do: true

  def disponivel?(:whatsapp),
    do: config()[:whatsapp_habilitado] == true and whatsapp_adapter().configurado?()

  def disponivel?(_canal), do: false

  @doc """
  Entrega a mensagem pelo canal dela.

  Devolve `{:ok, provider, provider_message_id}` ou `{:error, motivo_legivel}`. O motivo é texto
  porque vai para a coluna `erro` e daí para a tela: a recepção precisa ler "endereço inválido",
  não uma struct de exceção.
  """
  def entregar(%{canal: :email} = message, corpo),
    do: Api.Messaging.PatientEmails.entregar(message, corpo)

  def entregar(%{canal: :whatsapp} = message, corpo),
    do: whatsapp_adapter().entregar(message, corpo)

  def entregar(%{canal: canal}, _corpo),
    do: {:error, "canal #{canal} ainda não tem transporte nesta versão"}

  @doc "O adapter de WhatsApp ativo (a Zernio em dev/prod, o duplo em memória na suíte)."
  def whatsapp_adapter, do: config()[:whatsapp_adapter] || Api.Messaging.Zernio

  defp config, do: Application.get_env(:api, __MODULE__, [])
end
