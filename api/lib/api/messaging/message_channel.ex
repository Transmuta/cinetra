defmodule Api.Messaging.MessageChannel do
  @moduledoc """
  Por onde a mensagem sai (doc 52 §2). O eixo que a fase 2 troca — e o **único** dos quatro em
  que "só muda quem envia" é verdade.

  `:whatsapp` já existe no enum na fase 1, sem transporte por trás. É de propósito: o `OptOut`, a
  ordem de canal (§10.4) e a timeline são escritos contra os dois desde já, e o que falta na fase
  2 é o adapter — não o modelo.
  """
  use Ash.Type.Enum, values: [:email, :whatsapp]
end
