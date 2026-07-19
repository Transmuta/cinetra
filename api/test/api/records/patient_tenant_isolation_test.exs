defmodule Api.Records.PatientTenantIsolationTest do
  @moduledoc """
  Isolamento por-tenant do `Patient` (ADR-017). Prova a camada **primária**: o
  `strategy :attribute` injeta `WHERE clinic_id = tenant` em toda query, então uma clínica
  nunca enxerga o paciente de outra — o gêmeo do `ProfessionalTenantIsolationTest`.

  A RLS (ADR-018, defesa-em-profundidade) **não** é exercida aqui: o sandbox conecta como
  `postgres` (BYPASSRLS). Ela é provada por psql como `movimento_app` no bate-volta.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Records

  defp owner_of_clinic(nome) do
    email = "pac-iso-#{System.unique_integer([:positive])}@example.com"
    user = Accounts.register_user!("Dono #{nome}", email, authorize?: false)
    clinic = Accounts.onboard_clinic!(nome, %{}, actor: user)
    {user, clinic}
  end

  test "cada clínica só vê o próprio paciente (isolamento por atributo)" do
    {user_a, clinic_a} = owner_of_clinic("Clínica A")
    {user_b, clinic_b} = owner_of_clinic("Clínica B")

    pac_a = Records.create_patient!("Ana A", %{}, tenant: clinic_a.id, actor: user_a)
    pac_b = Records.create_patient!("Bruno B", %{}, tenant: clinic_b.id, actor: user_b)

    lista_a = Records.list_patients!(tenant: clinic_a.id, actor: user_a)
    lista_b = Records.list_patients!(tenant: clinic_b.id, actor: user_b)

    assert Enum.map(lista_a, & &1.id) == [pac_a.id]
    assert Enum.map(lista_b, & &1.id) == [pac_b.id]
    refute pac_a.id in Enum.map(lista_b, & &1.id)
  end

  test "buscar por id um paciente de outra clínica não o encontra" do
    {user_a, clinic_a} = owner_of_clinic("Clínica A")
    {_user_b, clinic_b} = owner_of_clinic("Clínica B")

    pac_a = Records.create_patient!("Ana A", %{}, tenant: clinic_a.id, actor: user_a)

    assert {:ok, nil} =
             Records.get_patient(pac_a.id, tenant: clinic_b.id, authorize?: false, not_found_error?: false)
  end
end
