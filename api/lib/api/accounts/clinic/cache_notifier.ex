defmodule Api.Accounts.Clinic.CacheNotifier do
  @moduledoc """
  Derruba o fuso desta clínica do cache (`Api.Accounts.ClinicTimezone`) quando a clínica muda.

  ## Por que notifier, e não um `change` na ação

  A tentativa óbvia — um `change` com hook de `after_transaction` em `update_settings` — **quebra
  a ação**: hook de transação é incompatível com update atômico, e o Ash recusa com
  `MustBeAtomic`. Sairia caro pelo lado errado: para invalidar um cache, a escrita deixaria de
  ser atômica (o mesmo `require_atomic? false` que o `SetTenantGuc` força nos recursos
  por-tenant, e que aqui não é necessário).

  O notifier roda **depois do commit**, fora da transação, e é o próprio Ash quem o segura até
  lá. Some o dilema e some também o pé-de-página de manutenção: a invalidação vale para
  **qualquer** ação de escrita da clínica, e não para a lista de ações que alguém lembrou de
  anotar no dia — inclusive as que ainda não existem.

  Invalida em vez de reescrever com o valor novo: o banco continua a fonte de verdade, e a
  próxima leitura vai lá.
  """
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{resource: Api.Accounts.Clinic, data: %{id: id}})
      when is_binary(id) do
    Api.Accounts.ClinicTimezone.invalidate(id)
    :ok
  end

  @impl true
  def notify(_notification), do: :ok
end
