defmodule Api.Scheduling.ClinicHoursTest do
  @moduledoc """
  Expediente semanal da clínica (doc 22). Cobre o seed no `onboard` (Seg–Sex 08–12/13–18, Sáb
  manhã, Dom fechado), isolamento por-tenant, RBAC (H7), a substituição da semana por
  `update_clinic_hours/2` e a validação de períodos.

  Como em `AppointmentTypeTest`, a RLS (ADR-018) **não** é exercida aqui: o sandbox conecta
  como `postgres` (BYPASSRLS). Aqui se prova o filtro por atributo do Ash e as regras.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Scheduling

  defp email, do: "hours-#{System.unique_integer([:positive])}@example.com"

  defp owner_and_clinic(attrs \\ %{}) do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", attrs,
        actor: owner
      )

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

  defp week(scope) do
    scope |> Scheduling.list_clinic_hours() |> Map.new(&{&1.dow, &1.periods})
  end

  describe "seed no onboard" do
    test "clínica nova nasce com o expediente do protótipo" do
      {owner, clinic} = owner_and_clinic()
      w = week(scope_for(owner, clinic))

      assert map_size(w) == 7
      assert w[1] == [["08:00", "12:00"], ["13:00", "18:00"]]
      assert w[5] == [["08:00", "12:00"], ["13:00", "18:00"]]
      assert w[6] == [["08:00", "12:00"]]
      assert w[0] == []
    end

    test "todas as 7 linhas são da clínica" do
      {owner, clinic} = owner_and_clinic()
      rows = Scheduling.list_clinic_hours(scope_for(owner, clinic))
      assert Enum.all?(rows, &(&1.clinic_id == clinic.id))
      assert Enum.map(rows, & &1.dow) == [0, 1, 2, 3, 4, 5, 6]
    end
  end

  describe "isolamento por-tenant" do
    test "cada clínica só vê o próprio expediente" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      Scheduling.update_clinic_hours(scope_for(owner_a, clinic_a), %{3 => [["10:00", "11:00"]]})

      assert week(scope_for(owner_a, clinic_a))[3] == [["10:00", "11:00"]]
      # a B continua com o seed padrão do dia 3.
      assert week(scope_for(owner_b, clinic_b))[3] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end

    test "quem não é membro não lê nada" do
      {_owner, clinic} = owner_and_clinic()
      estranho = Accounts.register_user!("Estranho", email(), authorize?: false)

      assert [] = Scheduling.list_clinic_hours_rows!(tenant: clinic.id, actor: estranho)
    end
  end

  describe "RBAC (H7) — ação set_day" do
    test "owner e admin escrevem" do
      {owner, clinic} = owner_and_clinic()
      admin = member_with_role(clinic, :admin)

      assert %{} =
               Scheduling.set_clinic_hours_day!(%{dow: 2, periods: [["09:00", "10:00"]]},
                 scope: scope_for(owner, clinic)
               )

      assert %{} =
               Scheduling.set_clinic_hours_day!(%{dow: 2, periods: [["09:00", "11:00"]]},
                 scope: scope_for(admin, clinic)
               )
    end

    test "recepção e profissional NÃO escrevem (Forbidden)" do
      {_owner, clinic} = owner_and_clinic()

      for papel <- [:recepcao, :profissional] do
        user = member_with_role(clinic, papel)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Scheduling.set_clinic_hours_day(%{dow: 2, periods: [["09:00", "10:00"]]},
                   scope: scope_for(user, clinic)
                 ),
               "#{papel} não deveria escrever"
      end
    end

    test "todos os membros leem" do
      {_owner, clinic} = owner_and_clinic()

      for papel <- [:admin, :recepcao, :profissional] do
        user = member_with_role(clinic, papel)
        assert map_size(week(scope_for(user, clinic))) == 7, "#{papel} deveria ler"
      end
    end
  end

  describe "update_clinic_hours/2" do
    test "substitui só os dias enviados e devolve a semana relida" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, rows} =
        Scheduling.update_clinic_hours(scope, %{
          1 => [["09:00", "17:00"]],
          0 => [["10:00", "12:00"]]
        })

      w = Map.new(rows, &{&1.dow, &1.periods})
      assert w[1] == [["09:00", "17:00"]]
      # domingo, que era fechado, agora abre.
      assert w[0] == [["10:00", "12:00"]]
      # os não enviados ficam no seed.
      assert w[6] == [["08:00", "12:00"]]
    end

    test "fechar um dia (lista vazia)" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      {:ok, _} = Scheduling.update_clinic_hours(scope, %{6 => []})
      assert week(scope)[6] == []
    end

    test "períodos inválidos são recusados sem escrever nada" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      assert {:error, {:invalid, [%{field: :periods}]}} =
               Scheduling.update_clinic_hours(scope, %{
                 1 => [["09:00", "10:00"]],
                 2 => [["18:00", "08:00"]]
               })

      # o dia 1 (válido) NÃO foi aplicado — a semana é validada antes de qualquer escrita.
      assert week(scope)[1] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end
  end

  test "um registro por dia-da-semana: reescrever o mesmo dow atualiza, não duplica" do
    {owner, clinic} = owner_and_clinic()
    scope = scope_for(owner, clinic)

    Scheduling.update_clinic_hours(scope, %{3 => [["08:00", "09:00"]]})
    Scheduling.update_clinic_hours(scope, %{3 => [["10:00", "11:00"]]})

    rows = Scheduling.list_clinic_hours(scope)
    assert Enum.count(rows, &(&1.dow == 3)) == 1
    assert week(scope)[3] == [["10:00", "11:00"]]
  end
end
