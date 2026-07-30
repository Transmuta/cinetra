defmodule Api.Cnpj do
  @moduledoc """
  CNPJ **alfanumérico** (Receita Federal / Serpro, vigente a partir de jul/2026): 12 posições
  alfanuméricas (`0-9`, `A-Z`) + 2 dígitos verificadores **numéricos**, validados por módulo 11.

  A única mudança frente ao CNPJ clássico é o valor de cada caractere no cálculo do DV: em vez
  do dígito, usa-se `código ASCII − 48` (então `'0'..'9' → 0..9`, `'A' → 17`, …, `'Z' → 42`).
  Como os dígitos mantêm o próprio valor, a rotina é retrocompatível: um CNPJ puramente numérico
  valida pela mesma conta. Ref: Serpro, "cálculo dos DV do CNPJ alfanumérico".
  """

  # Pesos do módulo 11 (2..9 da direita p/ a esquerda, reiniciando) — mesmos do CNPJ clássico.
  @weights_first [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
  @weights_second [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]

  @doc """
  Reduz à forma canônica de armazenamento: só `[0-9A-Z]`, em maiúsculas, sem máscara.
  `nil` ou uma string sem nenhum caractere válido viram `nil`.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(value) when is_binary(value) do
    normalized = value |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")
    if normalized == "", do: nil, else: normalized
  end

  @doc """
  Verdadeiro se, após normalizar, o valor tem 14 posições (12 alfanuméricas + 2 DV) e os dois
  dígitos verificadores conferem. Rejeita o CNPJ "vazio" `00000000000000`.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(value) when is_binary(value) do
    case normalize(value) do
      <<base::binary-size(12), d1::binary-size(1), d2::binary-size(1)>> = cnpj ->
        cnpj != "00000000000000" and
          check_digit(base, @weights_first) == d1 and
          check_digit(base <> d1, @weights_second) == d2

      _ ->
        false
    end
  end

  def valid?(_), do: false

  # Um DV: Σ (valor_do_char × peso) mod 11; resto < 2 → 0, senão 11 − resto. Sempre numérico.
  defp check_digit(chars, weights) do
    sum =
      chars
      |> String.to_charlist()
      |> Enum.zip(weights)
      |> Enum.reduce(0, fn {code, weight}, acc -> acc + (code - 48) * weight end)

    remainder = rem(sum, 11)
    digit = if remainder < 2, do: 0, else: 11 - remainder
    Integer.to_string(digit)
  end
end
