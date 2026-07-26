defmodule Api.Notifications do
  @moduledoc """
  Domínio das notificações in-app (doc 31). Recurso por-tenant por atributo (`clinic_id`,
  ADR-017/018) destinado a um usuário. Como em `Api.Scheduling`/`Api.Waitlist`, os **wrappers
  deste módulo** centralizam o `Api.Repo.with_clinic/2` (GUC de tenant para a RLS) na leitura —
  os controllers chamam estas funções, não as code interfaces cruas. A escrita seta a GUC dentro
  da própria ação (`SetTenantGuc`).

  A caixa é escrita pelo `Api.Notifications.Fanout` (após o commit do evento de origem); esta
  camada expõe só a leitura e o "marcar lida" da UI.
  """
  use Ash.Domain, otp_app: :api

  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query

  resources do
    resource Api.Notifications.Notification do
      define :create_notification, action: :notify
      define :list_inbox_page, action: :inbox
      define :list_unread_notifications, action: :unread
      define :get_notification, action: :read, get_by: [:id]
      define :do_mark_read, action: :mark_read
    end
  end

  @doc """
  A caixa do usuário na clínica ativa — recente no topo, recortada por destinatário na policy.

  Devolve `%Ash.Page.Offset{}` (`results`, `limit`, `offset`, `more?`), como as demais listas do
  projeto. Opções: `:only_unread`, `:limit`, `:offset` — os tetos são de `Api.Pagination`.

  **O `page:` é posto aqui, não deixado a cargo de quem chama.** A ação tem `default_limit`, mas
  ela só vale para leitura já paginada; um `list_inbox_page!` sem `page:` voltaria a carregar
  tudo. Como todo acesso à caixa passa por este wrapper (é a convenção do domínio), é aqui que o
  teto é garantido.

  **Sem `count`** (divergência deliberada de pacientes/trilha/fila, que exibem "X–Y de Z"): a
  tela da caixa mostra "N não lidas" e um "carregar mais", e nenhum dos dois precisa do total.
  Pagá-lo custaria 10.265 buffers contra 26 — ver `Api.Pagination.page_opts/1`. Quem quer o
  número das não-lidas chama `unread_count/1`, que vai ao índice parcial.
  """
  def list_inbox(%Api.Scope{} = scope, opts \\ []) do
    page = Api.Pagination.page_opts(Keyword.put(opts, :count, false))

    in_clinic(scope, fn ->
      case Keyword.get(opts, :only_unread, false) do
        true -> list_unread_notifications!(scope: scope, page: page)
        _ -> list_inbox_page!(scope: scope, page: page)
      end
    end)
  end

  @doc """
  Quantas não-lidas o usuário tem na clínica ativa (o número do badge). É um `COUNT` no banco —
  não trazer as linhas para contar em memória (roda em toda navegação do web, via o layout).
  """
  def unread_count(%Api.Scope{} = scope) do
    in_clinic(scope, fn ->
      Api.Notifications.Notification
      |> Ash.Query.for_read(:unread, %{}, scope: scope)
      |> Ash.count!()
    end)
  end

  @doc """
  Marca uma notificação como lida. Fora do tenant/de outro dono → `{:error, :not_found}`.

  **Tudo dentro de `in_clinic`** — o buscar E o atualizar. A policy do `mark_read` é um
  filter-check (`recipient_id == actor`), então o `Ash.can` da própria escrita roda um SELECT na
  tabela **sob RLS**; a GUC de tenant precisa já estar setada aí, e o `SetTenantGuc` (before_action)
  roda tarde demais para essa consulta de autorização. Sem a GUC, a policy RLS recebe `''::uuid` e
  estoura (invisível ao `mix test`, que bypassa RLS). O `with_clinic` seta a GUC na transação
  inteira, cobrindo a autorização.
  """
  def mark_read(%Api.Scope{} = scope, id) when is_binary(id) do
    in_clinic(scope, fn ->
      case get_notification(id, scope: scope, not_found_error?: false) do
        {:ok, %{} = notification} ->
          case do_mark_read(notification, scope: scope, return_notifications?: true) do
            {:ok, updated, _notifications} -> {:ok, updated}
            other -> other
          end

        _ ->
          {:error, :not_found}
      end
    end)
  end

  @doc """
  Marca todas as não-lidas do usuário como lidas. Devolve quantas foram tocadas.

  Um `COUNT` e um `UPDATE` (#53) — antes era 1 SELECT + N×(SELECT da policy + UPDATE) em série.
  O `COUNT` existe só para o número devolvido; ele vai ao índice parcial das não-lidas, e é o
  preço de responder "quantas" num caminho que o Ash fecha sem contar as linhas
  (`%Ash.BulkResult{}` não traz total). Entre contar e atualizar cabe uma notificação nova: o
  número é um relato do que havia, não uma promessa sobre o que o UPDATE alcançou.
  """
  def mark_all_read(%Api.Scope{} = scope) do
    in_clinic(scope, fn ->
      query =
        Api.Notifications.Notification
        |> Ash.Query.for_read(:unread, %{}, scope: scope)

      quantas = Ash.count!(query)

      %Ash.BulkResult{status: :success} =
        Ash.bulk_update!(query, :mark_all_read, %{},
          scope: scope,
          strategy: :atomic,
          return_records?: false,
          notify?: false
        )

      quantas
    end)
  end

  # `return_notifications?: true` no `mark_read`, `notify?: false` no lote: os dois calam o mesmo
  # aviso, e pelo mesmo motivo. A escrita roda dentro da transação do `in_clinic` (exigência da
  # RLS — ver o moduledoc de `mark_read`), e o Ash não despacha notificações de dentro de uma
  # transação que ele não abriu: sem isso ele avisa "Missed notifications" a cada marcação. Como
  # o recurso não tem assinante nenhum (nenhum `Ash.Notifier`), descartá-las é o correto.
end
