defmodule ApiWeb.NotificationsControllerTest do
  @moduledoc """
  Endpoints da caixa de notificações (doc 31). Integração real: sessão + `LoadScope`, a leitura
  recortada por destinatário (cada um só vê a própria), o contador do badge e o "marcar lida"
  (uma e todas). `clinic_id` sempre do escopo.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Notifications

  defp fixture do
    owner = sign_in!(email_unico("nc"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    %{owner: owner, clinic: clinic}
  end

  defp notify(clinic, recipient, attrs \\ %{}) do
    {:ok, n} =
      Notifications.create_notification(
        Map.merge(
          %{recipient_id: recipient.id, kind: :member_joined, title: "T", body: "B", data: %{}},
          attrs
        ),
        tenant: clinic.id,
        authorize?: false
      )

    n
  end

  describe "GET /api/notifications" do
    test "devolve a caixa do usuário e o contador de não-lidas" do
      ctx = fixture()
      notify(ctx.clinic, ctx.owner, %{title: "Primeira"})
      notify(ctx.clinic, ctx.owner, %{title: "Segunda"})

      body = as(ctx.owner) |> get("/api/notifications") |> json_response(200)

      assert body["unread"] == 2
      assert Enum.map(body["notifications"], & &1["title"]) == ["Segunda", "Primeira"]
      assert Enum.all?(body["notifications"], &(&1["read"] == false))
    end

    test "sem sessão responde 401" do
      assert Phoenix.ConnTest.build_conn() |> get("/api/notifications") |> json_response(401)
    end

    test "?unread=1 traz só as não-lidas" do
      ctx = fixture()
      lida = notify(ctx.clinic, ctx.owner)
      notify(ctx.clinic, ctx.owner, %{title: "Nova"})
      {:ok, _} = Notifications.mark_read(scope(ctx), lida.id)

      body = as(ctx.owner) |> get("/api/notifications?unread=1") |> json_response(200)
      assert length(body["notifications"]) == 1
    end

    # #54 — o envelope `page` de pacientes/trilha/fila (09 §8), menos o `total`: a caixa não
    # exibe "X–Y de Z" e o total custaria ler o recorte inteiro a cada abertura.
    test "pagina com limit/offset e diz se há mais" do
      ctx = fixture()
      for i <- 1..5, do: notify(ctx.clinic, ctx.owner, %{title: "N#{i}"})

      body = as(ctx.owner) |> get("/api/notifications?limit=2") |> json_response(200)

      assert length(body["notifications"]) == 2
      # `total` sai SEMPRE, e vem `nil` quando a leitura não contou (doc 96, H-8). A caixa do
      # sino é `count: false` de propósito — quem conta é o `unread_count/1`, no índice parcial.
      assert body["page"] == %{"limit" => 2, "offset" => 0, "more" => true, "total" => nil}

      segunda = as(ctx.owner) |> get("/api/notifications?limit=2&offset=4") |> json_response(200)
      assert length(segunda["notifications"]) == 1
      assert segunda["page"]["more"] == false
    end

    # O caminho do badge é o mais chamado do sistema (todo carregamento de layout). Com a lista
    # limitada, `unread` só pode vir do COUNT do recorte — contar a página daria "1".
    test "?unread=1 conta todas as não-lidas, mesmo com a página limitada" do
      ctx = fixture()
      for i <- 1..4, do: notify(ctx.clinic, ctx.owner, %{title: "N#{i}"})

      body = as(ctx.owner) |> get("/api/notifications?unread=1&limit=1") |> json_response(200)

      assert length(body["notifications"]) == 1
      assert body["unread"] == 4
    end
  end

  # Bate-volta (2ª passada). O caminho do badge roda no load do layout, ou seja, em **toda**
  # navegação do sistema — é o endpoint mais chamado que existe aqui. Ele fazia duas queries, e
  # a primeira era lixo: uma lista de 1 linha que o BFF descartava para ler só o número. Medido
  # numa navegação real a `/pacientes`:
  #
  #     SELECT n0."read_at" FROM "notifications" ... (limit 1)   ← ninguém lê o resultado
  #     SELECT coalesce(count(*), $1) FROM "notifications" ...   ← o número
  describe "GET /api/notifications/unread-count" do
    test "devolve só o número, e toca a tabela uma vez só" do
      ctx = fixture()
      for _ <- 1..3, do: notify(ctx.clinic, ctx.owner)

      {body, queries} =
        Api.QueryCounter.count(
          fn -> as(ctx.owner) |> get("/api/notifications/unread-count") |> json_response(200) end,
          "notifications"
        )

      assert body == %{"unread" => 3}
      assert queries == 1
    end

    test "sem sessão responde 401" do
      assert Phoenix.ConnTest.build_conn()
             |> get("/api/notifications/unread-count")
             |> json_response(401)
    end

    test "conta só as do próprio destinatário" do
      ctx = fixture()
      notify(ctx.clinic, ctx.owner)

      outro = sign_in!(email_unico("nc"))

      {:ok, m} =
        Accounts.invite_member(%{papel: :recepcao, user_id: outro.id, clinic_id: ctx.clinic.id},
          authorize?: false
        )

      {:ok, _} = Accounts.accept_invite(m, authorize?: false)

      body = as(outro) |> get("/api/notifications/unread-count") |> json_response(200)
      assert body["unread"] == 0
    end
  end

  describe "POST /api/notifications/:id/read" do
    test "marca uma como lida" do
      ctx = fixture()
      n = notify(ctx.clinic, ctx.owner)

      body = as(ctx.owner) |> post("/api/notifications/#{n.id}/read") |> json_response(200)
      assert body["notification"]["read"] == true
    end

    test "id inexistente/de outro dono responde 404" do
      ctx = fixture()

      assert as(ctx.owner)
             |> post("/api/notifications/#{Ecto.UUID.generate()}/read")
             |> json_response(404)
    end
  end

  describe "POST /api/notifications/read-all" do
    test "zera o badge e devolve quantas marcou" do
      ctx = fixture()
      notify(ctx.clinic, ctx.owner)
      notify(ctx.clinic, ctx.owner)

      body = as(ctx.owner) |> post("/api/notifications/read-all") |> json_response(200)
      assert body["marked"] == 2
      assert body["unread"] == 0

      assert as(ctx.owner) |> get("/api/notifications") |> json_response(200) |> Map.get("unread") ==
               0
    end
  end

  describe "DELETE /api/notifications" do
    test "esvazia a caixa e devolve quantas apagou" do
      ctx = fixture()
      n = notify(ctx.clinic, ctx.owner)
      notify(ctx.clinic, ctx.owner)
      {:ok, _} = Notifications.mark_read(scope(ctx), n.id)

      body = as(ctx.owner) |> delete("/api/notifications") |> json_response(200)
      assert body["cleared"] == 2
      assert body["unread"] == 0

      depois = as(ctx.owner) |> get("/api/notifications") |> json_response(200)
      assert depois["notifications"] == []
      assert depois["unread"] == 0
    end

    test "sem sessão responde 401" do
      assert Phoenix.ConnTest.build_conn() |> delete("/api/notifications") |> json_response(401)
    end

    test "não apaga a caixa do colega" do
      ctx = fixture()
      outro = sign_in!(email_unico("nc"))

      {:ok, m} =
        Accounts.invite_member(%{papel: :recepcao, user_id: outro.id, clinic_id: ctx.clinic.id},
          authorize?: false
        )

      {:ok, _} = Accounts.accept_invite(m, authorize?: false)
      notify(ctx.clinic, outro)

      assert as(ctx.owner) |> delete("/api/notifications") |> json_response(200)

      body = as(outro) |> get("/api/notifications") |> json_response(200)
      assert body["unread"] == 1
    end
  end

  defp scope(ctx) do
    {:ok, membership} =
      Accounts.get_active_membership(ctx.owner.id, ctx.clinic.id, authorize?: false)

    Api.Scope.with_membership(ctx.owner, membership)
  end
end
