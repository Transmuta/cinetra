defmodule Api.Messaging.Transport do
  @moduledoc """
  A porta de saída, por canal (doc 52 §2) — o **único** eixo em que "só muda quem envia" é
  verdade, e por isso o único que a fase 2 troca.

  Existe para que "o WhatsApp ainda não existe" não vire um `if` espalhado pelos gatilhos. O
  `Dispatch` pergunta `disponivel?/1` e trata canal sem transporte igual a paciente sem telefone
  — mesmo caminho, mesma explicação na tela. Ligar o WhatsApp na fase 2 é implementar
  `entregar/2` e a configuração passar a existir; nenhum chamador muda.

  ## Por que o e-mail está sempre disponível

  Porque o adapter `Local` (dev) e o `Test` (suíte) são transportes de verdade do ponto de vista
  de quem chama: aceitam a mensagem e devolvem sucesso. Perguntar "tem `RESEND_API_KEY`?" aqui
  faria o dev virar `:sem_canal` na tela — e o dev é justamente onde se quer ver a timeline
  funcionando. Quem decide para onde o e-mail vai é o adapter configurado, não este módulo.
  """

  @doc """
  Há transporte de pé para este canal?

  `:whatsapp` responde `false` na fase 1 e passa a consultar a configuração da Gupshup na fase 2.
  A chave `:whatsapp_habilitado` já é lida do config para que ligá-lo seja configuração, não
  deploy de código novo.
  """
  def disponivel?(:email), do: true

  def disponivel?(:whatsapp),
    do: Application.get_env(:api, __MODULE__, [])[:whatsapp_habilitado] == true

  def disponivel?(_canal), do: false

  @doc """
  Entrega a mensagem pelo canal dela.

  Devolve `{:ok, provider, provider_message_id}` ou `{:error, motivo_legivel}`. O motivo é texto
  porque vai para a coluna `erro` e daí para a tela: a recepção precisa ler "endereço inválido",
  não uma struct de exceção.
  """
  def entregar(%{canal: :email} = message, corpo),
    do: Api.Messaging.PatientEmails.entregar(message, corpo)

  def entregar(%{canal: canal}, _corpo),
    do: {:error, "canal #{canal} ainda não tem transporte nesta versão"}
end
