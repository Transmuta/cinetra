defmodule Api.Messaging.Falhas do
  @moduledoc """
  Traduz o motivo de falha do provider para o que a **recepção** precisa ler (doc 52 §6).

  ## Por que isto existe

  O que o provider devolve é inglês técnico — `"mailbox does not exist"`, `"Invalid API key"`, e no
  pior caso um `%Swoosh.Error{}` inspecionado. Isso ia direto para a coluna `erro` e daí para a
  timeline do drawer. Quem lê aquela tela é a recepção no balcão: texto em inglês ali não informa,
  **gera chamado de suporte** — e o chamado é sobre uma coisa que ela mesma resolveria em dez
  segundos se a frase dissesse o que fazer.

  ## Não é tradução, é instrução

  `"mailbox does not exist"` não vira "caixa de correio não existe". Vira **"E-mail não existe —
  confira o endereço na ficha"**, porque essa é a ação. A frase responde "e agora?", não "o que o
  servidor disse".

  ## O texto cru não some

  Fica na coluna `erro`, e a fronteira devolve os dois (`erro` e `erroTexto`). A tradução é
  **apresentação**, decidida na leitura — como o corpo da mensagem, que é renderizado do template
  em vez de gravado. Assim o suporte continua tendo a mensagem original para investigar, e o
  vocabulário do provider pode mudar sem reescrever histórico.

  ## Quando não reconhece

  Devolve uma frase genérica **em português**, nunca o texto cru. Uma falha que não sabemos
  explicar ainda é uma falha que a recepção precisa ver — e ver "não conseguimos entregar" é
  melhor do que ver `%Swoosh.Error{reason: :nxdomain}`.
  """

  # Casado por trecho, em minúsculas, e não por código de erro: cada provider tem o seu conjunto
  # (o Resend hoje, a Gupshup na fase 2), mas o vocabulário de bounce de e-mail é padronizado o
  # bastante para estes trechos aparecerem em todos. A ordem importa — o primeiro que casar vence,
  # e os mais específicos vêm antes.
  # Casado por **frase**, em minúsculas, e não por código de erro: cada provider tem o seu conjunto
  # (o Resend hoje, a Gupshup na fase 2), mas o vocabulário de bounce de e-mail é padronizado o
  # bastante para estes trechos aparecerem em todos.
  #
  # São listas de strings, e **não `~w`**: `~w(does not exist)` vira `["does", "not", "exist"]`, e
  # aí um `"not"` solto casa com quase qualquer mensagem de erro do mundo. Foi assim que a primeira
  # versão mandou "Invalid API key" para a regra de endereço inválido e um `%Swoosh.Error{}` para a
  # de domínio não verificado — os testes pegaram os dois.
  #
  # A ordem importa: o primeiro que casar vence, então o específico vem antes do genérico.
  # O bloco do WhatsApp vem **antes** do de e-mail, e não é ordem alfabética: o código `131049` da
  # Meta chega com a palavra "antispam" no texto, e a regra genérica de spam (lá embaixo, escrita
  # para bounce de e-mail) o classificaria como "o provedor do paciente recusou como spam" — que é
  # a frase errada e leva a recepção a corrigir a ficha de um endereço que está certo.
  #
  # Os números são códigos da Meta que a Zernio repassa (doc 65 §4). Casá-los por número é o que
  # torna a frase precisa: o texto que os acompanha muda de idioma e de redação sem aviso.
  @regras [
    {["131021", "not a valid whatsapp", "not a whatsapp user", "invalid wa_id", "invalid phone"],
     "Este número não tem WhatsApp — confira o telefone na ficha"},
    {["131049", "131048", "antispam", "healthy ecosystem", "spam rate"],
     "A Meta segurou esta mensagem para não sobrecarregar o paciente — tente mais tarde"},
    {["131026", "131047", "re-engagement", "reengagement", "undeliverable"],
     "Não foi possível iniciar conversa no WhatsApp com este número"},
    {[
       "132000",
       "132001",
       "132005",
       "132007",
       "132012",
       "132015",
       "template_required",
       "template not found",
       "template is paused",
       "template_param"
     ], "Template de WhatsApp não aprovado ou fora do padrão — avise o suporte"},
    {["platform_not_supported", "inbox addon", "addon required"],
     "A conta de WhatsApp não está configurada — avise o suporte"},
    {["429", "rate limit", "too many requests"],
     "Limite de envio atingido — tente reenviar em alguns minutos"},
    {["api key", "unauthorized", "forbidden", "authentication failed"],
     "Erro de configuração do envio — avise o suporte"},
    {["domain is not verified", "domain not verified", "unverified domain"],
     "O domínio de envio ainda não foi verificado"},
    {[
       "does not exist",
       "no such user",
       "user unknown",
       "unknown user",
       "recipient not found",
       "invalid recipient",
       "address not found",
       "no mailbox"
     ], "E-mail não existe — confira o endereço na ficha"},
    {["mailbox full", "quota exceeded", "over quota", "insufficient storage", "mailbox is full"],
     "A caixa de e-mail do paciente está cheia"},
    {["spam", "blacklist", "blocked", "policy rejection", "reputation"],
     "O provedor do paciente recusou a mensagem como spam"},
    {["invalid email", "invalid address", "malformed", "syntax error", "bad address"],
     "Endereço de e-mail inválido — confira a ficha"},
    {["suppress", "suppression list"], "Este endereço está bloqueado no provedor de envio"},
    {[
       "greylist",
       "try again",
       "temporarily",
       "temporary failure",
       "deferred",
       "timed out",
       "timeout"
     ], "Falha temporária no envio — tente reenviar"}
  ]

  @generico "Não conseguimos entregar a mensagem"

  @doc """
  A frase que a recepção lê, a partir do motivo cru.

  `nil` entra e `nil` sai: mensagem sem erro não ganha linha de erro.
  """
  def texto(nil), do: nil

  def texto(motivo) when is_binary(motivo) do
    alvo = String.downcase(motivo)

    Enum.find_value(@regras, @generico, fn {trechos, frase} ->
      if Enum.any?(trechos, &String.contains?(alvo, &1)), do: frase
    end)
  end

  @doc """
  Os motivos que **nós** escrevemos já nascem em português e passam direto.

  São os que não vêm de provider nenhum: template desconhecido, canal sem transporte, mensagem de
  WhatsApp sem template renderizado, e o `"destinatário marcou como spam"` do webhook. Traduzi-los
  de novo seria passá-los pelo genérico e perder informação que já estava certa.
  """
  def nosso?(motivo) when is_binary(motivo) do
    String.starts_with?(motivo, [
      "template desconhecido",
      "canal ",
      "destinatário marcou",
      "mensagem de WhatsApp"
    ])
  end

  def nosso?(_motivo), do: false

  @doc "A frase final: preserva o que já é nosso, traduz o que veio de fora."
  def para_tela(nil), do: nil

  def para_tela(motivo) when is_binary(motivo),
    do: if(nosso?(motivo), do: motivo, else: texto(motivo))
end
