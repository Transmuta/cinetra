defmodule Api.Repo.Migrations.RlsFailClosedUniforme do
  @moduledoc """
  Uniformiza o **modo de falha** da RLS: `nullif(current_setting(…), '')` nas 15 tabelas que ainda
  liam a GUC crua (doc 96, T-0).

  ## O achado

  O projeto afirma, em **cinco** lugares — `CLAUDE.md`, `.claude/rules/migrations.md` §3,
  `Api.Repo`, `Api.Tenancy` e o moduledoc de `Api.RlsSmokeTest` —, que uma leitura por-tenant sem
  `in_clinic` devolve **zero linhas, silenciosamente**. Medido, isso era verdade em **2** das 17
  tabelas. Nas outras 15 a leitura **levantava**:

      -- mesma conexão, depois de um COMMIT que fechou um `SET LOCAL`
      select coalesce(current_setting('cinetra.clinic_id', true), '<null>');  →  ''  (não NULL)
      select count(*) from appointments;
      -- ERROR: 22P02 invalid input syntax for type uuid: ""

  O detalhe que fazia a diferença: `current_setting(x, true)` devolve `NULL` só quando a GUC
  **nunca** foi setada. Depois de um `SET LOCAL` que já commitou, ela volta a `''` — e `''::uuid`
  levanta. Ou seja, o comportamento dependia de a conexão ser fria ou reciclada do pool: em
  produção, onde o pool recicla, o sintoma era **500 intermitente**, não lista vazia.

  Quem fosse depurar seguindo a documentação procuraria a coisa errada.

  ## A decisão: `nullif` em todas, não "cru" em todas

  As duas saídas uniformizam. Esta escolhe a que o projeto **já havia raciocinado por escrito**, em
  `20260728011500_messaging_rls.exs`, depois de um incidente ao vivo:

  > `nullif` faz a comparação voltar a ser `NULL`, ou seja **fail-closed**, que é o que a policy
  > sempre pretendeu ser.

  Três razões para manter essa direção:

  1. **A RLS aqui é backstop, não controle primário.** Quem garante o recorte por tenant é o filtro
     por atributo do Ash mais o `in_clinic`. Um backstop deve fechar, não derrubar o processo.
  2. **`message_opt_outs` depende disso.** A policy dela é `clinic_id IS NULL OR clinic_id = …`:
     as linhas globais precisam ser legíveis sem tenant. Sem `nullif`, ler opt-out global fora de
     um `with_clinic` levantaria — e isso é caminho de produção.
  3. **Transforma cinco textos errados em cinco textos certos**, em vez de exigir reescrevê-los.

  O que se **perde** é a parte que o doc 96 corretamente aponta: falha silenciosa é mais difícil de
  achar que exceção. A resposta a isso não é a policy — é o gate. Ver a nota em
  `.claude/rules/migrations.md` §3 e o débito D-15: leitura por-tenant nova em caminho de escrita
  se prova por `psql` sob o role restrito, **não** pela suíte.

  ## Sem `CONCURRENTLY`, e por quê

  `CREATE POLICY`/`DROP POLICY` altera catálogo, não reescreve tabela: é `AccessExclusiveLock` por
  alguns milissegundos, sem varredura. A regra 2 de `migrations.md` é sobre `CREATE INDEX`, que
  constrói estrutura sobre os dados — não se aplica aqui.
  """
  use Ecto.Migration

  # As 15 que liam a GUC crua. `messages` e `message_opt_outs` já usam `nullif` (a migration de
  # messaging), e ficam de fora — as policies delas têm cláusulas extras próprias.
  @tabelas ~w(
    appointment_types appointments attachments attendances audit_events availability_rules
    clinic_hours notifications package_schedules packages patients professional_hours
    professionals schedule_exceptions waitlist_entries
  )

  @cru "clinic_id = current_setting('cinetra.clinic_id', true)::uuid"
  @fail_closed "clinic_id = nullif(current_setting('cinetra.clinic_id', true), '')::uuid"

  def up, do: Enum.each(@tabelas, &repolicy(&1, @fail_closed))

  def down, do: Enum.each(@tabelas, &repolicy(&1, @cru))

  # `DROP` + `CREATE` porque o Postgres não tem `ALTER POLICY … USING` que preserve o nome sem
  # reescrever a expressão inteira de qualquer forma. As duas rodam na mesma transação da
  # migration, então não há janela em que a tabela fique sem policy.
  defp repolicy(tabela, expressao) do
    execute "DROP POLICY IF EXISTS tenant_isolation ON #{tabela}"

    execute """
    CREATE POLICY tenant_isolation ON #{tabela}
      USING (#{expressao})
      WITH CHECK (#{expressao})
    """
  end
end
