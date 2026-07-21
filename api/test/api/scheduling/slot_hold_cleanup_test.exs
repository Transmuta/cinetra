defmodule Api.Scheduling.SlotHold.CleanupWorkerTest do
  @moduledoc """
  O backstop de limpeza dos holds vencidos (doc 09 §6.2, passo 3). Exercita `purge_expired/0`
  direto — o cron é config, não lógica. A RLS não é exercida no sandbox (`postgres`, BYPASSRLS);
  a iteração por-clínica com GUC é verificada por `psql`/bate-volta.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling
  alias Api.Scheduling.SlotHold.CleanupWorker
  alias Api.Waitlist

  @segunda ~D[2026-07-20]

  defp email, do: "cln-#{System.unique_integer([:positive])}@example.com"

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  test "apaga os holds vencidos e preserva os vivos" do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)
    clinic = Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)
    membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)

    prof1 = Directory.create_professional!("Dra. A", %{}, tenant: clinic.id, actor: owner)
    prof2 = Directory.create_professional!("Dr. B", %{}, tenant: clinic.id, actor: owner)
    p = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)

    scope_vivo = Api.Scope.with_membership(owner, membership)
    {:ok, entry} = Waitlist.enqueue_entry(scope_vivo, %{patient_id: p.id})

    # Hold VENCIDO: relógio cravado no passado → expires_at no passado.
    scope_velho = Api.Scope.with_membership(owner, membership, now: ~U[2020-01-01 00:00:00Z])
    {:ok, vencido} = Waitlist.offer_slot(scope_velho, entry, %{professional_id: prof1.id, starts_at: at("09:00")})

    # Hold VIVO: relógio real → expires_at = agora + 10 min.
    {:ok, vivo} = Waitlist.offer_slot(scope_vivo, entry, %{professional_id: prof2.id, starts_at: at("11:00")})

    assert CleanupWorker.purge_expired() == 1

    ids = Scheduling.list_slot_holds!(scope: scope_vivo) |> Enum.map(& &1.id)
    refute vencido.id in ids
    assert vivo.id in ids
  end
end
