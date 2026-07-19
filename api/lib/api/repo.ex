defmodule Api.Repo do
  use AshPostgres.Repo, otp_app: :api

  @impl true
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  # Abre transação por ação (default do AshPostgres). Necessário para o RLS: a GUC de
  # tenant é `SET LOCAL` (transação-local), setada no `on_transaction_begin/1` abaixo.
  # Sem transação não haveria onde escopar a GUC com segurança (ADR-018).
  @impl true
  def prefer_transaction? do
    true
  end

  @tenant_guc "movimento.clinic_id"

  @doc """
  Injeta a GUC `movimento.clinic_id` no início de toda transação **de leitura** que tem um
  tenant no contexto (ADR-018).

  ATENÇÃO ao alcance real: só funciona em `read`. O `transaction_reason` do Ash carrega o
  tenant em `metadata.query` (read), mas nos reasons de create/update/destroy o
  `data_layer_context` é opcional e o Ash **não** o preenche (ver
  `Ash.DataLayer.transaction_reason` e `ash/lib/ash/actions/create/create.ex`) — não há de
  onde tirar o tenant aqui. Escrita por-tenant portanto **não** passa por este ponto: ela
  seta a GUC via `Api.Tenancy.SetTenantGuc` (`before_action`, dentro da transação
  da própria ação). Transações sem tenant (recursos globais) não setam nada.
  """
  @impl true
  def on_transaction_begin(reason) do
    case tenant_from_reason(reason) do
      nil -> :ok
      tenant -> set_clinic_guc(to_string(tenant))
    end
  end

  @doc """
  Seta a GUC de tenant (`SET LOCAL`, transação-local) na transação corrente. Exige uma
  transação aberta — fora dela o `set_config(..., true)` não teria onde valer.
  """
  def set_clinic_guc(clinic_id) when is_binary(clinic_id) do
    query!("SELECT set_config($1, $2, true)", [@tenant_guc, clinic_id])
    :ok
  end

  defp tenant_from_reason(%{data_layer_context: %{tenant: tenant}}) when not is_nil(tenant),
    do: tenant

  defp tenant_from_reason(%{metadata: %{query: %{tenant: tenant}}}) when not is_nil(tenant),
    do: tenant

  defp tenant_from_reason(_reason), do: nil

  @doc """
  Roda `fun` com o GUC `movimento.clinic_id` setado (transação-local) para as RLS
  policies (ADR-018). Toda operação em recurso por-tenant deve passar por aqui —
  no app, o plug de scope da sessão (ADR-014) é quem chama. `SET LOCAL` exige a
  transação; sem GUC as policies falham fechando (0 linhas).
  """
  def with_clinic(clinic_id, fun) when is_binary(clinic_id) do
    transaction(fn ->
      query!("SELECT set_config($1, $2, true)", [@tenant_guc, clinic_id])
      fun.()
    end)
  end

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    # citext: coluna case-insensitive do User.email (:ci_string).
    # btree_gist: exigida pela exclusion constraint `appointments_no_overlap`, que combina
    # igualdade em `professional_id` (btree) com sobreposição de `tstzrange` (gist) no mesmo
    # índice. Sem ela o `EXCLUDE USING gist (professional_id WITH =, ...)` não compila (25 §4).
    ["ash-functions", "citext", "btree_gist"]
  end
end
