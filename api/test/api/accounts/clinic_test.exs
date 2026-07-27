defmodule Api.Accounts.ClinicTest do
  @moduledoc """
  Ação `update_info` da clínica (tela /configuracoes/clinica): nome, CNPJ (alfanumérico,
  normalizado) e endereço. RBAC ADR-016: só owner/admin edita.
  """
  use Api.DataCase, async: false

  alias Api.Accounts

  defp capture_token(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    token
  end

  defp owner_and_clinic do
    {:ok, owner} = Accounts.sign_in_with_magic_link(capture_token(email_unico("clinic")))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp active_member(clinic, owner, papel) do
    addr = email_unico("clinic")

    {:ok, m} =
      Accounts.invite_member_by_email(addr, %{papel: papel, clinic_id: clinic.id}, actor: owner)

    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, _} = Accounts.accept_invite(m, actor: user)
    user
  end

  describe "update_info/3" do
    test "grava nome, CNPJ normalizado e endereço" do
      {owner, clinic} = owner_and_clinic()

      {:ok, updated} =
        Accounts.update_clinic_info(
          clinic,
          %{nome: "Clínica Vida", cnpj: "12.ABC.345/01DE-35", endereco: "  Rua X, 100 · SP  "},
          actor: owner
        )

      assert updated.nome == "Clínica Vida"
      # máscara descartada, guardado na forma canônica de 14 posições.
      assert updated.cnpj == "12ABC34501DE35"
      # endereço em texto único, com trim.
      assert updated.endereco == "Rua X, 100 · SP"
    end

    test "aceita CNPJ numérico clássico (retrocompatível)" do
      {owner, clinic} = owner_and_clinic()

      {:ok, updated} =
        Accounts.update_clinic_info(clinic, %{cnpj: "11.222.333/0001-81"}, actor: owner)

      assert updated.cnpj == "11222333000181"
    end

    test "rejeita CNPJ inválido apontando o campo" do
      {owner, clinic} = owner_and_clinic()

      {:error, %Ash.Error.Invalid{} = error} =
        Accounts.update_clinic_info(clinic, %{cnpj: "12ABC34501DE34"}, actor: owner)

      assert Enum.any?(error.errors, &(Map.get(&1, :field) == :cnpj))
    end

    test "CNPJ/endereço em branco limpam o campo" do
      {owner, clinic} = owner_and_clinic()

      {:ok, com} =
        Accounts.update_clinic_info(clinic, %{cnpj: "12ABC34501DE35", endereco: "Rua X"},
          actor: owner
        )

      {:ok, sem} = Accounts.update_clinic_info(com, %{cnpj: "", endereco: "   "}, actor: owner)
      assert sem.cnpj == nil
      assert sem.endereco == nil
    end

    test "recepção não pode editar (Forbidden)" do
      {owner, clinic} = owner_and_clinic()
      recep = active_member(clinic, owner, :recepcao)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.update_clinic_info(clinic, %{nome: "Hack"}, actor: recep)
    end

    test "admin pode editar" do
      {owner, clinic} = owner_and_clinic()
      admin = active_member(clinic, owner, :admin)

      {:ok, updated} = Accounts.update_clinic_info(clinic, %{nome: "Nova"}, actor: admin)
      assert updated.nome == "Nova"
    end
  end
end
