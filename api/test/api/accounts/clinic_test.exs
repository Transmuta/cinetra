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

    test "grava o telefone e o endereço estruturado" do
      {owner, clinic} = owner_and_clinic()

      {:ok, atualizada} =
        Accounts.update_clinic_info(
          clinic,
          %{
            telefone: "(11) 3456-7890",
            cep: "01310-100",
            endereco: "Av. Paulista",
            numero: "1000",
            complemento: "sala 5",
            bairro: "Bela Vista",
            cidade: "São Paulo",
            uf: "SP"
          },
          actor: owner
        )

      assert atualizada.telefone == "(11) 3456-7890"
      assert atualizada.cep == "01310-100"
      assert atualizada.endereco == "Av. Paulista"
      assert atualizada.numero == "1000"
      assert atualizada.complemento == "sala 5"
      assert atualizada.bairro == "Bela Vista"
      assert atualizada.cidade == "São Paulo"
      assert atualizada.uf == "SP"
    end
  end

  describe "o WhatsApp só liga com telefone (doc 52 §9.1.4)" do
    test "sem telefone, ligar o WhatsApp é recusado" do
      # A regra não é de tela: o template HSM leva o telefone como posicional obrigatório, e sem
      # ele toda mensagem daquela clínica sairia dizendo "Ligue para —".
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{} = erro} =
               Accounts.update_clinic_messaging(clinic, %{msg_whatsapp_ativo: true}, actor: owner)

      assert Enum.any?(erro.errors, &(Map.get(&1, :field) == :telefone))
    end

    test "com telefone, liga" do
      {owner, clinic} = owner_and_clinic()

      {:ok, com_telefone} =
        Accounts.update_clinic_info(clinic, %{telefone: "(11) 3456-7890"}, actor: owner)

      {:ok, ligada} =
        Accounts.update_clinic_messaging(com_telefone, %{msg_whatsapp_ativo: true}, actor: owner)

      assert ligada.msg_whatsapp_ativo
    end

    test "nasce desligado" do
      # Mensagem de WhatsApp é paga. Uma clínica que nunca pediu o canal não pode passar a
      # gastar por causa de um deploy — foi exatamente o custo que o doc 98 declarou ao ligar o
      # lembrete para todo mundo, e aqui a decisão é a contrária.
      {_owner, clinic} = owner_and_clinic()

      refute clinic.msg_whatsapp_ativo
    end

    test "apagar o telefone com o WhatsApp ligado é recusado" do
      # O outro lado da mesma regra. Sem isto, o gate seria contornável pela tela vizinha: liga o
      # WhatsApp com telefone, apaga o telefone depois, e as mensagens voltam a sair com "—".
      {owner, clinic} = owner_and_clinic()

      {:ok, com} =
        Accounts.update_clinic_info(clinic, %{telefone: "(11) 3456-7890"}, actor: owner)

      {:ok, ligada} =
        Accounts.update_clinic_messaging(com, %{msg_whatsapp_ativo: true}, actor: owner)

      assert {:error, %Ash.Error.Invalid{} = erro} =
               Accounts.update_clinic_info(ligada, %{telefone: ""}, actor: owner)

      assert Enum.any?(erro.errors, &(Map.get(&1, :field) == :telefone))
    end

    test "desligar o WhatsApp não exige telefone" do
      {owner, clinic} = owner_and_clinic()

      {:ok, desligada} =
        Accounts.update_clinic_messaging(clinic, %{msg_whatsapp_ativo: false}, actor: owner)

      refute desligada.msg_whatsapp_ativo
    end
  end
end
