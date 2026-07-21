defmodule Api.Directory.ProfessionalTest do
  @moduledoc """
  Ficha completa do profissional (fatia Profissionais, 2026-07-17). Cobre o que a fatia fixa:
  os campos das 6 seções, RBAC (owner/admin escrevem, todos leem), arquivar/reativar em vez de
  apagar, o enum de vínculo e o índice de cor. Isolamento por-tenant e cascade têm testes
  próprios (`ProfessionalTenantIsolationTest`, `ProfessionalCascadeTest`).

  Como nos demais, a RLS (ADR-018) não é exercida aqui: o sandbox conecta como `postgres`
  (BYPASSRLS). Prova-se o filtro por atributo do Ash e as regras de domínio.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory

  defp email, do: "prof-#{System.unique_integer([:positive])}@example.com"

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp member_with_role(clinic, papel, professional_id \\ nil) do
    user = Accounts.register_user!("Membro #{papel}", email(), authorize?: false)

    attrs = %{papel: papel, user_id: user.id, clinic_id: clinic.id}
    attrs = if professional_id, do: Map.put(attrs, :professional_id, professional_id), else: attrs

    {:ok, m} = Accounts.invite_member(attrs, authorize?: false)
    {:ok, _ativo} = Accounts.accept_invite(m, authorize?: false)
    user
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  @full %{
    nome_exibicao: "Dra. Marina",
    nascimento: ~D[1988-03-12],
    cpf: "123.456.789-00",
    rg: "12.345.678-9 SSP",
    estado_civil: "Solteiro(a)",
    tel: "(11) 98123-4451",
    email: "marina@example.com",
    cep: "01310-100",
    endereco: "Av. Paulista",
    numero: "1000",
    complemento: "Sala 5",
    bairro: "Bela Vista",
    cidade: "São Paulo",
    uf: "SP",
    emergencia_nome: "João (irmão)",
    emergencia_tel: "(11) 90000-0000",
    profissao: "Fisioterapia",
    crefito: "CREFITO 3/123456-F",
    registro_uf: "SP",
    ano_conclusao: "2010",
    especialidades: ["Traumato-Ortopedia", "Desportiva"],
    sub: "Traumato-Ortopedia",
    vinculo: :pj,
    razao_social: "Marina Fisio LTDA",
    cnpj: "12.345.678/0001-90",
    banco: "Banco X",
    agencia: "0001",
    conta: "12345-6",
    conta_tipo: "Corrente",
    pix: "marina@example.com",
    cor_indice: 3
  }

  describe "criação da ficha completa" do
    test "persiste os campos das 6 seções, em texto puro (sem cifra)" do
      {owner, clinic} = owner_and_clinic()

      prof =
        Directory.create_professional!("Dra. Marina Lopes", @full,
          tenant: clinic.id,
          actor: owner
        )

      assert prof.nome == "Dra. Marina Lopes"
      assert prof.cpf == "123.456.789-00"
      assert prof.crefito == "CREFITO 3/123456-F"
      assert prof.especialidades == ["Traumato-Ortopedia", "Desportiva"]
      assert prof.vinculo == :pj
      assert prof.pix == "marina@example.com"
      assert prof.cor_indice == 3
      # defaults de status/horário
      assert prof.ativo
      assert prof.segue_horario_clinica
    end

    test "só o nome é obrigatório — cadastro mínimo passa" do
      {owner, clinic} = owner_and_clinic()

      prof = Directory.create_professional!("Dr. Só Nome", %{}, tenant: clinic.id, actor: owner)

      assert prof.nome == "Dr. Só Nome"
      assert is_nil(prof.crefito)
      assert prof.cor_indice == 1
    end

    test "nome vazio é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_professional("", %{}, tenant: clinic.id, actor: owner)
    end

    test "vínculo fora do enum é recusado" do
      {owner, clinic} = owner_and_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Directory.create_professional("X", %{vinculo: :estagiario},
                 tenant: clinic.id,
                 actor: owner
               )
    end

    test "cor_indice fora de 1..99 é recusado" do
      {owner, clinic} = owner_and_clinic()

      for ci <- [0, 100] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Directory.create_professional("X", %{cor_indice: ci},
                   tenant: clinic.id,
                   actor: owner
                 ),
               "cor_indice #{ci} deveria ser recusado"
      end
    end
  end

  describe "atualização" do
    test "edita campos parcialmente sem zerar os demais" do
      {owner, clinic} = owner_and_clinic()

      prof =
        Directory.create_professional!("Dra. Marina", @full, tenant: clinic.id, actor: owner)

      updated =
        Directory.update_professional!(prof, %{sub: "Osteopatia", cor_indice: 5},
          tenant: clinic.id,
          actor: owner
        )

      assert updated.sub == "Osteopatia"
      assert updated.cor_indice == 5
      # não tocados
      assert updated.crefito == "CREFITO 3/123456-F"
      assert updated.vinculo == :pj
    end
  end

  describe "RBAC (ADR-016)" do
    test "owner e admin criam" do
      {owner, clinic} = owner_and_clinic()
      admin = member_with_role(clinic, :admin)

      assert %{} = Directory.create_professional!("A", %{}, tenant: clinic.id, actor: owner)
      assert %{} = Directory.create_professional!("B", %{}, tenant: clinic.id, actor: admin)
    end

    test "recepção e profissional NÃO criam, atualizam nem arquivam (Forbidden)" do
      {owner, clinic} = owner_and_clinic()
      prof = Directory.create_professional!("Alvo", %{}, tenant: clinic.id, actor: owner)

      for papel <- [:recepcao, :profissional] do
        user = member_with_role(clinic, papel)
        opts = [tenant: clinic.id, actor: user]

        assert {:error, %Ash.Error.Forbidden{}} =
                 Directory.create_professional("X", %{}, opts)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Directory.update_professional(prof, %{sub: "Hack"}, opts)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Directory.deactivate_professional(prof, %{}, opts)
      end
    end

    test "owner, admin e recepção leem o diretório inteiro" do
      {owner, clinic} = owner_and_clinic()
      Directory.create_professional!("Visível", %{}, tenant: clinic.id, actor: owner)

      for papel <- [:admin, :recepcao] do
        user = member_with_role(clinic, papel)

        nomes =
          clinic.id
          |> then(&Directory.list_professionals!(tenant: &1, actor: user))
          |> Enum.map(& &1.nome)

        assert "Visível" in nomes, "#{papel} deveria ler o diretório inteiro"
      end
    end

    test "quem não é membro não lê nada" do
      {_owner, clinic} = owner_and_clinic()
      estranho = Accounts.register_user!("Estranho", email(), authorize?: false)

      assert [] = Directory.list_professionals!(tenant: clinic.id, actor: estranho)
    end
  end

  # P1 (2026-07-21): o papel `profissional` só enxerga o **próprio** registro no diretório —
  # não a ficha do colega (CPF, dados bancários) nem a escala dele na agenda/Semana/Mês, que
  # se alimentam desta mesma leitura. Espelha o recorte A7 da agenda (`OwnAgendaOnly`), com o
  # mesmo fail-closed do `Membership.professional_id` "mole".
  describe "P1 — profissional só vê o próprio registro" do
    test "profissional vê só a si e NÃO vê o colega" do
      {owner, clinic} = owner_and_clinic()
      eu = Directory.create_professional!("Eu", %{}, tenant: clinic.id, actor: owner)
      _colega = Directory.create_professional!("Colega", %{}, tenant: clinic.id, actor: owner)

      user = member_with_role(clinic, :profissional, eu.id)

      nomes =
        Directory.list_professionals!(tenant: clinic.id, actor: user) |> Enum.map(& &1.nome)

      assert nomes == ["Eu"]
    end

    test "FAIL-CLOSED: profissional SEM professional_id não vê ninguém" do
      {owner, clinic} = owner_and_clinic()
      Directory.create_professional!("Alguém", %{}, tenant: clinic.id, actor: owner)

      # `Membership.professional_id` é allow_nil? true — o "UUID mole". Fail-open aqui daria
      # a lista inteira ao profissional sem vínculo; tem de fechar.
      user = member_with_role(clinic, :profissional, nil)

      assert [] = Directory.list_professionals!(tenant: clinic.id, actor: user)
    end
  end

  describe "arquivar / reativar (não apaga)" do
    test "deactivate marca ativo: false sem mexer nos demais campos" do
      {owner, clinic} = owner_and_clinic()
      prof = Directory.create_professional!("Dra. Marina", @full, tenant: clinic.id, actor: owner)

      arquivado = Directory.deactivate_professional!(prof, %{}, tenant: clinic.id, actor: owner)

      refute arquivado.ativo
      assert arquivado.crefito == "CREFITO 3/123456-F"
    end

    test "reactivate volta ativo: true" do
      {owner, clinic} = owner_and_clinic()
      prof = Directory.create_professional!("X", %{}, tenant: clinic.id, actor: owner)

      restaurado =
        prof
        |> Directory.deactivate_professional!(%{}, tenant: clinic.id, actor: owner)
        |> Directory.reactivate_professional!(%{}, tenant: clinic.id, actor: owner)

      assert restaurado.ativo
    end

    test "não existe destroy no recurso" do
      refute Enum.any?(
               Ash.Resource.Info.actions(Api.Directory.Professional),
               &(&1.type == :destroy)
             )
    end
  end

  describe "wrappers de escopo do domínio" do
    test "create/update/deactivate/fetch pela clínica ativa do escopo" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      prof = Directory.create_clinic_professional(scope, %{nome: "Dra. Beatriz", crefito: "C-1"})
      assert {:ok, %{nome: "Dra. Beatriz"}} = prof
      {:ok, prof} = prof

      assert {:ok, %{sub: "Osteopatia"}} =
               Directory.update_clinic_professional(scope, prof, %{sub: "Osteopatia"})

      assert {:ok, %{ativo: false}} = Directory.deactivate_clinic_professional(scope, prof)

      assert {:ok, %{id: id}} = Directory.fetch_clinic_professional(scope, prof.id)
      assert id == prof.id
    end

    test "fetch de profissional de outra clínica é 404 (nil)" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()
      scope_a = scope_for(owner_a, clinic_a)

      alheio = Directory.create_professional!("Alheio", %{}, tenant: clinic_b.id, actor: owner_b)

      assert {:ok, nil} = Directory.fetch_clinic_professional(scope_a, alheio.id)
    end
  end
end
