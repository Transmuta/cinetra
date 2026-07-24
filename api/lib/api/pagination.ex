defmodule Api.Pagination do
  @moduledoc """
  Os limites de página das listas do projeto, num lugar só.

  Três domínios já paginam — cadastro de pacientes, trilha de auditoria e fila de espera — e os
  três tinham escrito **a mesma** regra: 50 por padrão, teto de 200, e um teto de offset porque
  um `?offset=` gigante chega cru no Postgrex e derruba a request com 500. Eram três cópias com
  três formas diferentes (`clamp_limit/1`, `clamp_audit_limit/1`, `clamp/4`), que é o tipo de
  duplicação que só dói no dia em que alguém corrige uma delas.

  Os números vivem aqui; quem tem motivo para divergir passa o seu (`opts`), e aí a divergência
  fica **escrita** em vez de acidental.
  """

  @default_limit 50
  @max_limit 200
  # Ninguém pagina até aqui — usa os filtros. O teto existe para a fronteira não repassar um
  # inteiro absurdo ao banco.
  @max_offset 100_000

  @doc "O tamanho de página padrão (50)."
  def default_limit, do: @default_limit

  @doc """
  Normaliza o `limit` pedido: fora de `1..max`, cai no padrão ou no teto.

  Aceita `:default` e `:max` para quem tem motivo para divergir.

      iex> Api.Pagination.limit(10)
      10
      iex> Api.Pagination.limit(nil)
      50
      iex> Api.Pagination.limit(10_000)
      200
      iex> Api.Pagination.limit(-3)
      50
  """
  def limit(value, opts \\ [])

  def limit(value, opts) when is_integer(value) and value > 0 do
    min(value, Keyword.get(opts, :max, @max_limit))
  end

  def limit(_value, opts), do: Keyword.get(opts, :default, @default_limit)

  @doc """
  Normaliza o `offset` pedido: negativo ou ausente vira 0; acima do teto, o teto.

      iex> Api.Pagination.offset(100)
      100
      iex> Api.Pagination.offset(nil)
      0
      iex> Api.Pagination.offset(-1)
      0
      iex> Api.Pagination.offset(999_999_999)
      100_000
  """
  def offset(value, opts \\ [])

  def offset(value, opts) when is_integer(value) and value > 0 do
    min(value, Keyword.get(opts, :max, @max_offset))
  end

  def offset(_value, _opts), do: 0

  @doc """
  As opções de página prontas para o `page:` do Ash, com `count: true`.

      iex> Api.Pagination.page_opts(limit: 10, offset: 20)
      [limit: 10, offset: 20, count: true]
  """
  def page_opts(opts \\ []) do
    [
      limit: limit(Keyword.get(opts, :limit)),
      offset: offset(Keyword.get(opts, :offset)),
      count: true
    ]
  end
end
