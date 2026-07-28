defmodule Api.Texto do
  @moduledoc """
  Concordância de número em frase que o usuário lê — as duas palavras que o sistema pluraliza.

  Existe porque o mesmo par (`sessão`/`sessões`, `foi`/`foram`) passou a ser montado em dois
  planos que não se falam: a caixa do sino (`Api.Notifications.Fanout`, "3 sessões do pacote X
  foram remarcadas") e a mensagem ao paciente (`Api.Messaging`, "3 sessões do seu pacote mudaram
  de horário"). Copiar `defp sessoes(1)` no segundo produziria, no dia em que alguém acrescentasse
  um caso, um lugar dizendo "1 sessões" e o outro não — e o bate-volta do doc 60 já pegou
  exatamente esse padrão de helper copiado que diverge.
  """

  @doc """
  A contagem por extenso: `"1 sessão"`, `"3 sessões"`.

      iex> Api.Texto.sessoes(1)
      "1 sessão"

      iex> Api.Texto.sessoes(3)
      "3 sessões"
  """
  def sessoes(1), do: "1 sessão"
  def sessoes(n) when is_integer(n), do: "#{n} sessões"

  @doc """
  O verbo que concorda com a contagem.

      iex> Api.Texto.foram(1)
      "foi"

      iex> Api.Texto.foram(2)
      "foram"
  """
  def foram(1), do: "foi"
  def foram(n) when is_integer(n) and n != 1, do: "foram"
end
