defmodule Api.Scheduling.SlotHoldTest do
  @moduledoc """
  A reserva de vaga (doc 09 §6.2). Aqui: a derivação de `ends_at`/`expires_at`, a exclusion
  constraint `slot_holds_no_overlap` bloqueando sobreposição do mesmo profissional, e o release.

  A **corrida real** (duas conexões concorrentes → `409 slot_held`) e o mapeamento HTTP são do
  wrapper `Api.Waitlist.offer_slot/3` (testados à parte). A RLS não é exercida no sandbox
  (`postgres`, BYPASSRLS) — a prova é por `psql`.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling
  alias Api.Waitlist

  @segunda ~D[2026-07-20]

  defp email, do: "hold-#{System.unique_integer([:positive])}@example.com"

  defp setup_clinic(opts \\ []) do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)
    scope = Api.Scope.with_membership(owner, membership, opts)

    prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)
    p = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)
    {:ok, entry} = Waitlist.enqueue_entry(scope, %{patient_id: p.id})

    %{owner: owner, clinic: clinic, scope: scope, prof: prof, entry: entry}
  end

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp offer(ctx, hhmm, opts \\ []) do
    Scheduling.create_slot_hold(
      %{
        starts_at: at(hhmm),
        professional_id: ctx.prof.id,
        waitlist_entry_id: ctx.entry.id,
        duration_minutos: Keyword.get(opts, :duration, 50)
      },
      scope: ctx.scope
    )
  end

  describe "offer — janela derivada" do
    test "ends_at = starts_at + duração; expires_at = agora + 10 min (TTL)" do
      now = ~U[2026-07-20 14:00:00Z]
      ctx = setup_clinic(now: now)

      {:ok, hold} = offer(ctx, "09:00", duration: 50)

      assert DateTime.diff(hold.ends_at, hold.starts_at, :minute) == 50
      assert DateTime.compare(hold.expires_at, DateTime.add(now, 600, :second)) == :eq
      assert hold.held_by_id == ctx.owner.id
    end
  end

  describe "slot_holds_no_overlap" do
    test "segurar horário sobreposto do mesmo profissional é recusado" do
      ctx = setup_clinic()

      {:ok, _} = offer(ctx, "09:00", duration: 50)
      # 09:30–10:20 sobrepõe 09:00–09:50.
      assert {:error, %Ash.Error.Invalid{}} = offer(ctx, "09:30", duration: 50)
    end

    test "encostar fim-com-início não é sobreposição ('[)')" do
      ctx = setup_clinic()

      {:ok, _} = offer(ctx, "09:00", duration: 50)
      # 09:50–10:40 encosta em 09:50; convivem.
      assert {:ok, _} = offer(ctx, "09:50", duration: 50)
    end
  end

  describe "release" do
    test "libera a vaga" do
      ctx = setup_clinic()
      {:ok, hold} = offer(ctx, "09:00")

      assert :ok = Scheduling.release_slot_hold(hold, scope: ctx.scope)
      assert [] = Scheduling.list_slot_holds!(scope: ctx.scope)
    end
  end
end
