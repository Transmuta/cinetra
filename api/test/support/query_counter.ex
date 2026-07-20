defmodule Api.QueryCounter do
  @moduledoc """
  Conta as queries que um trecho dispara, opcionalmente só as de uma tabela.

  É o instrumento dos achados (f) e (g) do doc 26 — as duas correções de performance da fatia
  Agenda. Existe como helper compartilhado porque nasceu copiado em dois arquivos de teste, já
  divergindo em duas dimensões (um filtrava `"memberships"` hardcoded e devolvia só a contagem;
  o outro parametrizava a tabela e devolvia `{resultado, contagem}`). Instrumento de medição
  que mede diferente em cada lugar é pior que instrumento nenhum: o teto de query de um arquivo
  deixa de significar o mesmo que o do outro, e a regressão passa por baixo.
  """

  @doc """
  Roda `fun` e devolve `{resultado, n_queries}`.

  `source` é o nome da tabela (`"memberships"`, `"appointments"`); `nil` conta todas.
  """
  @spec count((-> result), String.t() | nil) :: {result, non_neg_integer()} when result: term()
  def count(fun, source \\ nil) when is_function(fun, 0) do
    parent = self()
    ref = make_ref()

    handler = fn _event, _measurements, metadata, _config ->
      if is_nil(source) or metadata[:source] == source, do: send(parent, {ref, :query})
    end

    :telemetry.attach({__MODULE__, ref}, [:api, :repo, :query], handler, nil)
    result = fun.()
    :telemetry.detach({__MODULE__, ref})

    {result, drain(ref, 0)}
  end

  # A telemetria chega por mensagem, então a contagem só fecha depois de drenar a caixa. O
  # `after` é o que separa "acabou" de "ainda vindo" — sem ele a contagem sairia por baixo.
  defp drain(ref, acc) do
    receive do
      {^ref, :query} -> drain(ref, acc + 1)
    after
      50 -> acc
    end
  end
end
