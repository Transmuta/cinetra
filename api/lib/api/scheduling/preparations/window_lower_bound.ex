defmodule Api.Scheduling.Preparations.WindowLowerBound do
  @moduledoc """
  Fecha o `:in_range` por baixo: `starts_at > from − teto de duração`.

  O filtro da ação é sobreposição — `starts_at < to and ends_at > from` —, e só `starts_at` é
  indexável: `ends_at` vira residual. Um btree ascendente atende `starts_at < to` varrendo **tudo
  que veio antes de `to`**, ou seja, o histórico inteiro da clínica, e descarta o que não presta
  linha a linha. Com 10k linhas não morde; com três anos de agenda, morde (doc 36 §6.2).

  Como nenhum bloco passa de `Api.Scheduling.Duration.max_minutos/0` — invariante de **banco**,
  não de formulário —, `ends_at > from` implica `starts_at > from − teto`. O predicado é, portanto,
  **redundante em resultado e novo em plano**: não muda nem uma linha do que volta, e transforma a
  varredura aberta num range fechado dos dois lados.

  ## Por que preparation e não `filter expr(...)` na ação

  Para o bound chegar ao SQL como **literal** (`starts_at > $2`), e não como expressão calculada
  sobre o argumento. É a lição do D-A, que custou um índice inteiro: o Postgres só usa o índice
  como bound quando o lado direito é constante em tempo de plano. Aqui a subtração acontece em
  Elixir, antes da query existir.

  ## O que acontece se o teto for violado por fora

  Nada de errado, por construção: o CHECK `appointments_duration_within_cap` impede que a linha
  exista. Foi ele que tornou este corte legítimo — os dois nasceram no mesmo commit e não devem
  ser separados.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :from) do
      %DateTime{} = from ->
        floor = DateTime.add(from, -Api.Scheduling.Duration.max_segundos(), :second)
        Ash.Query.filter(query, starts_at > ^floor)

      # Argumento é `allow_nil? false`; sem valor a query já está inválida e a validação do Ash
      # é quem reporta. Deixar passar aqui evita mascarar o erro real com um match failure.
      _ ->
        query
    end
  end
end
