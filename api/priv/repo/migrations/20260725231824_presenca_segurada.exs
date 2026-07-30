defmodule Api.Repo.Migrations.PresencaSegurada do
  @moduledoc """
  `attendances.pkg_hold` — a presença segurada por uma pausa de pacote (doc 43 §5c).

  Até aqui o `pkg_hold` era só do **bloco**, e pausar o pacote de um paciente numa turma tirava a
  sessão da agenda de todos. Com o hold na presença, pausar segue a mesma regra do resto do pacote:
  sozinho no bloco segura o bloco; acompanhado segura só a presença.

  Roda em transação, diferente das irmãs: é um `ADD COLUMN` com default **constante**, que no
  Postgres ≥ 11 não reescreve a tabela — não há janela de lock que justifique `CONCURRENTLY` nem a
  perda da atomicidade (que é o que torna a migration re-executável de graça).

  Gerada por `mix ash.codegen presenca_segurada`; só o moduledoc é escrito à mão.
  """

  use Ecto.Migration

  def up do
    alter table(:attendances) do
      add(:pkg_hold, :boolean, null: false, default: false)
    end
  end

  def down do
    alter table(:attendances) do
      remove(:pkg_hold)
    end
  end
end
