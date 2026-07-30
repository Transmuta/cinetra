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

  @tenant_guc "cinetra.clinic_id"

  # As GUCs das DUAS portas sem sessão da comunicação com o paciente (doc 52 §10.2). Ver
  # `with_provider_message/2` e `with_message/2` — e o moduledoc delas para por que existem.
  @provider_guc "cinetra.provider_message_id"
  @message_guc "cinetra.message_id"

  @doc """
  Injeta a GUC `cinetra.clinic_id` no início de toda transação **de leitura** que tem um
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
  Roda `fun` com o GUC `cinetra.clinic_id` setado (transação-local) para as RLS
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

  @doc """
  Roda `fun` enxergando **uma** mensagem pelo id que o provider devolveu — a porta do webhook
  (doc 52 §10.2).

  O evento de entrega chega sem `clinic_id`: o que ele traz é o id que o próprio provider gerou no
  envio. A busca por esse id precisa acontecer **antes** de saber a clínica — é ela que descobre a
  clínica. Sem esta GUC a policy de `messages` devolveria zero linhas e o webhook responderia 200
  sem fazer nada, para sempre, sem erro em lugar nenhum.

  O id veio num payload cuja assinatura já foi conferida (`Api.Messaging.Svix`).
  """
  def with_provider_message(provider_message_id, fun) when is_binary(provider_message_id) do
    com_guc(@provider_guc, provider_message_id, fun)
  end

  @doc """
  Roda `fun` enxergando **uma** mensagem pelo id dela — a porta da resposta do paciente
  (doc 52 §5).

  Mesmo problema do webhook, e foi por não ver que era o mesmo que ele nasceu quebrado: o link do
  e-mail carrega só o `message_id` (no token assinado) e a rota roda **sem sessão e sem GUC**. A
  policy comparava `clinic_id = NULL`, não casava linha, e todo link legítimo respondia
  "link inválido" — com os testes da rota verdes, porque o sandbox conecta como `postgres`.

  O id veio de um token que **nós** assinamos (`Api.Messaging.ReplyToken`), e um token forjado não
  passa da verificação — a exceção não é alcançável sem ele.

  ## Por que as duas são estreitas

  Cada uma alcança **uma** linha, identificada por um segredo que o chamador já provou possuir. Não
  há varredura: `provider_message_id` e `id` são opacos e únicos, e GUC vazia não casa nada
  (`nullif(…, '')`). A prova está no gate `:rls` — e ela foi tirada ao vivo no bate-volta:
  com a GUC do provider setada, `SELECT count(*) FROM messages` devolve **1**; com ela vazia, **0**.
  """
  def with_message(message_id, fun) when is_binary(message_id) do
    com_guc(@message_guc, message_id, fun)
  end

  defp com_guc(guc, valor, fun) do
    transaction(fn ->
      query!("SELECT set_config($1, $2, true)", [guc, valor])
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
