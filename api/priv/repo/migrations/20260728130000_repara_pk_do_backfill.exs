defmodule Api.Repo.Migrations.ReparaPkDoBackfill do
  @moduledoc """
  Conserta as linhas que o backfill gravou com PK **v4** (bate-volta, causa C1).

  `20260728060000_backfill_audit_events.exs` gerava o `id` com `gen_random_uuid()`, que produz
  UUID **v4**. A coluna é `uuid_v7_primary_key`, e o `Ash.Type.UUIDv7` valida a versão **ao
  carregar** — então cada linha migrada era ilegível, e como o Ash carrega o conjunto, **uma**
  linha ruim devolvia 500 na página inteira. Medido em dev: 294 de 588 linhas em v4, e
  `GET /api/audit` respondendo `status=500` em toda clínica com histórico migrado.

  A migration de origem foi corrigida (banco novo já nasce certo). Esta existe para os bancos que
  **já rodaram** a versão defeituosa — dev, e qualquer ambiente que tenha feito o deploy no
  intervalo.

  ## Por que é seguro trocar a PK

  `audit_events.id` não é referenciado por ninguém: `record_id` e `user_id` são uuid crus por
  decisão (a linha precisa sobreviver ao que registra), e nenhuma outra tabela aponta para cá. O
  `id` serve a duas coisas — identidade da linha e **desempate** do `ORDER BY at DESC, id DESC`.
  A ordem cronológica é definida por `at` (o instante real do evento, preservado do backfill);
  o `id` só decide empates dentro do mesmo instante, então regerá-lo não reordena o feed.

  Idempotente: só toca linha cuja versão não é 7.
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE audit_events
       SET id = uuid_generate_v7()
     WHERE substring(id::text, 15, 1) <> '7'
    """
  end

  def down do
    # Não há volta: os ids v4 originais não foram guardados, e não teriam serventia — eram
    # justamente o defeito. O `down` é no-op deliberado, não esquecimento.
    :ok
  end
end
