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

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email_unico("pac"), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp member_with_role(clinic, papel) do
    user = Accounts.register_user!("Membro #{papel}", email_unico("pac"), authorize?: false)

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
    cpf: "123.456.789-09",
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
      assert p.cpf == "123.456.789-09"
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
        Records.create_patient!(
          "Consent",
          %{lgpd: true, comunicacao: false, tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

      assert p.lgpd
      refute p.comunicacao
    end

    test "só o nome é obrigatório — cadastro mínimo passa com defaults" do
      {owner, clinic} = owner_and_clinic()

      p =
        Records.create_patient!("Só Nome", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

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

  defp criar(clinic, owner, extra) do
    Records.create_patient(
      "Validação",
      Map.merge(%{tel: Api.Generators.telefone_unico()}, extra),
      tenant: clinic.id,
      actor: owner
    )
  end

  defp erro_no_campo?({:error, %Ash.Error.Invalid{errors: errors}}, campo) do
    Enum.any?(errors, &(Map.get(&1, :field) == campo))
  end

  # AN-11 / HOM-012 (D10: **barra no salvar**, diverge do "duplicado só avisa" por decisão
  # explícita). Só o que veio preenchido é validado — obrigatório continua sendo nome + telefone.
  describe "validação de identificação (AN-11)" do
    test "CPF com dígito verificador errado barra, no campo certo" do
      {owner, clinic} = owner_and_clinic()
      assert criar(clinic, owner, %{cpf: "123.456.789-00"}) |> erro_no_campo?(:cpf)
    end

    test "CPF válido passa, com ou sem máscara" do
      {owner, clinic} = owner_and_clinic()
      assert {:ok, _} = criar(clinic, owner, %{cpf: "390.533.447-05"})
      assert {:ok, _} = criar(clinic, owner, %{cpf: "39053344705"})
    end

    test "e-mail sem forma de e-mail barra" do
      {owner, clinic} = owner_and_clinic()
      assert criar(clinic, owner, %{email: "mari.example.com"}) |> erro_no_campo?(:email)
      assert {:ok, _} = criar(clinic, owner, %{email: "mari@example.com"})
    end

    test "nascimento no futuro barra; passado plausível passa" do
      {owner, clinic} = owner_and_clinic()

      assert criar(clinic, owner, %{nascimento: Date.add(Date.utc_today(), 2)})
             |> erro_no_campo?(:nascimento)

      assert {:ok, _} = criar(clinic, owner, %{nascimento: ~D[1990-05-20]})
    end

    test "nascimento antes de 1900 barra (dedo a mais no ano)" do
      {owner, clinic} = owner_and_clinic()
      assert criar(clinic, owner, %{nascimento: ~D[1889-01-01]}) |> erro_no_campo?(:nascimento)
    end

    test "os três vazios continuam passando — obrigatório é só nome e telefone" do
      {owner, clinic} = owner_and_clinic()
      assert {:ok, _} = criar(clinic, owner, %{})
    end

    test "no update a mesma régua vale" do
      {owner, clinic} = owner_and_clinic()
      {:ok, p} = criar(clinic, owner, %{})

      assert {:error, %Ash.Error.Invalid{}} =
               Records.update_patient(p, %{cpf: "111.111.111-11"},
                 tenant: clinic.id,
                 actor: owner
               )
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

      # Guardado em E.164 — a forma canônica que o opt-out e o envio comparam (doc 52 §9). A
      # máscara volta na tela, por `web/src/lib/telefone.ts`.
      assert updated.tel == "+5511911112222"
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

      assert %{} =
               Records.create_patient!("A", %{tel: Api.Generators.telefone_unico()},
                 tenant: clinic.id,
                 actor: owner
               )

      assert %{} =
               Records.create_patient!("B", %{tel: Api.Generators.telefone_unico()},
                 tenant: clinic.id,
                 actor: admin
               )
    end

    # Revisão de 2026-07-29 (AN-06): a matriz publicada expôs a divergência — quem cadastra
    # paciente no balcão é a RECEPÇÃO (o mesmo racional do telefone obrigatório: "cobrar é
    # quando a pessoa está na frente de quem digita"), e a policy só deixava owner/admin.
    test "recepção cria, atualiza e arquiva a ficha" do
      {owner, clinic} = owner_and_clinic()

      alvo =
        Records.create_patient!("Alvo", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

      recepcao = member_with_role(clinic, :recepcao)
      opts = [tenant: clinic.id, actor: recepcao]

      assert {:ok, _} =
               Records.create_patient(
                 "Pela Recepção",
                 %{tel: Api.Generators.telefone_unico()},
                 opts
               )

      assert {:ok, _} =
               Records.update_patient(alvo, %{tel: Api.Generators.telefone_unico()}, opts)

      assert {:ok, _} = Records.deactivate_patient(alvo, %{}, opts)
    end

    test "profissional NÃO cria, atualiza nem arquiva (Forbidden)" do
      {owner, clinic} = owner_and_clinic()

      alvo =
        Records.create_patient!("Alvo", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

      user = member_with_role(clinic, :profissional)
      opts = [tenant: clinic.id, actor: user]

      # Com telefone VÁLIDO de propósito: sem ele a ação para na validação e devolve
      # `Invalid` antes de chegar à policy — o teste passaria a provar outra coisa.
      assert {:error, %Ash.Error.Forbidden{}} =
               Records.create_patient("X", %{tel: Api.Generators.telefone_unico()}, opts)

      assert {:error, %Ash.Error.Forbidden{}} =
               Records.update_patient(alvo, %{tel: Api.Generators.telefone_unico()}, opts)

      assert {:error, %Ash.Error.Forbidden{}} = Records.deactivate_patient(alvo, %{}, opts)
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
      estranho = Accounts.register_user!("Estranho", email_unico("pac"), authorize?: false)

      assert [] = Records.list_patients!(tenant: clinic.id, actor: estranho)
    end
  end

  describe "arquivar / reativar (não apaga)" do
    test "deactivate marca ativo: false sem mexer nos demais campos" do
      {owner, clinic} = owner_and_clinic()
      p = Records.create_patient!("Mariana", @full, tenant: clinic.id, actor: owner)

      arquivado = Records.deactivate_patient!(p, %{}, tenant: clinic.id, actor: owner)

      refute arquivado.ativo
      assert arquivado.cpf == "123.456.789-09"
    end

    test "reactivate volta ativo: true" do
      {owner, clinic} = owner_and_clinic()

      p =
        Records.create_patient!("X", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

      arquivado = Records.deactivate_patient!(p, %{}, tenant: clinic.id, actor: owner)
      restaurado = Records.reactivate_patient!(arquivado, %{}, tenant: clinic.id, actor: owner)

      assert restaurado.ativo
    end

    test "a lista traz ativos E arquivados (a sidebar filtra por status)" do
      {owner, clinic} = owner_and_clinic()

      ativo =
        Records.create_patient!("Ativo", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

      arq =
        Records.create_patient!("Arquivado", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

      Records.deactivate_patient!(arq, %{}, tenant: clinic.id, actor: owner)

      ids =
        clinic.id |> then(&Records.list_patients!(tenant: &1, actor: owner)) |> Enum.map(& &1.id)

      assert ativo.id in ids
      assert arq.id in ids
    end
  end
end
