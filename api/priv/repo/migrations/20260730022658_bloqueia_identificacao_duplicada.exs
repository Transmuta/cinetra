defmodule Api.Repo.Migrations.BloqueiaIdentificacaoDuplicada do
  @moduledoc """
  CPF, telefone e e-mail preenchidos passam a ser únicos **por clínica** nos dois cadastros de
  pessoa (reverte o "duplicado só avisa" das fatias de Pacientes e Profissionais).

  Três coisas que a leitura do índice não deixa óbvias:

    * **`clinic_id` na frente é a unicidade por tenant**, não otimização: a mesma pessoa pode ser
      paciente (e o mesmo profissional pode ser cadastro) de duas clínicas — ADR-014/017.
    * **`NULLS DISTINCT`** (o default do Postgres) é o que faz ficha sem CPF conviver com outra
      ficha sem CPF. Quem garante que campo em branco chega como `NULL` e não como `''` — que
      *colidiria* — é a `Api.Changes.Canonicalizar`, no caminho de escrita.
    * **Sem `CONCURRENTLY`**, contra o default de `.claude/rules/migrations.md` §2, e de
      propósito: a regra é para tabela **com volume**, e estas chegam vazias no servidor (a
      instalação ainda não foi provisionada). Índice **único** ainda pesa o argumento para o outro
      lado: build `CONCURRENTLY` que falha deixa um índice `INVALID` para trás, e um que não falha
      é mais lento (duas varreduras).

  Não há backfill de dado. A ficha antiga salva com máscara (`123.456.789-09`) vira canônica no
  próximo save, pela mesma ação que canonicaliza a nova — é a opção (b) do D6, a que evitou
  backfill quando o telefone virou obrigatório. Isso deixa um buraco conhecido *só* onde já existe
  dado não-canônico: duas linhas antigas, uma com máscara e uma sem, não colidem no índice. Em dev
  isso foi resolvido na mão (dado de seed); no servidor não existe linha para resolver.
  """

  use Ecto.Migration

  def up do
    create unique_index(:professionals, [:clinic_id, :cpf], name: "professionals_cpf_unico_index")

    create unique_index(:professionals, [:clinic_id, :email],
             name: "professionals_email_unico_index"
           )

    create unique_index(:professionals, [:clinic_id, :tel], name: "professionals_tel_unico_index")

    create unique_index(:patients, [:clinic_id, :cpf], name: "patients_cpf_unico_index")

    create unique_index(:patients, [:clinic_id, :email], name: "patients_email_unico_index")

    create unique_index(:patients, [:clinic_id, :tel], name: "patients_tel_unico_index")
  end

  def down do
    drop_if_exists(unique_index(:patients, [:clinic_id, :tel], name: "patients_tel_unico_index"))

    drop_if_exists(
      unique_index(:patients, [:clinic_id, :email], name: "patients_email_unico_index")
    )

    drop_if_exists(unique_index(:patients, [:clinic_id, :cpf], name: "patients_cpf_unico_index"))

    drop_if_exists(
      unique_index(:professionals, [:clinic_id, :tel], name: "professionals_tel_unico_index")
    )

    drop_if_exists(
      unique_index(:professionals, [:clinic_id, :email], name: "professionals_email_unico_index")
    )

    drop_if_exists(
      unique_index(:professionals, [:clinic_id, :cpf], name: "professionals_cpf_unico_index")
    )
  end
end
