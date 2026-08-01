defmodule Api.Repo.Migrations.RemoverConfirmacaoNaCriacao do
  @moduledoc """
  A confirmação na criação do agendamento sai; o lembrete vira 2 h e nasce ligado (doc 98).

  Gerada por `mix ash.codegen` e depois **editada à mão** em três pontos — cada um por um motivo
  que o gerador não tem como saber:

  ## 1. A view `metrics_clinics` cita a coluna que está sendo removida

  O `DROP COLUMN` sozinho falha com `cannot drop column msg_confirmacao_auto ... because other
  objects depend on it`. `CREATE OR REPLACE VIEW` também não resolve: o Postgres permite *acrescentar*
  coluna ao fim de uma view, nunca remover. Então é `DROP VIEW` → alterar a tabela → recriar a view.

  É o conserto mecânico que a `MetricsViews` (doc 73 §6) já antecipava no próprio moduledoc — só
  que ele previa o caso de *mudança de tipo*, e o primeiro a acontecer de verdade foi a remoção.

  Como `DROP VIEW` leva junto os `GRANT`, o bloco que reconcede a leitura ao `cinetra_metrics` é
  repetido aqui. Sem ele o painel do Grafana perde a view — em silêncio, porque a query passa a
  falhar do lado do datasource, não do deploy.

  ## 2. O backfill de `msg_lembrete_horas`

  Trocar o `default` só vale para clínica **nova**. Como a confirmação na criação era o único
  disparo automático ao paciente, deixar as existentes em `NULL` (= desligado) as deixaria mudas —
  a remoção da confirmação viraria "a comunicação automática parou de funcionar". O `UPDATE`
  preenche 2 h onde ninguém tinha escolhido nada.

  Decisão humana explícita de 2026-07-31, e com custo: no deploy, toda clínica com sessões passa a
  mandar lembrete — no WhatsApp, mensagem paga. Quem não quiser desliga na tela de comunicação.

  ## 3. O `down` é parcial, e isso está declarado

  Ele recria a coluna, o default antigo e a view antiga. **Não desfaz o backfill**: depois do
  `UPDATE` não há como distinguir "2 h porque a migration preencheu" de "2 h porque a clínica
  escolheu", e chutar apagaria uma escolha real. Reverter é voltar o código, não o dado.
  """

  use Ecto.Migration

  # A definição ANTERIOR, para o `down` — a única cópia dela, já que o `up` a substitui.
  @view_antiga """
  SELECT id, nome, timezone, slot_minutos, cap_turma_padrao,
         msg_confirmacao_auto, msg_lembrete_horas,
         (zernio_account_id IS NOT NULL) AS whatsapp_configurado,
         inserted_at
    FROM clinics
  """

  # A nova: a mesma lista, sem a coluna que deixou de existir.
  @view_nova """
  SELECT id, nome, timezone, slot_minutos, cap_turma_padrao,
         msg_lembrete_horas,
         (zernio_account_id IS NOT NULL) AS whatsapp_configurado,
         inserted_at
    FROM clinics
  """

  @comentario "Clínicas — sem CNPJ e sem endereço; nome serve de rótulo nos painéis."

  def up do
    execute("DROP VIEW IF EXISTS metrics_clinics")

    alter table(:clinics) do
      remove(:msg_confirmacao_auto)
      modify(:msg_lembrete_horas, :bigint, default: 2)
    end

    # Ver §2 do moduledoc. `WHERE ... IS NULL` para não pisar em quem já escolheu um número.
    execute("UPDATE clinics SET msg_lembrete_horas = 2 WHERE msg_lembrete_horas IS NULL")

    recriar_view(@view_nova)
  end

  def down do
    execute("DROP VIEW IF EXISTS metrics_clinics")

    alter table(:clinics) do
      modify(:msg_lembrete_horas, :bigint, default: nil)
      add(:msg_confirmacao_auto, :boolean, null: false, default: true)
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
