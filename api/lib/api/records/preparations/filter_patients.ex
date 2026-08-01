defmodule Api.Records.Preparations.FilterPatients do
  @moduledoc """
  Filtro e busca da lista de pacientes — **no servidor**, para que a paginação seja correta
  (paginar primeiro e filtrar a página depois devolveria páginas furadas).

  Move para o banco o que era o `filterPatients`/`searchPatients` do web:

    * **segmento** (`:status`): `ativos` / `inativos` / `resp` (com responsável legal) / `todos`;
    * **busca** (`:q`): nome e e-mail por `ilike` e, quando o termo tem dígitos, também CPF e
      telefone comparando **só os dígitos** — a ficha antiga guarda a máscara
      (`"123.456.789-00"`), então o `regexp_replace` tira a pontuação dos dois lados antes de
      comparar (espelha o `byDoc` do protótipo,
      [`:999`](../../../../interface/Movimento.dc.html#L999)).

      O e-mail entrou em 2026-07-29, quando e-mail duplicado passou a barrar: o aviso de possível
      duplicado da tela consulta **esta** busca, e sem o e-mail aqui ele avisaria sobre CPF e
      telefone e ficaria calado justo no terceiro campo que também recusa o save.

  O `LIKE '%termo%'` é varredura por natureza (não usa índice); o que o índice composto
  `(clinic_id, inserted_at)` resolve é o recorte por tenant + a ordenação da página. Busca por
  prefixo/trigram só entraria se a busca virar gargalo medido.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  # Teto do termo. Nome de paciente não passa disso, e sem teto um termo de milhares de
  # metacaracteres vira um padrão que o Postgres avalia linha a linha (medido: 8k chars de
  # `a%` = 6,7s por query, e cada request roda o padrão DUAS vezes — página + count).
  @max_term 100

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
    case term |> String.trim() |> String.slice(0, @max_term) do
      "" -> query
      trimmed -> apply_term(query, trimmed, Api.Texto.somente_digitos(trimmed))
    end
  end

  defp filter_search(query, _nil), do: query

  # `%`, `_` e `\` digitados são LITERAIS, não curingas. Sem escapar, quem busca "%" casa a
  # clínica inteira e, pior, pode montar um padrão patológico de propósito — o valor é
  # parametrizado (não há injeção de SQL), mas a *forma* do padrão é do usuário.
  # O `\` é o escape default do LIKE no Postgres.
  defp escape_like(term), do: String.replace(term, ~r/[\\%_]/, &("\\" <> &1))

  # Termo sem dígito nenhum: nome ou e-mail.
  defp apply_term(query, term, "") do
    like = "%#{escape_like(term)}%"
    Ash.Query.filter(query, ilike(nome, ^like) or ilike(email, ^like))
  end

  # Com dígitos: nome OU e-mail OU CPF OU telefone (comparando dígitos contra dígitos). O `dlike`
  # já é só `[0-9]`, então não carrega metacaractere — o escape é do termo de nome/e-mail.
  defp apply_term(query, term, digits) do
    like = "%#{escape_like(term)}%"
    dlike = "%#{digits}%"

    Ash.Query.filter(
      query,
      ilike(nome, ^like) or
        ilike(email, ^like) or
        fragment("regexp_replace(coalesce(?, ''), '\\D', '', 'g') LIKE ?", cpf, ^dlike) or
        fragment("regexp_replace(coalesce(?, ''), '\\D', '', 'g') LIKE ?", tel, ^dlike)
    )
  end
end
