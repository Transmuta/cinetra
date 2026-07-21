defmodule Api.Notifications.NotificationTest do
  @moduledoc """
  A caixa de notificações in-app (doc 31): leitura recortada por destinatário, contagem de
  não-lidas (o badge), marcar lida (uma e todas) e o isolamento entre usuários da mesma clínica.

  A RLS (ADR-018) **não** é exercida aqui — o sandbox conecta como `postgres` (BYPASSRLS). A prova
  do isolamento por clínica é por `psql`, fora da suíte; o recorte por destinatário testado aqui é
  o da policy do recurso.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Notifications

  defp email, do: "notif-#{System.unique_integer([:positive])}@example.com"

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp member(clinic, papel) do
    user = Accounts.register_user!("Membro #{papel}", email(), authorize?: false)
    {:ok, m} = Accounts.invite_member(%{papel: papel, user_id: user.id, clinic_id: clinic.id}, authorize?: false)
    {:ok, _} = Accounts.accept_invite(m, authorize?: false)
    user
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp notify(clinic, recipient, attrs \\ %{}) do
    Notifications.create_notification(
      Map.merge(
        %{recipient_id: recipient.id, kind: :member_joined, title: "Título", body: "Corpo", data: %{}},
        attrs
      ),
      tenant: clinic.id,
      authorize?: false
    )
  end

  describe "leitura da caixa" do
    test "lista as notificações do usuário, recente no topo" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, _} = notify(clinic, owner, %{title: "Primeira"})
      {:ok, _} = notify(clinic, owner, %{title: "Segunda"})

      titulos = Notifications.list_inbox(scope) |> Enum.map(& &1.title)
      assert titulos == ["Segunda", "Primeira"]
    end

    test "cada um só vê a própria caixa (recorte por destinatário)" do
      {owner, clinic} = owner_and_clinic()
      recep = member(clinic, :recepcao)

      {:ok, minha} = notify(clinic, owner, %{title: "Do dono"})

      owner_ids = Notifications.list_inbox(scope_for(owner, clinic)) |> Enum.map(& &1.id)
      recep_ids = Notifications.list_inbox(scope_for(recep, clinic)) |> Enum.map(& &1.id)

      assert minha.id in owner_ids
      refute minha.id in recep_ids
      # A recepção não é destinatária de nada aqui (o member_joined do seu aceite vai ao owner).
      assert recep_ids == []
    end
  end

  describe "não-lidas e marcar lida" do
    test "unread_count conta só as não-lidas" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, _} = notify(clinic, owner)
      {:ok, n2} = notify(clinic, owner)

      assert Notifications.unread_count(scope) == 2

      {:ok, _} = Notifications.mark_read(scope, n2.id)
      assert Notifications.unread_count(scope) == 1
    end

    test "marcar lida grava o instante e é idempotente" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      {:ok, n} = notify(clinic, owner)

      {:ok, lida} = Notifications.mark_read(scope, n.id)
      assert %DateTime{} = lida.read_at

      {:ok, relida} = Notifications.mark_read(scope, n.id)
      assert relida.read_at == lida.read_at
    end

    test "não dá para marcar a notificação de outro usuário (404)" do
      {owner, clinic} = owner_and_clinic()
      recep = member(clinic, :recepcao)
      {:ok, n} = notify(clinic, owner)

      assert {:error, :not_found} = Notifications.mark_read(scope_for(recep, clinic), n.id)
    end

    test "mark_all_read zera o badge e devolve quantas tocou" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, _} = notify(clinic, owner)
      {:ok, _} = notify(clinic, owner)
      {:ok, ja_lida} = notify(clinic, owner)
      {:ok, _} = Notifications.mark_read(scope, ja_lida.id)

      assert Notifications.mark_all_read(scope) == 2
      assert Notifications.unread_count(scope) == 0
    end
  end
end
