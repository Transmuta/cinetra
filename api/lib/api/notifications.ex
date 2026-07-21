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
      define :list_notifications, action: :read
      define :list_unread_notifications, action: :unread
      define :get_notification, action: :read, get_by: [:id]
      define :do_mark_read, action: :mark_read
    end
  end

  @doc "A caixa do usuário na clínica ativa — recente no topo, recortada por destinatário na policy."
  def list_inbox(%Api.Scope{} = scope, opts \\ []) do
    in_clinic(scope, fn ->
      case Keyword.get(opts, :only_unread, false) do
        true -> list_unread_notifications!(scope: scope)
        _ -> list_notifications!(scope: scope, query: [sort: [inserted_at: :desc]])
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

  @doc "Marca todas as não-lidas do usuário como lidas. Devolve quantas foram tocadas."
  def mark_all_read(%Api.Scope{} = scope) do
    in_clinic(scope, fn ->
      unread = list_unread_notifications!(scope: scope)
      Enum.each(unread, &do_mark_read!(&1, scope: scope, return_notifications?: true))
      length(unread)
    end)
  end

  # `return_notifications?: true` acima: a escrita roda dentro da transação do `in_clinic` (exigência
  # da RLS — ver o moduledoc de `mark_read`). O Ash não despacha notificações de dentro de uma
  # transação que ele não abriu, então sem isso ele avisa "Missed notifications" a cada marcação. O
  # recurso não tem assinante de notificação (nenhum `Ash.Notifier`), então devolvê-las e descartar
  # é o descarte correto — silencia o aviso sem perder nada.
end
