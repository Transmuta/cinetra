defmodule Api.Cpf do
  @moduledoc """
  CPF clássico: 9 dígitos + 2 verificadores por módulo 11. Irmão do `Api.Cnpj`, e existe pelo
  mesmo motivo (AN-11 / HOM-012, D10): a ficha tinha **máscara e zero validação** — o banco
  guardava qualquer coisa com onze dígitos.

  A coluna guarda o valor **canônico** (só dígitos), desde que CPF duplicado passou a barrar
  (2026-07-29): unicidade é igualdade de string, e com a máscara guardada bastaria digitar sem os
  pontos para criar a segunda ficha da mesma pessoa. Quem canonicaliza na escrita é a
  `Api.Changes.Canonicalizar`; quem mascara na tela é `web/src/lib/masks.ts`. A busca da lista
  (`FilterPatients`) já comparava só os dígitos dos dois lados, então ela segue valendo para a
  ficha antiga que ainda tem máscara no banco.
  """

  @doc """
  Só os dígitos, sem máscara. `nil` ou string sem nenhum dígito viram `nil`.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(value) when is_binary(value) do
    digits = String.replace(value, ~r/\D/, "")
    if digits == "", do: nil, else: digits
  end

  @doc """
  Verdadeiro se, após normalizar, o valor tem 11 dígitos e os dois verificadores conferem.
  Sequências de um dígito só (`111.111.111-11`) fecham a conta mas não são CPFs emitidos —
  reprovam.
  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value) do
    case normalize(value) do
      <<_::binary-size(11)>> = cpf -> not repetido?(cpf) and verificadores_conferem?(cpf)
      _ -> false
    end
  end

  def valid?(_value), do: false

  defp repetido?(<<primeiro, resto::binary>>) do
    resto |> String.to_charlist() |> Enum.all?(&(&1 == primeiro))
  end

  defp verificadores_conferem?(cpf) do
    digitos = cpf |> String.to_charlist() |> Enum.map(&(&1 - ?0))
    {base, [dv1, dv2]} = Enum.split(digitos, 9)

    dv1 == check_digit(base, 10) and dv2 == check_digit(base ++ [dv1], 11)
  end

  # Σ (dígito × peso decrescente) → `soma × 10 mod 11`, com 10 ≡ 0: a forma fechada do
  # "resto < 2 → 0, senão 11 − resto" da Receita.
  defp check_digit(digitos, peso_inicial) do
    soma =
      digitos
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * (peso_inicial - i) end)

    case rem(soma * 10, 11) do
      10 -> 0
      dv -> dv
    end
  end
end
