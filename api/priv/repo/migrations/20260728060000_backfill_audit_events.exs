defmodule Api.Repo.Migrations.BackfillAuditEvents do
  @moduledoc """
  Migra o histórico já gravado para `audit_events` (doc 63 §4, passo 2 do expand-contract).

  Três fontes, todas preservadas no lugar de origem — este backfill **copia**, não move:

    * `appointments_versions` e `attendances_versions` (AshPaperTrail, que sai nesta fatia);
    * `attachment_events` (a trilha de acesso a anexo, que passa a ser lida pela mesma tela).

  ## O diff é reconstruído aqui, uma vez, em vez de a cada leitura

  O AshPaperTrail gravava com `change_tracking_mode :changes_only`: cada versão guarda **só o
  valor novo** dos campos que mudaram. O "de X para Y" da tela era remontado a cada request,
  encadeando a versão anterior do mesmo registro — trabalho que o doc 25 §11.4 já classificava
  como do backend justamente para não virar N+1.

  Com a retenção de 90 dias (D-Aud5) esse encadeamento deixou de ser possível: a versão anterior
  pode ter sido podada, e o "de X" sumiria em silêncio. Então ele é resolvido **agora**, de uma
  vez: para cada campo de cada versão, o valor anterior é o da última versão do mesmo registro,
  antes dela, que tocou aquele campo. É o `LATERAL` abaixo.

  ## A PK precisa ser **v7**, e não é detalhe

  `audit_events.id` é `uuid_v7_primary_key`, e o `Ash.Type.UUIDv7` **valida a versão ao carregar**.
  Uma linha gravada com `gen_random_uuid()` (que produz **v4**) fica ilegível para sempre — e não
  só ela: o Ash falha ao carregar o *conjunto*, então **uma** linha ruim derruba a página inteira
  com 500. Foi exatamente o que aconteceu, e nenhum dos testes viu, porque todos liam linhas
  gravadas pela app, que nascem do `default` da coluna.

  `uuid_generate_v7()` é a mesma função que a coluna usa por default
  (`20260728053848_trilha_de_eventos.exs`). O `test/api/audit/backfill_test.exs` trava isso agora,
  inclusive lendo uma linha escrita por SQL cru — a fronteira que a suíte não atravessava.

  ## Sobre rodar como `postgres`

  `audit_events` tem `FORCE ROW LEVEL SECURITY`, que alcança até o dono da tabela — mas
  **superusuário sempre bypassa** RLS, e migration roda como `postgres`. Por isso o `INSERT`
  abaixo não precisa da GUC `movimento.clinic_id`. O `clinic_id` de cada linha vem da origem,
  então o isolamento continua correto: nenhuma linha muda de clínica no caminho.

  ## Campos que não viram linha de diff

  A mesma lista que a tela já descartava (doc 25 §11.4): internas/derivadas (`version`, `id`,
  `ends_at`, timestamps) e as FKs por-uuid — um diff `<uuid> → <uuid>` não diz nada a quem lê, e
  o contexto delas viaja em `meta`.
  """
  use Ecto.Migration

  @ignorados ~w(version id clinic_id ends_at pkg_hold package_id inserted_at updated_at
                professional_id appointment_type_id patient_id appointment_id created_by_id)

  def up do
    backfill_versions("appointments_versions", "appointment", """
      jsonb_strip_nulls(jsonb_build_object(
        'professional_id', v.professional_id,
        'starts_at', v.starts_at,
        'status', v.status
      ))
    """)

    backfill_versions("attendances_versions", "attendance", """
      jsonb_strip_nulls(jsonb_build_object(
        'patient_id', v.patient_id,
        'appointment_id', v.appointment_id,
        'status', v.status
      ))
    """)

    backfill_attachment_events()
  end

  def down do
    # A trilha nova volta a ficar só com o que foi gravado depois da virada. As origens não
    # foram tocadas, então nada se perde — é o que torna este `down` seguro.
    execute "DELETE FROM audit_events WHERE meta ? 'backfill'"
  end

  # ---- versões do AshPaperTrail ----

  defp backfill_versions(tabela, resource, meta_sql) do
    ignorados = Enum.map_join(@ignorados, ",", &"'#{&1}'")

    execute """
    INSERT INTO audit_events
      (id, clinic_id, resource, record_id, label, action, action_type,
       user_id, user_label, at, diff, meta, inserted_at)
    SELECT
      uuid_generate_v7(),
      v.clinic_id,
      '#{resource}',
      v.version_source_id,
      NULL,
      v.version_action_name,
      v.version_action_type,
      v.user_id,
      u.nome,
      v.version_inserted_at,
      COALESCE(d.diff, ARRAY[]::jsonb[]),
      #{meta_sql} || jsonb_build_object('backfill', true),
      v.version_inserted_at
    FROM #{tabela} v
    LEFT JOIN users u ON u.id = v.user_id
    LEFT JOIN LATERAL (
      SELECT array_agg(
               jsonb_build_object('field', kv.key, 'from', anterior.valor, 'to', kv.value)
             ) AS diff
      FROM jsonb_each(COALESCE(v.changes, '{}'::jsonb)) kv
      LEFT JOIN LATERAL (
        SELECT p.changes -> kv.key AS valor
        FROM #{tabela} p
        WHERE p.version_source_id = v.version_source_id
          AND p.clinic_id = v.clinic_id
          AND p.version_inserted_at < v.version_inserted_at
          AND p.changes ? kv.key
        ORDER BY p.version_inserted_at DESC
        LIMIT 1
      ) anterior ON TRUE
      WHERE kv.key NOT IN (#{ignorados})
    ) d ON TRUE
    """
  end

  # ---- trilha de acesso a anexo ----
  #
  # `:visualizou` é o único evento de LEITURA do sistema hoje, e é o que responde "quem leu o
  # laudo?" — por isso vira `action_type = 'read'` em vez de ser espremido num dos três tipos de
  # escrita. Os demais mapeiam para o tipo de escrita correspondente.
  defp backfill_attachment_events do
    execute """
    INSERT INTO audit_events
      (id, clinic_id, resource, record_id, label, action, action_type,
       user_id, user_label, at, diff, meta, inserted_at)
    SELECT
      uuid_generate_v7(),
      e.clinic_id,
      'attachment',
      e.attachment_id,
      e.nome,
      e.acao,
      CASE e.acao
        WHEN 'visualizou' THEN 'read'
        WHEN 'enviou' THEN 'create'
        WHEN 'removeu' THEN 'destroy'
        ELSE 'update'
      END,
      e.user_id,
      u.nome,
      e.inserted_at,
      ARRAY[]::jsonb[],
      jsonb_strip_nulls(jsonb_build_object('patient_id', e.patient_id))
        || jsonb_build_object('backfill', true),
      e.inserted_at
    FROM attachment_events e
    LEFT JOIN users u ON u.id = e.user_id
    """
  end
end
