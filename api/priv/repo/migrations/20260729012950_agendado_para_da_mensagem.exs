defmodule Api.Repo.Migrations.AgendadoParaDaMensagem do
  @moduledoc """
  `messages.agendado_para` — o instante para o qual a janela de silêncio (doc 52 §7) adiou o envio.

  ## Os índices de `audit_events` aqui são no-op DE PROPÓSITO

  O gerador propôs `DROP` + `CREATE` do `audit_events_feed_index` e a criação dos dois índices de
  faceta. Os três **já existem**: vieram das migrations à mão `20260728140000` (feed com desempate,
  com `CONCURRENTLY`) e `20260728150000` (facetas), que rodam antes desta em qualquer banco. O
  codegen os repete só porque o snapshot ainda não os conhecia.

  Deixá-los como o gerador escreveu quebraria o deploy de duas formas: `create index` sem guarda
  estoura em "relation already exists", e o par DROP+CREATE comum tomaria `ShareLock` na tabela
  mais escrita do sistema — dentro do `release_command`, que é justamente a janela que
  `.claude/rules/migrations.md` §2 manda evitar. Guardados com `if_not_exists`, eles alinham o
  snapshot sem tocar no banco.

  O `down` desfaz só a coluna: os índices são das outras migrations, e derrubá-los aqui apagaria
  trabalho que não é desta.
  """
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add(:agendado_para, :utc_datetime)
    end

    create_if_not_exists(
      index(:audit_events, [:clinic_id, :resource, :at], name: "audit_events_resource_index")
    )

    create_if_not_exists(
      index(:audit_events, [:clinic_id, :action, :at], name: "audit_events_action_index")
    )

    create_if_not_exists(
      index(:audit_events, [:clinic_id, :at, :id], name: "audit_events_feed_index")
    )
  end

  def down do
    alter table(:messages) do
      remove(:agendado_para)
    end
  end
end
