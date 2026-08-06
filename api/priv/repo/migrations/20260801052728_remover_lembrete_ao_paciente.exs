defmodule Api.Repo.Migrations.RemoverLembreteAoPaciente do
  @moduledoc """
  O lembrete automático ao paciente sai, e com ele `clinics.msg_lembrete_horas` (2026-08-01).

  Gerada por `mix ash.codegen` e **editada à mão** pelo mesmo motivo da migration de 2026-07-31
  (doc 98): a view `metrics_clinics` cita a coluna, e `DROP COLUMN` falha com *"cannot drop column
  ... because other objects depend on it"*. `CREATE OR REPLACE VIEW` também não resolve — o
  Postgres acrescenta coluna ao fim de uma view, nunca remove. É `DROP VIEW` → alterar a tabela →
  recriar a view, **reconcedendo o GRANT** ao `cinetra_metrics`, que o `DROP VIEW` leva junto.

  Segunda vez que essa armadilha cobra em dois dias. O aviso já está em
  `.claude/rules/migrations.md`; o que esta migration acrescenta é a evidência de que ele não é
  teórico.

  ## O `down` é honesto sobre o que não devolve

  Ele recria a coluna com o default de 2 h e a view antiga. **Não devolve o valor por clínica**:
  quem tinha escolhido 24 h volta com 2 h, porque o dado foi embora com a coluna. Reverter é
  voltar o código; o número que cada clínica escolheu, não.

  E não devolve o disparo — o `ReminderJob` e o crontab saíram no mesmo commit. Uma coluna
  restaurada sem cron é uma configuração que não faz nada, e é isso que o `down` entrega.
  """

  use Ecto.Migration

  # A definição ANTERIOR, para o `down` — a única cópia dela, já que o `up` a substitui.
  @view_antiga """
  SELECT id, nome, timezone, slot_minutos, cap_turma_padrao,
         msg_lembrete_horas,
         (zernio_account_id IS NOT NULL) AS whatsapp_configurado,
         inserted_at
    FROM clinics
  """

  # A nova: a mesma lista, sem a coluna que deixou de existir.
  @view_nova """
  SELECT id, nome, timezone, slot_minutos, cap_turma_padrao,
         (zernio_account_id IS NOT NULL) AS whatsapp_configurado,
         inserted_at
    FROM clinics
  """

  @comentario "Clínicas — sem CNPJ e sem endereço; nome serve de rótulo nos painéis."

  def up do
    execute("DROP VIEW IF EXISTS metrics_clinics")

    alter table(:clinics) do
      remove(:msg_lembrete_horas)
    end

    recriar_view(@view_nova)
  end

  def down do
    execute("DROP VIEW IF EXISTS metrics_clinics")

    alter table(:clinics) do
      add(:msg_lembrete_horas, :bigint, default: 2)
    end

    recriar_view(@view_antiga)
  end

  # `DROP VIEW` leva os grants junto; o role de leitura é provisionado fora da migration (ele tem
  # senha, e senha não mora aqui), então o `IF EXISTS` cobre o banco em que ele ainda não existe.
  defp recriar_view(sql) do
    execute("CREATE VIEW metrics_clinics AS #{sql}")
    execute("COMMENT ON VIEW metrics_clinics IS '#{@comentario}'")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'cinetra_metrics') THEN
        GRANT SELECT ON public.metrics_clinics TO cinetra_metrics;
      END IF;
    END
    $$
    """)
  end
end
