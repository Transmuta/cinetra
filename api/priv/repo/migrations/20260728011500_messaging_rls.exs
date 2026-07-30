defmodule Api.Repo.Migrations.MessagingRls do
  @moduledoc """
  RLS nas tabelas da comunicação com o paciente (doc 52) — defesa-em-profundidade da tenancy por
  atributo (ADR-018), no molde de `NotificationsRls`.

  ## `message_opt_outs`: a linha global precisa passar

  Esta tabela tem `clinic_id` **anulável** de propósito (C10, doc 52 §10.1): nulo = opt-out
  **global**, que é a forma que o "SAIR" assume enquanto houver um remetente único da Cinetra
  (C11). A policy padrão (`clinic_id = current_setting(...)`) recusaria toda linha global — `NULL
  = x` é `NULL`, nunca verdadeiro — e o efeito seria o pior possível: **o opt-out global sumiria
  da leitura e continuaríamos mandando mensagem para quem pediu para parar**, sem erro em lugar
  nenhum. Por isso a policy aceita `clinic_id IS NULL` explicitamente, e isso é a intenção: um
  opt-out global vale para todos.

  ## `messages`: duas portas que chegam **sem tenant**

  A comunicação tem dois caminhos que resolvem a clínica a partir de um identificador externo, e
  os dois precisam ler **antes** de saber o tenant:

    * **o webhook do provider** conhece só o `provider_message_id` que ele próprio gerou;
    * **a resposta do paciente** conhece só o `id` da mensagem, que veio no token assinado do link.

  Sem exceção, a policy compara `clinic_id = NULL` e não casa linha nenhuma. O sintoma não é erro:
  é o webhook respondendo 200 sem fazer nada e o link do e-mail dizendo "link inválido" — **para
  sempre, e verde no `mix test`**, onde o sandbox conecta como `postgres` e bypassa RLS. Aconteceu:
  o webhook nasceu com a exceção, a resposta do paciente nasceu sem, e só o bate-volta ao vivo
  (como `cinetra_app`) pegou.

  Cada exceção alcança **uma** linha, identificada por um segredo que o chamador já provou possuir
  — a assinatura Svix num caso, o token que nós assinamos no outro. Não há varredura: as duas
  colunas são opacas e únicas.

  ## `nullif(…, '')` não é enfeite

  `current_setting(x, true)` devolve `NULL` quando a GUC nunca foi setada, e `NULL::uuid` é `NULL`
  (a policy fecha, correto). Mas quando ela foi setada como **string vazia** — que é como o
  projeto representa "sem GUC" (ver `Api.RlsSmokeTest.sem_guc/0`) — `''::uuid` levanta
  `22P02 invalid_text_representation` e a query inteira morre. `nullif` faz a comparação voltar a
  ser `NULL`, ou seja **fail-closed**, que é o que a policy sempre pretendeu ser.

  **Nada disto aparece no `mix test`.** A prova é o gate `:rls`, rodando como `cinetra_app`
  (NOBYPASSRLS) — parte do critério de pronto da fatia.
  """
  use Ecto.Migration

  def up do
    execute "ALTER TABLE messages ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE messages FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON messages
      USING (
        clinic_id = nullif(current_setting('cinetra.clinic_id', true), '')::uuid
        OR provider_message_id = nullif(current_setting('cinetra.provider_message_id', true), '')
        OR id = nullif(current_setting('cinetra.message_id', true), '')::uuid
      )
      WITH CHECK (clinic_id = nullif(current_setting('cinetra.clinic_id', true), '')::uuid)
    """

    execute "ALTER TABLE message_opt_outs ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE message_opt_outs FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation ON message_opt_outs
      USING (
        clinic_id IS NULL
        OR clinic_id = nullif(current_setting('cinetra.clinic_id', true), '')::uuid
      )
      WITH CHECK (
        clinic_id IS NULL
        OR clinic_id = nullif(current_setting('cinetra.clinic_id', true), '')::uuid
      )
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation ON message_opt_outs"
    execute "ALTER TABLE message_opt_outs NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE message_opt_outs DISABLE ROW LEVEL SECURITY"

    execute "DROP POLICY IF EXISTS tenant_isolation ON messages"
    execute "ALTER TABLE messages NO FORCE ROW LEVEL SECURITY"
    execute "ALTER TABLE messages DISABLE ROW LEVEL SECURITY"
  end
end
