defmodule Api.Repo.Migrations.LimiteDeSessoesDoPacote do
  @moduledoc """
  Teto de 120 sessões por pacote, no banco — o par do `min` que já existia
  (`packages_total_positive`).

  `total` dimensiona as duas operações mais pesadas do sistema: a materialização (N agendamentos
  criados pelo job) e a massa por pacote (N escritas numa transação única, segurando conexão do
  pool e os locks da exclusion constraint). Medido depois do hoist do invariante (doc 43 §5a):
  16,6 queries por sessão no caminho de turma. Sem teto, um `500` digitado no lugar de `50` viraria
  ~8.000 queries e ~15 s de transação; com 120, o pior caso fica em ~2.000 queries.

  A constraint do atributo já recusa na entrada da API — esta protege o dado de qualquer outro
  caminho (`Ash.Seed`, script, `psql`), como o piso faz desde o começo.

  Sem `NOT VALID`/`VALIDATE`: `packages` tem uma linha por pacote (dezenas, não milhões), e a
  varredura sob `ACCESS EXCLUSIVE` é instantânea nessa ordem de grandeza. A dança em duas etapas
  seria complexidade sem ganho — diferente dos índices de `attendances`, que é tabela quente.

  Gerada por `mix ash.codegen limite_de_sessoes_do_pacote`; só o moduledoc é escrito à mão.
  """

  use Ecto.Migration

  def up do
    create constraint(:packages, :packages_total_max,
             check: """
               total <= 120
             """
           )
  end

  def down do
    drop_if_exists(constraint(:packages, :packages_total_max))
  end
end
