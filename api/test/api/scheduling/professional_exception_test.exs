defmodule Api.Scheduling.ProfessionalExceptionTest do
  @moduledoc """
  Exceções de data **do profissional** (folga/horário pontual) reusando o `ScheduleException`
  polimórfico (fatia Profissionais, doc 22 §5). Cobre a amarração do `professional_id` à
  clínica, o isolamento entre exceção da clínica e do profissional, a unicidade por data/dono
  e o destroy.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Scheduling

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email_unico("profe"), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp professional(clinic, owner, nome \\ "Dra. X") do
    Directory.create_professional!(nome, %{}, tenant: clinic.id, actor: owner)
  end

  test "cria folga (fechado) e horário pontual do profissional" do
    {owner, clinic} = owner_and_clinic()
    scope = scope_for(owner, clinic)
    prof = professional(clinic, owner)

    {:ok, folga} =
      Scheduling.create_professional_exception(scope, prof.id, %{
        data: ~D[2026-08-10],
        nome: "Férias",
        tipo: :fechado
      })

    {:ok, pontual} =
      Scheduling.create_professional_exception(scope, prof.id, %{
        data: ~D[2026-08-11],
        nome: "Congresso — meio período",
        tipo: :horario,
        periods: [["08:00", "12:00"]]
      })

    assert folga.professional_id == prof.id
    assert folga.tipo == :fechado
    assert pontual.periods == [["08:00", "12:00"]]
  end

  test "horário pontual sem período é recusado; fechado com período é recusado" do
    {owner, clinic} = owner_and_clinic()
    scope = scope_for(owner, clinic)
    prof = professional(clinic, owner)

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.create_professional_exception(scope, prof.id, %{
               data: ~D[2026-08-12],
               tipo: :horario,
               periods: []
             })

    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.create_professional_exception(scope, prof.id, %{
               data: ~D[2026-08-13],
               tipo: :fechado,
               periods: [["08:00", "12:00"]]
             })
  end

  test "profissional de outra clínica é recusado" do
    {owner_a, clinic_a} = owner_and_clinic()
    {owner_b, clinic_b} = owner_and_clinic()
    scope_a = scope_for(owner_a, clinic_a)
    prof_b = professional(clinic_b, owner_b)

    assert {:error, :professional_not_in_clinic} =
             Scheduling.create_professional_exception(scope_a, prof_b.id, %{
               data: ~D[2026-08-10],
               tipo: :fechado
             })
  end

  test "exceção do profissional e da clínica não se misturam nas listas" do
    {owner, clinic} = owner_and_clinic()
    scope = scope_for(owner, clinic)
    prof = professional(clinic, owner)

    {:ok, _clinica} =
      Scheduling.create_clinic_exception(scope, %{
        data: ~D[2026-12-25],
        nome: "Natal",
        tipo: :fechado
      })

    {:ok, _prof} =
      Scheduling.create_professional_exception(scope, prof.id, %{
        data: ~D[2026-08-10],
        tipo: :fechado
      })

    prof_exc = Scheduling.list_professional_exceptions(scope, prof.id)
    clinic_exc = Scheduling.list_clinic_exceptions(scope)

    assert Enum.map(prof_exc, & &1.data) == [~D[2026-08-10]]
    assert Enum.map(clinic_exc, & &1.data) == [~D[2026-12-25]]
  end

  test "mesma data pode ter exceção da clínica E de um profissional; mas não duas do mesmo prof" do
    {owner, clinic} = owner_and_clinic()
    scope = scope_for(owner, clinic)
    prof = professional(clinic, owner)
    data = ~D[2026-09-07]

    {:ok, _} =
      Scheduling.create_clinic_exception(scope, %{data: data, nome: "Feriado", tipo: :fechado})

    {:ok, _} =
      Scheduling.create_professional_exception(scope, prof.id, %{data: data, tipo: :fechado})

    # segunda do mesmo profissional na mesma data colide
    assert {:error, %Ash.Error.Invalid{}} =
             Scheduling.create_professional_exception(scope, prof.id, %{
               data: data,
               tipo: :fechado
             })
  end

  test "destroy apaga a exceção do profissional" do
    {owner, clinic} = owner_and_clinic()
    scope = scope_for(owner, clinic)
    prof = professional(clinic, owner)

    {:ok, exc} =
      Scheduling.create_professional_exception(scope, prof.id, %{
        data: ~D[2026-08-10],
        tipo: :fechado
      })

    :ok = Scheduling.destroy_professional_exception(scope, exc)

    assert Scheduling.list_professional_exceptions(scope, prof.id) == []
  end
end
