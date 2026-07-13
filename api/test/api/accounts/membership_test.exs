defmodule Api.Accounts.MembershipTest do
  @moduledoc """
  Gestão de membros da clínica (Fatia 10): convite por e-mail (acha-ou-cria `User` →
  `Membership` pendente → magic link), leitura por clínica e RBAC (ADR-016).
  """
  use Api.DataCase, async: false
  require Ash.Query

  alias Api.Accounts

  defp email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp capture_token(addr) do
    :ok = Accounts.request_magic_link(addr)
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    token
  end

  # Um owner com clínica ativa (consome o e-mail do magic link do próprio owner).
  defp owner_and_clinic do
    {:ok, owner} = Accounts.sign_in_with_magic_link(capture_token(email()))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  # Convida alguém e ativa o vínculo (simula o aceite no primeiro acesso).
  defp active_member(clinic, owner, papel) do
    addr = email()

    {:ok, m} =
      Accounts.invite_member_by_email(addr, %{papel: papel, clinic_id: clinic.id}, actor: owner)

    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, m} = Accounts.accept_invite(m, actor: user)
    {user, m}
  end

  describe "invite_member_by_email/3" do
    test "cria Membership pendente e dispara magic link para o convidado" do
      {owner, clinic} = owner_and_clinic()
      invitee = email()

      {:ok, membership} =
        Accounts.invite_member_by_email(
          invitee,
          %{nome: "Fulano", papel: :recepcao, clinic_id: clinic.id},
          actor: owner
        )

      assert membership.status == :pendente
      assert membership.papel == :recepcao
      assert membership.clinic_id == clinic.id

      # o convite é um magic link para o e-mail do convidado (ADR-015, D24).
      assert_receive {:email, mail}, 1_000
      assert [{_, ^invitee}] = mail.to
    end

    test "cria o User do convidado quando ele ainda não existe" do
      {owner, clinic} = owner_and_clinic()
      invitee = email()

      {:ok, membership} =
        Accounts.invite_member_by_email(
          invitee,
          %{nome: "Novato", papel: :admin, clinic_id: clinic.id},
          actor: owner
        )

      user = Accounts.get_user_by_email!(invitee, authorize?: false)
      assert membership.user_id == user.id
      assert user.nome == "Novato"
    end

    test "reaproveita o User existente sem sobrescrever o nome" do
      {owner, clinic} = owner_and_clinic()
      existing = email()
      {:ok, user} = Accounts.register_user("Nome Original", existing, authorize?: false)

      {:ok, membership} =
        Accounts.invite_member_by_email(
          existing,
          %{nome: "Outro Nome", papel: :admin, clinic_id: clinic.id},
          actor: owner
        )

      assert membership.user_id == user.id
      reloaded = Accounts.get_user!(user.id, authorize?: false)
      assert reloaded.nome == "Nome Original"
    end

    test "NÃO vincula profissional de outra clínica" do
      {owner_a, clinic_a} = owner_and_clinic()
      {_owner_b, clinic_b} = owner_and_clinic()

      {:ok, prof_b} =
        Api.Directory.create_professional("Prof B", %{}, tenant: clinic_b.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.invite_member_by_email(
                 email(),
                 %{papel: :profissional, professional_id: prof_b.id, clinic_id: clinic_a.id},
                 actor: owner_a
               )
    end

    test "vincula profissional da própria clínica" do
      {owner, clinic} = owner_and_clinic()

      {:ok, prof} =
        Api.Directory.create_professional("Prof A", %{}, tenant: clinic.id, authorize?: false)

      assert {:ok, m} =
               Accounts.invite_member_by_email(
                 email(),
                 %{papel: :profissional, professional_id: prof.id, clinic_id: clinic.id},
                 actor: owner
               )

      assert m.professional_id == prof.id
    end

    test "só owner/admin podem convidar — recepção é barrada (Forbidden)" do
      {owner, clinic} = owner_and_clinic()
      {recep, _m} = active_member(clinic, owner, :recepcao)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.invite_member_by_email(
                 email(),
                 %{papel: :recepcao, clinic_id: clinic.id},
                 actor: recep
               )
    end

    test "convite NEGADO não cria o User do convidado (sem phantom user)" do
      {owner, clinic} = owner_and_clinic()
      {recep, _} = active_member(clinic, owner, :recepcao)
      ghost = email()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.invite_member_by_email(
                 ghost,
                 %{papel: :recepcao, clinic_id: clinic.id},
                 actor: recep
               )

      # a autorização roda ANTES de qualquer escrita: o User não pode ter sido criado.
      users =
        Accounts.User
        |> Ash.Query.filter(email == ^ghost)
        |> Ash.read!(authorize?: false)

      assert users == []
    end

    test "admin pode convidar" do
      {owner, clinic} = owner_and_clinic()
      {admin, _m} = active_member(clinic, owner, :admin)

      assert {:ok, membership} =
               Accounts.invite_member_by_email(
                 email(),
                 %{papel: :recepcao, clinic_id: clinic.id},
                 actor: admin
               )

      assert membership.status == :pendente
    end
  end

  describe "RBAC de owner (D23 — só owner gerencia owners)" do
    test "admin NÃO pode promover ninguém a owner" do
      {owner, clinic} = owner_and_clinic()
      {admin, _} = active_member(clinic, owner, :admin)
      {_recep_user, recep_m} = active_member(clinic, owner, :recepcao)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.update_membership(recep_m, %{papel: :owner}, actor: admin)
    end

    test "admin NÃO pode se autopromover a owner" do
      {owner, clinic} = owner_and_clinic()
      {admin, admin_m} = active_member(clinic, owner, :admin)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.update_membership(admin_m, %{papel: :owner}, actor: admin)
    end

    test "admin NÃO pode rebaixar um owner" do
      {owner, clinic} = owner_and_clinic()
      {admin, _} = active_member(clinic, owner, :admin)
      # um segundo owner (para o NotLastOwner não ser a razão do erro).
      {_o2_user, owner2_m} = active_member(clinic, owner, :owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.update_membership(owner2_m, %{papel: :recepcao}, actor: admin)
    end

    test "admin NÃO pode revogar um owner" do
      {owner, clinic} = owner_and_clinic()
      {admin, _} = active_member(clinic, owner, :admin)
      {_o2_user, owner2_m} = active_member(clinic, owner, :owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Accounts.revoke_access(owner2_m, actor: admin)
    end

    test "owner PODE promover a owner" do
      {owner, clinic} = owner_and_clinic()
      {_admin, admin_m} = active_member(clinic, owner, :admin)

      assert {:ok, updated} = Accounts.update_membership(admin_m, %{papel: :owner}, actor: owner)
      assert updated.papel == :owner
    end

    test "admin ainda gerencia papéis não-owner (recepção → profissional)" do
      {owner, clinic} = owner_and_clinic()
      {admin, _} = active_member(clinic, owner, :admin)
      {_recep_user, recep_m} = active_member(clinic, owner, :recepcao)

      assert {:ok, updated} =
               Accounts.update_membership(recep_m, %{papel: :profissional}, actor: admin)

      assert updated.papel == :profissional
    end
  end

  describe "Invites.activate_pending/1" do
    test "o primeiro acesso do convidado ativa o vínculo pendente" do
      {owner, clinic} = owner_and_clinic()
      invitee = email()

      {:ok, pending} =
        Accounts.invite_member_by_email(
          invitee,
          %{papel: :recepcao, clinic_id: clinic.id},
          actor: owner
        )

      assert pending.status == :pendente
      user = Accounts.get_user_by_email!(invitee, authorize?: false)

      assert [activated] = Api.Accounts.Invites.activate_pending(user)
      assert activated.status == :ativo

      # agora o escopo consegue resolver o tenant do convidado.
      assert [active] = Accounts.list_active_memberships!(user.id, authorize?: false)
      assert active.clinic_id == clinic.id
    end

    test "é no-op quando não há convite pendente" do
      {owner, _clinic} = owner_and_clinic()
      assert [] = Api.Accounts.Invites.activate_pending(owner)
    end
  end

  describe "list_clinic_members/2" do
    test "owner/admin veem todos os vínculos da clínica com o user carregado" do
      {owner, clinic} = owner_and_clinic()
      {_recep, _m} = active_member(clinic, owner, :recepcao)

      members = Accounts.list_clinic_members!(clinic.id, actor: owner)

      assert length(members) == 2
      assert Enum.all?(members, &(&1.clinic_id == clinic.id))
      # o user vem carregado (a lista precisa de nome/e-mail).
      assert Enum.all?(members, &match?(%Accounts.User{}, &1.user))
    end

    test "não vaza vínculos de outra clínica" do
      {owner_a, clinic_a} = owner_and_clinic()
      {_owner_b, clinic_b} = owner_and_clinic()

      members = Accounts.list_clinic_members!(clinic_a.id, actor: owner_a)

      assert Enum.all?(members, &(&1.clinic_id == clinic_a.id))
      refute Enum.any?(members, &(&1.clinic_id == clinic_b.id))
    end
  end
end
