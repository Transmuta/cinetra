defmodule ApiWeb.WaitlistChannelTest do
  @moduledoc """
  O canal da fila (Entrega 5, D-E5.3). Protege, em ordem de gravidade:

    * **o `clinic_id` do tópico é validado no `join`** — o WebSocket não passa pela sessão nem
      pela RLS, então assinar a fila de outra clínica seria vazamento por fora de tudo;
    * o vínculo revogado depois do token emitido não entra (token vive 15 min);
    * uma mutação na fila empurra o sinal `waitlist_changed` (o cliente recarrega a lista).
  """
  use ApiWeb.ChannelCase, async: false

  alias Api.Accounts
  alias Api.Records
  alias Api.Waitlist

  defp email, do: "wchan-#{System.unique_integer([:positive])}@example.com"

  defp sign_in(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  defp member(owner, clinic, papel) do
    addr = email()

    {:ok, pending} =
      Accounts.invite_member_by_email(addr, %{papel: papel, clinic_id: clinic.id}, actor: owner)

    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, membership} = Accounts.accept_invite(pending, actor: user)
    {sign_in(addr), membership}
  end

  defp fixture do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    paciente = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)
    {:ok, membership} = Accounts.get_active_membership(owner.id, clinic.id, authorize?: false)

    %{
      owner: owner,
      clinic: clinic,
      paciente: paciente,
      scope: Api.Scope.with_membership(owner, membership)
    }
  end

  defp socket_for(user, clinic) do
    Phoenix.ChannelTest.socket(ApiWeb.UserSocket, "user_socket:#{user.id}", %{
      user_id: user.id,
      clinic_id: clinic.id
    })
  end

  defp topic(clinic), do: "waitlist:#{clinic.id}"

  describe "join" do
    test "membro entra no tópico da própria clínica" do
      ctx = fixture()

      assert {:ok, _reply, _socket} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))
    end

    test "tópico de OUTRA clínica é recusado" do
      ctx = fixture()
      intruso = fixture()

      assert {:error, %{reason: "unauthorized"}} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(intruso.clinic))
    end

    test "tópico malformado é recusado" do
      ctx = fixture()

      assert {:error, %{reason: "invalid_topic"}} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, "waitlist:")
    end

    test "vínculo revogado depois do token emitido não entra" do
      ctx = fixture()
      {user, membership} = member(ctx.owner, ctx.clinic, :recepcao)
      :ok = Accounts.revoke_access(membership, actor: ctx.owner)

      assert {:error, %{reason: "unauthorized"}} =
               user
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))
    end
  end

  describe "sinal" do
    test "enfileirar empurra waitlist_changed" do
      ctx = fixture()

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      {:ok, _entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})

      assert_push "waitlist_changed", payload
      assert payload.change == "entry_upserted"
      assert payload.actor.id == ctx.owner.id
    end
  end

  # F4: reservar/soltar uma vaga muda o que a fila mostra ("alguém está oferecendo"), mesmo sem
  # nenhum item da fila ter mudado. Sem este sinal, a outra recepção só descobriria ao tomar 409.
  describe "reserva de vaga (F4)" do
    test "oferecer uma vaga empurra o sinal para quem está na fila" do
      ctx = fixture()

      prof =
        Api.Directory.create_professional!("Dra. A", %{},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      {:ok, hold} =
        Waitlist.offer_slot(ctx.scope, entry, %{
          professional_id: prof.id,
          starts_at: ~U[2026-07-21 12:00:00Z]
        })

      assert_push "waitlist_changed", %{change: "slot_held"}

      # E soltar avisa também — senão o chip ficaria "reservado" até alguém recarregar.
      :ok = Api.Scheduling.release_slot_hold!(hold, scope: ctx.scope)
      assert_push "waitlist_changed", %{change: "slot_released"}
    end
  end
end
