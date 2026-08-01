defmodule Api.Params do
  @moduledoc """
  Coerção dos valores que chegam **de fora** — corpo de request, query string, argumento de job —
  para o que o domínio espera.

  Mora em `Api` e não em `ApiWeb.TenantScope` (onde vivem `parse_int/1` e `parse_window/4`) porque
  nem todo consumidor é controller: `Api.Packages.Bulk` recebe o mapa de params intacto e lê as
  próprias flags. A regra de divisão é essa — o que é **forma HTTP** (escada de erro, janela de
  datas) fica na fronteira; o que é **valor** atravessa a camada e mora aqui.

  Nasceu do bate-volta da Onda 3 ([doc 43](../../docs/43-bate-volta-onda-3.md) §5e): `truthy`
  existia em quatro cópias com contratos divergentes — `"1"`/`1` valiam para `justificada` e não
  valiam para `forcar`/`encaixe`/`aplicar_horario`, então um cliente que mandasse `forcar: 1`
  recebia `false` **calado** e a massa agendava sem o "agendar mesmo assim". É o mesmo argumento
  que já consolidou `parse_int/1`, cujo docstring diz "estava copiada em três controllers, e a
  cópia mais nova já divergia".
  """

  # O conjunto da cópia mais permissiva das quatro (a do `AppointmentsController`): a consolidação
  # amplia quem já era estrito, em vez de estreitar quem já aceitava — assim nenhum cliente que
  # funcionava para de funcionar.
  @verdadeiros [true, "true", "1", 1]

  @doc """
  O valor é um "sim"? Aceita o booleano, as strings de form (`"true"`, `"1"`) e o inteiro `1`.
  Qualquer outra coisa — inclusive `nil` e ausência — é `false`.

      iex> Api.Params.truthy?(true)
      true

      iex> Api.Params.truthy?("true")
      true

      iex> Api.Params.truthy?("1")
      true

      iex> Api.Params.truthy?(1)
      true

      iex> Api.Params.truthy?("false")
      false

      iex> Api.Params.truthy?(nil)
      false
  """
  def truthy?(value), do: value in @verdadeiros

  @doc """
  A flag de `params` (aceita a chave átomo **ou** string, como chega do Plug) é um "sim"?

      iex> Api.Params.truthy?(%{"forcar" => "1"}, :forcar)
      true

      iex> Api.Params.truthy?(%{forcar: true}, :forcar)
      true

      iex> Api.Params.truthy?(%{}, :forcar)
      false
  """
  def truthy?(params, key) when is_map(params) and is_atom(key),
    do: truthy?(get(params, key))

  @doc """
  Lê de `params` por chave átomo **ou** string — a ponte entre o mapa que o Plug entrega
  (`%{"escopo" => …}`) e o que os testes e jobs montam (`%{escopo: …}`).
  """
  def get(params, key) when is_map(params) and is_atom(key),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  @doc """
  O valor é um UUID bem formado?

  Estava copiado, byte a byte, em `Api.Scheduling` e `Api.Packages.Bulk` (doc 96, R-2). Mora aqui
  pela mesma razão que `get/2`: é higiene de valor vindo da fronteira, e não regra de nenhum
  domínio. A cláusula de catch-all é o que torna a função segura para valor de qualquer tipo —
  `nil`, número, mapa — que é como ele chega de um corpo HTTP.
  """
  def uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  def uuid?(_value), do: false
end
