defmodule Api.Records.Preparations.FilterPatients do
  @moduledoc """
  Filtro e busca da lista de pacientes — **no servidor**, para que a paginação seja correta
  (paginar primeiro e filtrar a página depois devolveria páginas furadas).

  Move para o banco o que era o `filterPatients`/`searchPatients` do web:

    * **segmento** (`:status`): `ativos` / `inativos` / `resp` (com responsável legal) / `todos`;
    * **busca** (`:q`): nome por `ilike` e, quando o termo tem dígitos, também CPF e telefone
      comparando **só os dígitos** — a coluna guarda a máscara (`"123.456.789-00"`), então o
      `regexp_replace` tira a pontuação dos dois lados antes de comparar
      (espelha o `byDoc` do protótipo, [`:999`](../../../../interface/Movimento.dc.html#L999)).

  O `LIKE '%termo%'` é varredura por natureza (não usa índice); o que o índice composto
  `(clinic_id, inserted_at)` resolve é o recorte por tenant + a ordenação da página. Busca por
  prefixo/trigram só entraria se a busca virar gargalo medido.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> filter_status(Ash.Query.get_argument(query, :status))
    |> filter_search(Ash.Query.get_argument(query, :q))
  end

  defp filter_status(query, :ativos), do: Ash.Query.filter(query, ativo == true)
  defp filter_status(query, :inativos), do: Ash.Query.filter(query, ativo == false)

  # "Com responsável" = tem responsável legal preenchido (o segmento do protótipo, :1445).
  defp filter_status(query, :resp),
    do: Ash.Query.filter(query, not is_nil(responsavel) and responsavel != "")

  defp filter_status(query, _todos), do: query

  defp filter_search(query, term) when is_binary(term) do
    case String.trim(term) do
      "" -> query
      trimmed -> apply_term(query, trimmed, String.replace(trimmed, ~r/\D/, ""))
    end
  end

  defp filter_search(query, _nil), do: query

  # Termo sem dígito nenhum: só nome.
  defp apply_term(query, term, "") do
    like = "%#{term}%"
    Ash.Query.filter(query, ilike(nome, ^like))
  end

  # Com dígitos: nome OU CPF OU telefone (comparando dígitos contra dígitos).
  defp apply_term(query, term, digits) do
    like = "%#{term}%"
    dlike = "%#{digits}%"

    Ash.Query.filter(
      query,
      ilike(nome, ^like) or
        fragment("regexp_replace(coalesce(?, ''), '\\D', '', 'g') LIKE ?", cpf, ^dlike) or
        fragment("regexp_replace(coalesce(?, ''), '\\D', '', 'g') LIKE ?", tel, ^dlike)
    )
  end
end
