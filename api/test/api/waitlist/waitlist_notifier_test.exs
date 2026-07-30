defmodule Api.Waitlist.WaitlistNotifierTest do
  @moduledoc """
  O publicador da fila (D-E5.3) — o contrato interno que o `ApiWeb.WaitlistChannel` consome:
  enqueue/update viram `entry_upserted`, dequeue vira `entry_removed`, no tópico da clínica.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Records
  alias Api.Waitlist
  alias Api.Waitlist.WaitlistNotifier

  defp fixture do
    owner = Accounts.register_user!("Dono", email_unico("wnotif"), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)

    p =
      Records.create_patient!("Paciente", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    %{clinic: clinic, patient: p, scope: Api.Scope.with_membership(owner, membership)}
  end

  test "enqueue publica entry_upserted; dequeue publica entry_removed" do
    ctx = fixture()
    :ok = WaitlistNotifier.subscribe(WaitlistNotifier.internal_topic(ctx.clinic.id))

    {:ok, entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.patient.id})
    assert_receive {:waitlist_event, %{change: "entry_upserted"}}

    {:ok, _} = Waitlist.update_entry(ctx.scope, entry.id, %{prio: :alta})
    assert_receive {:waitlist_event, %{change: "entry_upserted"}}

    :ok = Waitlist.dequeue_entry(ctx.scope, entry.id)
    assert_receive {:waitlist_event, %{change: "entry_removed"}}
  end

  test "não vaza para o tópico de outra clínica" do
    a = fixture()
    b = fixture()
    :ok = WaitlistNotifier.subscribe(WaitlistNotifier.internal_topic(b.clinic.id))

    {:ok, _} = Waitlist.enqueue_entry(a.scope, %{patient_id: a.patient.id})
    refute_receive {:waitlist_event, _}, 200
  end
end
