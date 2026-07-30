defmodule Api.Directory.AppointmentType.Calculations.Sigla do
  @moduledoc """
  A sigla do tipo de atendimento — **derivada** do nome, não coluna (doc 20, T4): o form do
  protótipo nunca coleta sigla, e o `pkgSigla` do protótipo já deriva do nome. Como derivada,
  ela não pode divergir do nome nem exigir backfill quando o nome muda.

  Regra: tira tudo que não é letra, pega as 3 primeiras, sobe pra maiúscula; se não sobrar
  letra nenhuma, cai em `"TIP"`. Reproduz as 5 siglas do seed exatamente — Avaliação→`AVA`,
  Sessão→`SES`, RPG→`RPG`, Pilates→`PIL`, Reavaliação→`REA`.
  """
  use Ash.Resource.Calculation

  @fallback "TIP"

  @impl true
  def load(_query, _opts, _context), do: [:nome]

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, &derive(&1.nome))

  @doc """
  Deriva a sigla de um nome.

      iex> Api.Directory.AppointmentType.Calculations.Sigla.derive("Avaliação")
      "AVA"
      iex> Api.Directory.AppointmentType.Calculations.Sigla.derive("123")
      "TIP"

  Só aceita binário, de propósito: `nome` é `allow_nil? false` e o `load/3` acima garante
  que vem carregado. Uma cláusula-pega-tudo devolveria `"TIP"` calada diante de `nil` ou
  `%Ash.NotLoaded{}` — mascarando o bug em vez de estourar.
  """
  def derive(nome) when is_binary(nome) do
    # A faixa À-ÿ cobre os acentos do português (Avaliação, Sessão, Reavaliação).
    case ~r/[^A-Za-zÀ-ÿ]/u
         |> Regex.replace(nome, "")
         |> String.slice(0, 3)
         |> String.upcase() do
      "" -> @fallback
      sigla -> sigla
    end
  end
end
