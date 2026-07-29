defmodule Api.Repo.Migrations.RenameTenantGucToCinetra do
  @moduledoc """
  Renomeia o namespace das GUCs de `movimento.*` para `cinetra.*` (rebrand), reescrevendo as
  **17 policies de RLS** que as leem (ADR-018).

  ## Por que uma migration, se as migrations antigas já foram reescritas

  As `*_rls.exs` anteriores tiveram o texto trocado para `cinetra.*` no mesmo commit, o que
  resolve **banco novo** (CI, dev recém-criado, produção quando for provisionada): elas rodam do
  zero e já criam a policy com o nome novo. Não resolve **banco que já migrou** — o Ecto não
  re-roda migration aplicada, então lá a policy continuaria lendo `movimento.clinic_id` enquanto
  o código passaria a setar `cinetra.clinic_id`. O efeito seria mudo e total: GUC que a policy
  não lê é GUC ausente, e a RLS falha FECHANDO — toda leitura por-tenant voltaria vazia e toda
  escrita estouraria, sem erro em lugar nenhum que apontasse para a causa.

  Esta migration é o que faz os dois caminhos convergirem. Em banco novo ela é idempotente (o
  `DROP ... IF EXISTS` seguido do `CREATE` só reescreve o que a migration anterior acabou de
  criar); em banco já migrado, é ela que corrige.

  **Roda em transação de propósito** (sem `@disable_ddl_transaction`): as 17 policies têm de
  trocar juntas. Uma falha no meio com metade das tabelas lendo o GUC novo e metade o velho é
  exatamente o estado que nenhum teste pega — `mix test` roda como superusuário e bypassa RLS.

  A prova real é o gate `mix test --only rls`, que conecta como `cinetra_app` (NOBYPASSRLS).
  """
  use Ecto.Migration

  # As 17 tabelas por-tenant e o formato do predicado de cada uma. A maioria compara direto; duas
  # fogem do padrão e estão escritas à parte, porque copiá-las erradas passaria despercebido.
  @tabelas_simples ~w(
    appointment_types appointments attachments attendances audit_events availability_rules
    clinic_hours notifications package_schedules packages patients professional_hours
    professionals schedule_exceptions waitlist_entries
  )

  def up, do: trocar_para("cinetra")
  def down, do: trocar_para("movimento")

  defp trocar_para(ns) do
    for tabela <- @tabelas_simples do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{tabela}"

      execute """
      CREATE POLICY tenant_isolation ON #{tabela}
        USING (clinic_id = current_setting('#{ns}.clinic_id', true)::uuid)
        WITH CHECK (clinic_id = current_setting('#{ns}.clinic_id', true)::uuid)
      """
    end

    # `message_opt_outs` aceita linha SEM clínica: o opt-out global do paciente (doc 52) vale para
    # qualquer clínica, então `clinic_id IS NULL` tem de passar pela policy.
    execute "DROP POLICY IF EXISTS tenant_isolation ON message_opt_outs"

    execute """
    CREATE POLICY tenant_isolation ON message_opt_outs
      USING (
        clinic_id IS NULL
        OR clinic_id = nullif(current_setting('#{ns}.clinic_id', true), '')::uuid
      )
      WITH CHECK (
        clinic_id IS NULL
        OR clinic_id = nullif(current_setting('#{ns}.clinic_id', true), '')::uuid
      )
    """

    # `messages` tem as DUAS portas sem sessão (doc 52 §10.2): o webhook do provedor chega sem
    # clínica e só com o id que o provedor gerou, e a resposta do paciente só com o id da
    # mensagem. Cada uma abre a policy por UMA linha — e só na LEITURA: o `WITH CHECK` continua
    # exigindo a clínica, para que nenhuma dessas portas possa ESCREVER fora do tenant.
    execute "DROP POLICY IF EXISTS tenant_isolation ON messages"

    execute """
    CREATE POLICY tenant_isolation ON messages
      USING (
        clinic_id = nullif(current_setting('#{ns}.clinic_id', true), '')::uuid
        OR provider_message_id = nullif(current_setting('#{ns}.provider_message_id', true), '')
        OR id = nullif(current_setting('#{ns}.message_id', true), '')::uuid
      )
      WITH CHECK (clinic_id = nullif(current_setting('#{ns}.clinic_id', true), '')::uuid)
    """
  end
end
