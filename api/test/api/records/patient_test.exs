defmodule Api.Records.PatientTest do
  @moduledoc """
  Ficha cadastral do paciente (fatia Pacientes, 2026-07-17). Cobre o que a fatia fixa: os
  campos das 8 seções em texto puro (sem cifra), `tags`/`prefs` como arrays, o enum comercial,
  só-o-nome-obrigatório, RBAC (owner/admin escrevem, todo membro lê), e arquivar/reativar em
  vez de apagar. Isolamento por-tenant tem teste próprio (`PatientTenantIsolationTest`).

  Como nos demais, a RLS (ADR-018) não é exercida aqui: o sandbox conecta como `postgres`
  (BYPASSRLS). Prova-se o filtro por atributo do Ash e as regras de domínio.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Records

  defp email, do: "pac-#{System.unique_integer([:positive])}@example.com"

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

    {:ok, _ativo} = Accounts.accept_invite(m, authorize?: false)
    user
  end

  @pref_a "11111111-1111-4111-8111-111111111111"
  @pref_b "22222222-2222-4222-8222-222222222222"

  @full %{
    nome_social: "Mari",
    cpf: "123.456.789-00",
    rg: "12.345.678-9",
    genero: "Feminino",
    estado_civil: "Solteiro(a)",
    nascimento: ~D[1990-05-20],
    responsavel: "Maria Aparecida (mãe)",
    tel: "(11) 98123-4451",
    email: "mari@example.com",
    cep: "01310-100",
    endereco: "Av. Paulista",
    numero: "1000",
    complemento: "Apto 5",
    bairro: "Bela Vista",
    cidade: "São Paulo",
    uf: "SP",
    emergencia_nome: "João",
    emergencia_parentesco: "Irmão",
    emergencia_tel: "(11) 90000-0000",
    profissao: "Designer",
    empresa: "Acme",
    atend_tipo: :convenio,
    convenio: "Unimed",
    carteirinha: "1234567890",
    convenio_validade: "12/2028",
    medico: "Dr. Silva",
    crm: "CRM/SP 123456",
    como_conheceu: "Instagram",
    prefs: [@pref_a, @pref_b],
    tags: ["pós-op joelho", "tendinite"],
    lgpd: true,
    comunicacao: true,
    cor_indice: 3
  }

  describe "criação da ficha completa" do
    test "persiste os campos das 8 seções, em texto puro (sem cifra)" do
      {owner, clinic} = owner_and_clinic()

      p = Records.create_patient!("Mariana Alves", @full, tenant: clinic.id, actor: owner)

      assert p.nome == "Mariana Alves"
      assert p.cpf == "123.456.789-00"
      assert p.rg == "12.345.678-9"
      assert p.medico == "Dr. Silva"
      assert p.crm == "CRM/SP 123456"
      assert p.atend_tipo == :convenio
      assert p.convenio == "Unimed"
      assert p.responsavel == "Maria Aparecida (mãe)"
      assert p.cor_indice == 3
    end

    test "tags e prefs ficam como arrays (decisão da fatia — texto puro, não recurso cifrado)" do
      {owner, clinic} = owner_and_clinic()

      p = Records.create_patient!("Com tags", @full, tenant: clinic.id, actor: owner)

      assert p.tags == ["pós-op joelho", "tendinite"]
      assert p.prefs == [@pref_a, @pref_b]
    end

    test "consentimento são dois booleanos independentes" do
      {owner, clinic} = owner_and_clinic()

      p =
        Records.create_patient!("Consent", %{lgpd: true, comunicacao: false},
          tenant: clinic.id,
          actor: owner
        )

      assert p.lgpd
      refute p.comunicacao
    end

    test "só o nome é obrigatório — cadastro mínimo passa com defaults" do
      {owner, clinic} = owner_and_clinic()

      p = Records.create_patient!("Só Nome", %{}, tenant: clinic.id, actor: owner)

      assert p.nome == "Só Nome"
      assert is_nil(p.cpf)
      assert p.atend_tipo == :particular
      assert p.cor_indice == 1
      assert p.tags == []
      assert p.prefs == []
      refute p.lgpd
      assert p.ativo
    end

    test "nome vazio é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Records.create_patient("", %{}, tenant: clinic.id, actor: owner)
    end

    test "atend_tipo fora do enum é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Records.create_patient("X", %{atend_tipo: :sus}, tenant: clinic.id, actor: owner)
    end

    test "cor_indice fora de 1..99 é recusado" do
      {owner, clinic} = owner_and_clinic()

      for ci <- [0, 100] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Records.create_patient("X", %{cor_indice: ci}, tenant: clinic.id, actor: owner),
               "cor_indice #{ci} deveria ser recusado"
      end
    end
  end

  describe "atualização" do
    test "edita campos parcialmente sem zerar os demais" do
      {owner, clinic} = owner_and_clinic()
      p = Records.create_patient!("Mariana", @full, tenant: clinic.id, actor: owner)

      updated =
        Records.update_patient!(p, %{tel: "(11) 91111-2222", cor_indice: 5},
          tenant: clinic.id,
          actor: owner
        )

      assert updated.tel == "(11) 91111-2222"
      assert updated.cor_indice == 5
      # não tocados
      assert updated.medico == "Dr. Silva"
      assert updated.tags == ["pós-op joelho", "tendinite"]
    end
  end

  describe "RBAC (ADR-016)" do
    test "owner e admin criam" do
      {owner, clinic} = owner_and_clinic()
      admin = member_with_role(clinic, :admin)

      assert %{} = Records.create_patient!("A", %{}, tenant: clinic.id, actor: owner)
      assert %{} = Records.create_patient!("B", %{}, tenant: clinic.id, actor: admin)
    end

    test "recepção e profissional NÃO criam, atualizam nem arquivam (Forbidden)" do
      {owner, clinic} = owner_and_clinic()
      alvo = Records.create_patient!("Alvo", %{}, tenant: clinic.id, actor: owner)

      for papel <- [:recepcao, :profissional] do
        user = member_with_role(clinic, papel)
        opts = [tenant: clinic.id, actor: user]

        assert {:error, %Ash.Error.Forbidden{}} = Records.create_patient("X", %{}, opts)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Records.update_patient(alvo, %{tel: "hack"}, opts)

        assert {:error, %Ash.Error.Forbidden{}} = Records.deactivate_patient(alvo, %{}, opts)
      end
    end

    test "todos os membros leem o cadastro (inclusive médico/CRM — sem field policy)" do
      {owner, clinic} = owner_and_clinic()
      Records.create_patient!("Visível", @full, tenant: clinic.id, actor: owner)

      for papel <- [:admin, :recepcao, :profissional] do
        user = member_with_role(clinic, papel)
        [p] = Records.list_patients!(tenant: clinic.id, actor: user)
        assert p.nome == "Visível"
        assert p.medico == "Dr. Silva", "#{papel} deveria ler médico/CRM na v1"
      end
    end

    test "quem não é membro não lê nada" do
      {_owner, clinic} = owner_and_clinic()
      estranho = Accounts.register_user!("Estranho", email(), authorize?: false)

      assert [] = Records.list_patients!(tenant: clinic.id, actor: estranho)
    end
  end

  describe "arquivar / reativar (não apaga)" do
    test "deactivate marca ativo: false sem mexer nos demais campos" do
      {owner, clinic} = owner_and_clinic()
      p = Records.create_patient!("Mariana", @full, tenant: clinic.id, actor: owner)

      arquivado = Records.deactivate_patient!(p, %{}, tenant: clinic.id, actor: owner)

      refute arquivado.ativo
      assert arquivado.cpf == "123.456.789-00"
    end

    test "reactivate volta ativo: true" do
      {owner, clinic} = owner_and_clinic()
      p = Records.create_patient!("X", %{}, tenant: clinic.id, actor: owner)

      arquivado = Records.deactivate_patient!(p, %{}, tenant: clinic.id, actor: owner)
      restaurado = Records.reactivate_patient!(arquivado, %{}, tenant: clinic.id, actor: owner)

      assert restaurado.ativo
    end

    test "a lista traz ativos E arquivados (a sidebar filtra por status)" do
      {owner, clinic} = owner_and_clinic()
      ativo = Records.create_patient!("Ativo", %{}, tenant: clinic.id, actor: owner)
      arq = Records.create_patient!("Arquivado", %{}, tenant: clinic.id, actor: owner)
      Records.deactivate_patient!(arq, %{}, tenant: clinic.id, actor: owner)

      ids = clinic.id |> then(&Records.list_patients!(tenant: &1, actor: owner)) |> Enum.map(& &1.id)

      assert ativo.id in ids
      assert arq.id in ids
    end
  end
end
