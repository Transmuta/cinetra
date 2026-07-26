defmodule Api.Housekeeping.PruneNotificationsTest do
  @moduledoc """
  A poda da caixa de notificações (#54, P3 do doc 32 — "tabela sem expurgo").

  A retenção é assimétrica por decisão de produto: **lida** é histórico e sai em 90 dias;
  **não-lida** é trabalho pendente e só sai no teto de um ano, para que uma caixa abandonada
  também não cresça para sempre.

  O que se afirma aqui: a lida velha some, a lida recente fica, a não-lida velha **resiste** à
  janela curta e cai na longa, e a poda não atravessa clínica.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Housekeeping.PruneNotifications
  alias Api.Notifications

  defp notifica(ctx, attrs \\ %{}) do
    {:ok, n} =
      Notifications.create_notification(
        Map.merge(
          %{recipient_id: ctx.owner.id, kind: :member_joined, title: "T", body: "B", data: %{}},
          attrs
        ),
        tenant: ctx.clinic.id,
        authorize?: false
      )

    n
  end

  # Envelhece a linha na marra: `inserted_at` é carimbo do banco e não há ação que o mova.
  defp envelhecer(id, dias) do
    Api.Repo.query!(
      "UPDATE notifications SET inserted_at = inserted_at - ($1 || ' days')::interval WHERE id = $2",
      [to_string(dias), Ecto.UUID.dump!(id)]
    )
  end

  defp existe?(id) do
    {:ok, %{rows: [[n]]}} =
      Api.Repo.query("SELECT count(*) FROM notifications WHERE id = $1", [Ecto.UUID.dump!(id)])

    n == 1
  end

  defp marcar_lida(ctx, n) do
    membership =
      Api.Accounts.get_active_membership!(ctx.owner.id, ctx.clinic.id, authorize?: false)

    {:ok, lida} = Notifications.mark_read(Api.Scope.with_membership(ctx.owner, membership), n.id)
    lida
  end

  describe "perform/1" do
    test "apaga a lida velha e mantém a lida recente" do
      ctx = clinica()
      velha = ctx |> notifica() |> then(&marcar_lida(ctx, &1))
      recente = ctx |> notifica() |> then(&marcar_lida(ctx, &1))

      envelhecer(velha.id, 120)

      assert {:ok, %{apagadas: apagadas}} = perform_job(PruneNotifications, %{})
      assert apagadas >= 1

      refute existe?(velha.id)
      assert existe?(recente.id)
    end

    # O ponto da retenção assimétrica: 120 dias já passou da janela das lidas (90) e a não-lida
    # continua ali. Sem isto, "expurgo" apagaria aviso que o usuário nunca abriu.
    test "a não-lida resiste à janela curta e cai só na longa" do
      ctx = clinica()
      nao_lida = notifica(ctx)
      envelhecer(nao_lida.id, 120)

      assert {:ok, %{apagadas: 0}} = perform_job(PruneNotifications, %{})
      assert existe?(nao_lida.id)

      envelhecer(nao_lida.id, 300)
      assert {:ok, %{apagadas: n}} = perform_job(PruneNotifications, %{})
      assert n >= 1
      refute existe?(nao_lida.id)
    end

    test "as janelas são parâmetro do job" do
      ctx = clinica()
      lida = ctx |> notifica() |> then(&marcar_lida(ctx, &1))
      nao_lida = notifica(ctx)

      assert {:ok, %{apagadas: 0}} = perform_job(PruneNotifications, %{})

      assert {:ok, %{apagadas: 2}} =
               perform_job(PruneNotifications, %{"reter_lidas_dias" => 0, "reter_dias" => 0})

      refute existe?(lida.id)
      refute existe?(nao_lida.id)
    end

    test "poda clínica a clínica, cada uma sob a própria GUC" do
      a = clinica()
      b = clinica()
      da_a = a |> notifica() |> then(&marcar_lida(a, &1))
      da_b = b |> notifica() |> then(&marcar_lida(b, &1))

      envelhecer(da_a.id, 120)

      assert {:ok, _} = perform_job(PruneNotifications, %{})

      refute existe?(da_a.id)
      assert existe?(da_b.id)
    end
  end
end
