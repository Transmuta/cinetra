defmodule Api.Tenancy.SetTenantGuc do
  @moduledoc """
  Injeta a GUC `cinetra.clinic_id` na transação da própria ação, para que a RLS (ADR-018)
  aceite o INSERT/UPDATE de recurso por-tenant.

  ## Por que isto existe

  O `Api.Repo.on_transaction_begin/1` promete injetar a GUC em "qualquer ação Ash sobre
  recurso por-tenant", mas só consegue fazê-lo em **leitura**: o `transaction_reason` do Ash
  carrega o tenant em `metadata.query` (read), enquanto nos reasons de create/update/destroy
  o `data_layer_context` é opcional e o Ash **não** o preenche (ver
  `Ash.DataLayer.transaction_reason` e `ash/lib/ash/actions/create/create.ex`). Sem GUC, o
  `WITH CHECK` da policy barra a escrita e a ação inteira volta.

  ## Por que como `before_action`, e não envolvendo a chamada num `with_clinic`

  `Api.Repo.with_clinic/2` abre uma transação **por fora** da ação. Quando a ação falha
  (nome duplicado, validação), o Ash chama `Repo.rollback` na transação interna, o que
  arrebenta a transação externa e transforma um `{:error, changeset}` — que deveria virar
  422 — em `Ash.Error.Unknown` (500). O `before_action` roda **dentro** da transação da
  própria ação, logo antes da escrita: a GUC entra no lugar certo e o caminho de erro
  continua sendo ok/error normal.

  Nada disso aparece na suíte: o sandbox de teste conecta como `postgres` (BYPASSRLS). Só
  morde no servidor real (`cinetra_app`, NOBYPASSRLS).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case changeset.tenant do
        nil -> changeset
        tenant -> set_guc(changeset, tenant)
      end
    end)
  end

  # Ação por-tenant sempre tem tenant; se um dia não tiver, deixamos a RLS barrar (fail
  # closed) em vez de escrever sem escopo.
  defp set_guc(changeset, tenant) do
    Api.Repo.set_clinic_guc(to_string(tenant))
    changeset
  end
end
