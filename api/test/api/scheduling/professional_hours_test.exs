defmodule Api.Scheduling.ProfessionalHoursTest do
  @moduledoc """
  Grade semanal do profissional (fatia Profissionais, `01 §4.3` / doc 22 §5). Cobre o modelo
  `:herda/:custom/:fechado`, o invariante **prof ⊆ clínica** (custom só cabe dentro do
  expediente da clínica), a coerência `modo`↔`periods`, o upsert por dia e o RBAC.

  RLS (ADR-018) não é exercida aqui (sandbox BYPASSRLS); prova-se o filtro por atributo e as
  regras de domínio.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Scheduling

  defp email, do: "profh-#{System.unique_integer([:positive])}@example.com"

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

  defp professional(clinic, owner, nome \\ "Dra. X") do
    Directory.create_professional!(nome, %{}, tenant: clinic.id, actor: owner)
  end

  defp grade(scope, prof_id) do
    scope
    |> Scheduling.list_professional_hours(prof_id)
    |> Map.new(&{&1.dow, {&1.modo, &1.periods}})
  end

  describe "update_professional_hours/3 — modelo e invariante prof ⊆ clínica" do
    test "custom dentro do horário da clínica persiste modo :custom + períodos" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      prof = professional(clinic, owner)

      # Seg (dow 1) da clínica é 08–12/13–18; 09–11 cabe.
      {:ok, _rows} =
        Scheduling.update_professional_hours(scope, prof.id, [
          %{dow: 1, modo: :custom, periods: [["09:00", "11:00"]]}
        ])

      assert grade(scope, prof.id)[1] == {:custom, [["09:00", "11:00"]]}
    end

    test "custom FORA do horário da clínica é recusado sem escrever nada" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      prof = professional(clinic, owner)

      # 07:00 começa antes das 08:00 da clínica.
      assert {:error, {:invalid, [%{field: :periods}]}} =
               Scheduling.update_professional_hours(scope, prof.id, [
                 %{dow: 1, modo: :custom, periods: [["07:00", "09:00"]]}
               ])

      assert grade(scope, prof.id) == %{}
    end

    test "custom num dia em que a clínica está fechada é recusado" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      prof = professional(clinic, owner)

      # Domingo (dow 0) a clínica é fechada no seed.
      assert {:error, {:invalid, _}} =
               Scheduling.update_professional_hours(scope, prof.id, [
                 %{dow: 0, modo: :custom, periods: [["09:00", "10:00"]]}
               ])
    end

    test "herda e fechado não carregam períodos; herdar/fechar persiste o modo" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      prof = professional(clinic, owner)

      {:ok, _} =
        Scheduling.update_professional_hours(scope, prof.id, [
          %{dow: 2, modo: :herda, periods: []},
          %{dow: 3, modo: :fechado, periods: []}
        ])

      g = grade(scope, prof.id)
      assert g[2] == {:herda, []}
      assert g[3] == {:fechado, []}
    end

    test "herda/fechado COM períodos é incoerente e recusado" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      prof = professional(clinic, owner)

      assert {:error, {:invalid, _}} =
               Scheduling.update_professional_hours(scope, prof.id, [
                 %{dow: 2, modo: :herda, periods: [["09:00", "10:00"]]}
               ])
    end

    test "custom sem períodos é recusado" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      prof = professional(clinic, owner)

      assert {:error, {:invalid, _}} =
               Scheduling.update_professional_hours(scope, prof.id, [
                 %{dow: 1, modo: :custom, periods: []}
               ])
    end

    test "upsert: reescrever o mesmo dia atualiza, não duplica" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      prof = professional(clinic, owner)

      Scheduling.update_professional_hours(scope, prof.id, [
        %{dow: 1, modo: :custom, periods: [["09:00", "10:00"]]}
      ])

      Scheduling.update_professional_hours(scope, prof.id, [
        %{dow: 1, modo: :fechado, periods: []}
      ])

      rows = Scheduling.list_professional_hours(scope, prof.id)
      assert Enum.count(rows, &(&1.dow == 1)) == 1
      assert grade(scope, prof.id)[1] == {:fechado, []}
    end

    test "profissional de outra clínica é recusado (professional_not_in_clinic)" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()
      scope_a = scope_for(owner_a, clinic_a)
      prof_b = professional(clinic_b, owner_b)

      assert {:error, :professional_not_in_clinic} =
               Scheduling.update_professional_hours(scope_a, prof_b.id, [
                 %{dow: 1, modo: :herda, periods: []}
               ])
    end
  end

  describe "isolamento e leitura" do
    test "a grade de um profissional não vaza para outro" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      p1 = professional(clinic, owner, "P1")
      p2 = professional(clinic, owner, "P2")

      Scheduling.update_professional_hours(scope, p1.id, [
        %{dow: 1, modo: :custom, periods: [["09:00", "10:00"]]}
      ])

      assert map_size(grade(scope, p1.id)) == 1
      assert grade(scope, p2.id) == %{}
    end
  end

  describe "RBAC — ação set_day" do
    test "recepção e profissional NÃO escrevem a grade (Forbidden)" do
      {owner, clinic} = owner_and_clinic()
      prof = professional(clinic, owner)

      for papel <- [:recepcao, :profissional] do
        user = member_with_role(clinic, papel)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Scheduling.set_professional_hours_day(
                   %{professional_id: prof.id, dow: 1, modo: :herda, periods: []},
                   scope: scope_for(user, clinic)
                 ),
               "#{papel} não deveria escrever a grade"
      end
    end

    test "todos os membros leem a grade" do
      {owner, clinic} = owner_and_clinic()
      prof = professional(clinic, owner)

      Scheduling.update_professional_hours(scope_for(owner, clinic), prof.id, [
        %{dow: 1, modo: :custom, periods: [["09:00", "10:00"]]}
      ])

      for papel <- [:admin, :recepcao, :profissional] do
        user = member_with_role(clinic, papel)
        assert map_size(grade(scope_for(user, clinic), prof.id)) == 1, "#{papel} deveria ler"
      end
    end
  end
end
