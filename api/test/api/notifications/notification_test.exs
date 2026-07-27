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

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email_unico("notif"), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp member(clinic, papel) do
    user = Accounts.register_user!("Membro #{papel}", email_unico("notif"), authorize?: false)

    {:ok, m} =
      Accounts.invite_member(%{papel: papel, user_id: user.id, clinic_id: clinic.id},
        authorize?: false
      )

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
        %{
          recipient_id: recipient.id,
          kind: :member_joined,
          title: "Título",
          body: "Corpo",
          data: %{}
        },
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

      titulos = Notifications.list_inbox(scope).results |> Enum.map(& &1.title)
      assert titulos == ["Segunda", "Primeira"]
    end

    test "cada um só vê a própria caixa (recorte por destinatário)" do
      {owner, clinic} = owner_and_clinic()
      recep = member(clinic, :recepcao)

      {:ok, minha} = notify(clinic, owner, %{title: "Do dono"})

      owner_ids = Notifications.list_inbox(scope_for(owner, clinic)).results |> Enum.map(& &1.id)
      recep_ids = Notifications.list_inbox(scope_for(recep, clinic)).results |> Enum.map(& &1.id)

      assert minha.id in owner_ids
      refute minha.id in recep_ids

      # A recepção não é destinatária de nada aqui (o member_joined do seu aceite vai ao owner).
      assert recep_ids == []
    end
  end

  # #54 (P3 do doc 32). A caixa não tinha teto: a sonda com volume mediu `list_inbox` trazendo
  # 20.065 linhas em 583 ms — e o caminho do badge (`?unread=1`, chamado em TODA navegação do web)
  # trafegava as 4.065 não-lidas inteiras para ler **um número**.
  describe "paginação da caixa (#54)" do
    test "limita a página e diz se há mais" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      for i <- 1..5, do: {:ok, _} = notify(clinic, owner, %{title: "N#{i}"})

      page = Notifications.list_inbox(scope, limit: 2)

      assert length(page.results) == 2
      assert page.more?

      # Sem `count` de propósito: o total custaria ler o recorte inteiro (10.265 buffers contra
      # 26 na sonda), e a tela não exibe "X–Y de Z". O `more?` sai do `limit + 1`.
      refute page.count
    end

    test "o offset traz a página seguinte, sem repetir" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      for i <- 1..5, do: {:ok, _} = notify(clinic, owner, %{title: "N#{i}"})

      primeira = Notifications.list_inbox(scope, limit: 2).results |> Enum.map(& &1.title)

      segunda =
        Notifications.list_inbox(scope, limit: 2, offset: 2).results |> Enum.map(& &1.title)

      assert primeira == ["N5", "N4"]
      assert segunda == ["N3", "N2"]
    end

    # A regressão que a própria paginação cria: contar o que chegou passaria a contar só a página.
    test "a contagem de não-lidas é a do recorte, não a da página" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      for _ <- 1..4, do: {:ok, _} = notify(clinic, owner)

      page = Notifications.list_inbox(scope, only_unread: true, limit: 1)

      assert length(page.results) == 1
      assert Notifications.unread_count(scope) == 4
    end

    test "o teto de página barra um limit absurdo" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      {:ok, _} = notify(clinic, owner)

      assert Notifications.list_inbox(scope, limit: 10_000).limit == 200
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

    # #53 (P2 do doc 32): eram 1 SELECT + N×(SELECT da policy + UPDATE) em série. O teto é o
    # conserto — sem ele, "marcar todas" volta a ser O(N) sem ninguém perceber.
    test "mark_all_read toca a tabela em O(1), não O(N)" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      for _ <- 1..6, do: {:ok, _} = notify(clinic, owner)

      {marcadas, queries} =
        Api.QueryCounter.count(fn -> Notifications.mark_all_read(scope) end, "notifications")

      assert marcadas == 6

      # 1 COUNT (para o número devolvido) + 1 UPDATE. No caminho antigo, 6 não-lidas custavam 13.
      assert queries == 2
    end

    test "marcar todas não alcança a caixa do colega" do
      {owner, clinic} = owner_and_clinic()

      # O aceite do convite já notifica o owner (`member_joined`) — a caixa dele não começa vazia.
      recep = member(clinic, :recepcao)
      {:ok, _} = notify(clinic, owner)
      {:ok, do_colega} = notify(clinic, recep)

      owner_scope = scope_for(owner, clinic)
      do_owner = Notifications.unread_count(owner_scope)
      assert do_owner >= 2

      assert Notifications.mark_all_read(owner_scope) == do_owner
      assert Notifications.unread_count(owner_scope) == 0

      # A policy é filter-check; num UPDATE em massa ela precisa virar cláusula do WHERE, e não
      # sobrar como checagem por registro que o caminho atômico pula.
      assert Notifications.unread_count(scope_for(recep, clinic)) == 1

      assert %{read_at: nil} =
               Notifications.get_notification!(do_colega.id,
                 authorize?: false,
                 tenant: clinic.id
               )
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

  describe "limpar a caixa" do
    test "apaga tudo do usuário — lidas e não-lidas — e devolve quantas" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, _} = notify(clinic, owner)
      {:ok, lida} = notify(clinic, owner)
      {:ok, _} = Notifications.mark_read(scope, lida.id)

      assert Notifications.clear_all(scope) == 2
      assert Notifications.unread_count(scope) == 0
      assert Notifications.list_inbox(scope).results == []
    end

    test "caixa vazia devolve 0 sem estourar" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      _ = Notifications.clear_all(scope)

      assert Notifications.clear_all(scope) == 0
    end

    # O gêmeo do "marcar todas não alcança a caixa do colega", e aqui a aposta é maior: um DELETE
    # que escape do recorte não deixa o dado ilegível, deixa-o **inexistente**. A policy é
    # filter-check; no caminho atômico ela precisa virar cláusula do WHERE do DELETE.
    test "limpar não alcança a caixa do colega" do
      {owner, clinic} = owner_and_clinic()
      recep = member(clinic, :recepcao)
      {:ok, _} = notify(clinic, owner)
      {:ok, do_colega} = notify(clinic, recep)

      _ = Notifications.clear_all(scope_for(owner, clinic))

      assert Notifications.unread_count(scope_for(recep, clinic)) == 1

      assert %{id: _} =
               Notifications.get_notification!(do_colega.id,
                 authorize?: false,
                 tenant: clinic.id
               )
    end

    # Mesmo teto do #53: limpar é UM DELETE, não N. Sem o teto, o caminho volta a ser O(N) —
    # e numa caixa de um ano (a sonda do #54 mediu 20.065 linhas) isso é um travamento.
    test "clear_all toca a tabela em O(1), não O(N)" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      for _ <- 1..6, do: {:ok, _} = notify(clinic, owner)

      {apagadas, queries} =
        Api.QueryCounter.count(fn -> Notifications.clear_all(scope) end, "notifications")

      assert apagadas == 6

      # 1 COUNT (para o número devolvido) + 1 DELETE.
      assert queries == 2
    end
  end
end
