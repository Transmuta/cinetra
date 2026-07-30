defmodule Api.Messaging.MessageReply do
  @moduledoc """
  O que o paciente respondeu (doc 52 §5). Duas opções, e só duas.

  Elas são **botões de um link assinado**, não texto interpretado: o paciente clica em "Confirmar"
  ou "Preciso remarcar" e o token diz de qual presença se trata. Interpretar frase livre ("acho
  que consigo ir") é adivinhação com consequência na agenda — e no WhatsApp, com um número
  compartilhado (§9.1), a frase nem sequer identifica a clínica.

  `:quer_remarcar` **não remarca nada**: marca que a pessoa pediu, e a recepção resolve. Remarcar
  sozinho exigiria escolher horário por ela, e a agenda tem regras (expediente, conflito, encaixe)
  que um clique de fora não conhece.
  """
  use Ash.Type.Enum, values: [:confirmou, :quer_remarcar]
end
