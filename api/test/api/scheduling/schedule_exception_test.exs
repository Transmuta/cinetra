defmodule Api.Scheduling.ScheduleExceptionTest do
  @moduledoc """
  Exceções de data da clínica (doc 22). Cobre criar/listar/apagar, unicidade por data (H3),
  coerência períodos×tipo, isolamento por-tenant e RBAC (H7). A RLS não é exercida (sandbox
  BYPASSRLS), como em `AppointmentTypeTest`.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Scheduling

  defp email, do: "exc-#{System.unique_integer([:positive])}@example.com"

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp member_with_role(clinic, papel) do
    user = Accounts.register_user!("Membro #{papel}", email(), authorize?: false)

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

  defp fechado(overrides \\ %{}) do
    Map.merge(%{data: ~D[2026-07-09], nome: "Feriado", tipo: :fechado}, overrides)
  end

  describe "criar" do
    test "dia fechado" do
      {owner, clinic} = owner_and_clinic()

      {:ok, exc} = Scheduling.create_clinic_exception(scope_for(owner, clinic), fechado())

      assert exc.tipo == :fechado
      assert exc.periods == []
      assert is_nil(exc.professional_id)
      assert exc.clinic_id == clinic.id
    end

    test "horário especial com períodos" do
      {owner, clinic} = owner_and_clinic()

      {:ok, exc} =
        Scheduling.create_clinic_exception(scope_for(owner, clinic), %{
          data: ~D[2026-07-24],
          nome: "Expediente reduzido",
          tipo: :horario,
          periods: [["08:00", "12:00"]]
        })

      assert exc.tipo == :horario
      assert exc.periods == [["08:00", "12:00"]]
    end
  end

  describe "coerência períodos × tipo" do
    test "horário sem períodos é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.create_clinic_exception(scope_for(owner, clinic), %{
                 data: ~D[2026-07-24],
                 tipo: :horario,
                 periods: []
               })
    end

    test "fechado com períodos é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.create_clinic_exception(
                 scope_for(owner, clinic),
                 fechado(%{periods: [["08:00", "12:00"]]})
               )
    end

    test "períodos malformados são recusados" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.create_clinic_exception(scope_for(owner, clinic), %{
                 data: ~D[2026-07-24],
                 tipo: :horario,
                 periods: [["18:00", "08:00"]]
               })
    end
  end

  describe "unicidade por data (H3)" do
    test "duas exceções da clínica na mesma data são recusadas" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, _} = Scheduling.create_clinic_exception(scope, fechado(%{data: ~D[2026-12-25]}))

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.create_clinic_exception(
                 scope,
                 fechado(%{data: ~D[2026-12-25], nome: "Outra"})
               )
    end

    test "a mesma data pode existir em clínicas diferentes" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      {:ok, _} = Scheduling.create_clinic_exception(scope_for(owner_a, clinic_a), fechado())

      assert {:ok, _} =
               Scheduling.create_clinic_exception(scope_for(owner_b, clinic_b), fechado())
    end
  end

  describe "listar" do
    test "só as da clínica, ordenadas por data" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      Scheduling.create_clinic_exception(scope, fechado(%{data: ~D[2026-07-24]}))
      Scheduling.create_clinic_exception(scope, fechado(%{data: ~D[2026-07-09]}))

      datas = scope |> Scheduling.list_clinic_exceptions() |> Enum.map(& &1.data)
      assert datas == [~D[2026-07-09], ~D[2026-07-24]]
    end

    test "não vaza exceção de outra clínica" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      Scheduling.create_clinic_exception(scope_for(owner_b, clinic_b), fechado(%{nome: "Da B"}))

      nomes =
        scope_for(owner_a, clinic_a) |> Scheduling.list_clinic_exceptions() |> Enum.map(& &1.nome)

      refute "Da B" in nomes
    end
  end

  describe "apagar (H4)" do
    test "destroy remove a linha" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, exc} = Scheduling.create_clinic_exception(scope, fechado())
      assert :ok = Scheduling.destroy_clinic_exception(scope, exc)
      assert [] = Scheduling.list_clinic_exceptions(scope)
    end

    test "existe destroy no recurso (ao contrário de AppointmentType)" do
      assert Enum.any?(
               Ash.Resource.Info.actions(Api.Scheduling.ScheduleException),
               &(&1.type == :destroy)
             )
    end
  end

  describe "RBAC (H7)" do
    test "recepção e profissional não criam nem apagam (Forbidden)" do
      {owner, clinic} = owner_and_clinic()
      {:ok, exc} = Scheduling.create_clinic_exception(scope_for(owner, clinic), fechado())

      for papel <- [:recepcao, :profissional] do
        scope = scope_for(member_with_role(clinic, papel), clinic)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Scheduling.create_clinic_exception(scope, fechado(%{data: ~D[2026-01-01]}))

        assert {:error, %Ash.Error.Forbidden{}} = Scheduling.destroy_clinic_exception(scope, exc)
      end
    end

    test "todos os membros leem" do
      {owner, clinic} = owner_and_clinic()
      Scheduling.create_clinic_exception(scope_for(owner, clinic), fechado(%{nome: "Visível"}))

      for papel <- [:admin, :recepcao, :profissional] do
        scope = scope_for(member_with_role(clinic, papel), clinic)
        nomes = scope |> Scheduling.list_clinic_exceptions() |> Enum.map(& &1.nome)
        assert "Visível" in nomes, "#{papel} deveria ler"
      end
    end
  end
end
