defmodule Api.Audit.BackfillTest do
  @moduledoc """
  A trilha precisa conseguir LER a linha que a migration de backfill escreve (doc 63 §4).

  Este é o teste que faltava e cuja ausência deixou passar um bug que derrubava a tela inteira:
  toda a suíte lia apenas linhas gravadas **pela app**, que nascem com `uuid_generate_v7()` por
  default da coluna. A migration escrevia por `INSERT ... SELECT`, informando o `id` — e um
  `id` de versão errada só falha na LEITURA, quando o `Ash.Type.UUIDv7` recusa a linha.

  A regra que isto trava é a lição do doc 49, aplicada a outra fronteira: **regra que atravessa
  a fronteira precisa de teste que a atravesse**. Aqui a fronteira é o SQL cru.
  """
  use Api.DataCase, async: false

  alias Api.Audit

  # Escreve como a migration escreve: SQL cru, `id` informado, sem passar pelo recurso.
  defp inserir_como_migration!(clinic_id, id_sql) do
    Api.Repo.query!(
      """
      INSERT INTO audit_events
        (id, clinic_id, resource, record_id, label, action, action_type,
         user_id, user_label, at, diff, meta, inserted_at)
      VALUES (#{id_sql}, $1, 'appointment', gen_random_uuid(), NULL, 'schedule', 'create',
              NULL, NULL, now(), ARRAY[]::jsonb[], '{"backfill": true}'::jsonb, now())
      """,
      [Ecto.UUID.dump!(clinic_id)]
    )
  end

  test "linha escrita pela migration é legível pelo feed" do
    ctx = clinica()

    inserir_como_migration!(ctx.clinic.id, "uuid_generate_v7()")

    assert %{entries: [_ | _]} = Audit.list_events(ctx.scope)
  end

  # A aresta afiada, documentada como teste para que ninguém a "conserte" pelo lado errado —
  # afrouxando o tipo da coluna em vez de gerar o id certo. Uma PK v4 não é uma linha ruim: é a
  # PÁGINA inteira caindo, porque o Ash carrega o conjunto e falha nele.
  test "PK v4 derruba o feed inteiro — é por isso que a migration precisa gerar v7" do
    ctx = clinica()

    inserir_como_migration!(ctx.clinic.id, "gen_random_uuid()")

    assert_raise MatchError, fn -> Audit.list_events(ctx.scope) end
  end

  # Tripwire sobre o SQL da migration. Casa `gen_random_uuid(),` — a forma de **coluna do
  # SELECT** —, e não a menção em prosa: o moduledoc da própria migration explica o bug e cita a
  # função pelo nome. Um tripwire que não distingue os dois se dispara com a própria explicação.
  test "o backfill não gera a PK com uuid v4" do
    sql = File.read!("priv/repo/migrations/20260728060000_backfill_audit_events.exs")

    refute sql =~ ~r/^\s*gen_random_uuid\(\),\s*$/m,
           "o backfill grava a PK de `audit_events`, que é uuid_v7 — `gen_random_uuid()` produz v4"
  end
end
