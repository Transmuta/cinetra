defmodule Api.Records.PatientListTest do
  @moduledoc """
  A lista paginada de pacientes (`read :list` + `Records.list_clinic_patients/2`) e as contagens
  da sidebar. É o que substituiu o carrega-tudo: filtro, busca e recorte de página agora são do
  servidor, então é aqui que a correção deles é provada.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Records

  defp email, do: "paclist-#{System.unique_integer([:positive])}@example.com"

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic, scope_for(owner, clinic)}
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp create(clinic, nome, attrs \\ %{}) do
    Records.create_patient!(nome, attrs, tenant: clinic.id, authorize?: false)
  end

  defp nomes(page), do: Enum.map(page.results, & &1.nome)

  describe "paginação" do
    test "recorta a página e devolve o total do recorte" do
      {_owner, clinic, scope} = owner_and_clinic()
      for i <- 1..5, do: create(clinic, "Paciente #{i}")

      primeira = Records.list_clinic_patients(scope, limit: 2, offset: 0)

      assert length(primeira.results) == 2
      assert primeira.count == 5
      assert primeira.more?

      ultima = Records.list_clinic_patients(scope, limit: 2, offset: 4)

      assert length(ultima.results) == 1
      assert ultima.count == 5
      refute ultima.more?
    end

    test "percorrer as páginas não repete nem pula ninguém (ordem total)" do
      {_owner, clinic, scope} = owner_and_clinic()
      esperados = for i <- 1..6, do: create(clinic, "P#{i}").id

      coletados =
        [0, 2, 4]
        |> Enum.flat_map(fn offset ->
          scope |> Records.list_clinic_patients(limit: 2, offset: offset) |> Map.get(:results)
        end)
        |> Enum.map(& &1.id)

      assert coletados == esperados
      assert Enum.uniq(coletados) == coletados
    end

    test "limit é limitado ao teto e valor inválido cai no default" do
      {_owner, clinic, scope} = owner_and_clinic()
      create(clinic, "Único")

      assert Records.list_clinic_patients(scope, limit: 5_000).limit == 200
      assert Records.list_clinic_patients(scope, limit: 0).limit == 50
      assert Records.list_clinic_patients(scope, limit: -3).limit == 50
      assert Records.list_clinic_patients(scope, limit: "abc").limit == 50
    end

    test "offset negativo é tratado como 0" do
      {_owner, clinic, scope} = owner_and_clinic()
      create(clinic, "Único")

      assert Records.list_clinic_patients(scope, offset: -10).offset == 0
    end

    test "a página só enxerga a clínica do escopo" do
      {_owner_a, clinic_a, scope_a} = owner_and_clinic()
      {_owner_b, clinic_b, _scope_b} = owner_and_clinic()
      create(clinic_a, "Da clínica A")
      create(clinic_b, "Da clínica B")

      page = Records.list_clinic_patients(scope_a)

      assert nomes(page) == ["Da clínica A"]
      assert page.count == 1
    end
  end

  describe "busca (q)" do
    setup do
      {_owner, clinic, scope} = owner_and_clinic()
      create(clinic, "Mariana Alves", %{cpf: "123.456.789-00", tel: "(11) 98888-7777"})
      create(clinic, "João Souza", %{cpf: "999.888.777-66", tel: "(11) 91111-2222"})
      %{scope: scope}
    end

    test "por parte do nome, sem diferenciar maiúsculas", %{scope: scope} do
      assert nomes(Records.list_clinic_patients(scope, q: "mari")) == ["Mariana Alves"]
      assert nomes(Records.list_clinic_patients(scope, q: "SOUZA")) == ["João Souza"]
    end

    test "por dígitos do CPF, mesmo com a máscara guardada na coluna", %{scope: scope} do
      # a coluna guarda "123.456.789-00"; o termo é só dígito
      assert nomes(Records.list_clinic_patients(scope, q: "45678")) == ["Mariana Alves"]
    end

    test "por dígitos do telefone", %{scope: scope} do
      assert nomes(Records.list_clinic_patients(scope, q: "91111")) == ["João Souza"]
    end

    test "termo que não casa devolve página vazia com total 0", %{scope: scope} do
      page = Records.list_clinic_patients(scope, q: "zzz")

      assert page.results == []
      assert page.count == 0
    end

    test "termo em branco não filtra", %{scope: scope} do
      assert Records.list_clinic_patients(scope, q: "   ").count == 2
      assert Records.list_clinic_patients(scope, q: nil).count == 2
    end
  end

  describe "segmento (status)" do
    setup do
      {owner, clinic, scope} = owner_and_clinic()
      create(clinic, "Ativo com resp", %{responsavel: "Maria (mãe)"})
      create(clinic, "Ativo sem resp")
      arquivado = create(clinic, "Arquivado")
      Records.deactivate_patient!(arquivado, %{}, tenant: clinic.id, actor: owner)
      %{scope: scope}
    end

    test "ativos / inativos", %{scope: scope} do
      assert nomes(Records.list_clinic_patients(scope, status: :ativos)) ==
               ["Ativo com resp", "Ativo sem resp"]

      assert nomes(Records.list_clinic_patients(scope, status: :inativos)) == ["Arquivado"]
    end

    test "resp traz só quem tem responsável legal", %{scope: scope} do
      assert nomes(Records.list_clinic_patients(scope, status: :resp)) == ["Ativo com resp"]
    end

    test "todos (default) traz ativos e arquivados", %{scope: scope} do
      assert Records.list_clinic_patients(scope).count == 3
    end
  end

  describe "busca + segmento combinam" do
    test "o filtro de segmento se aplica junto com o termo" do
      {owner, clinic, scope} = owner_and_clinic()
      create(clinic, "Ana Ativa")
      arquivada = create(clinic, "Ana Arquivada")
      Records.deactivate_patient!(arquivada, %{}, tenant: clinic.id, actor: owner)

      assert nomes(Records.list_clinic_patients(scope, q: "ana", status: :ativos)) == ["Ana Ativa"]
      assert Records.list_clinic_patients(scope, q: "ana").count == 2
    end
  end

  describe "contagens da sidebar" do
    test "conta por segmento e deriva inativos" do
      {owner, clinic, scope} = owner_and_clinic()
      create(clinic, "Com resp", %{responsavel: "Mãe"})
      create(clinic, "Sem resp")
      arquivado = create(clinic, "Arquivado")
      Records.deactivate_patient!(arquivado, %{}, tenant: clinic.id, actor: owner)

      assert Records.clinic_patient_counts(scope) == %{
               todos: 3,
               ativos: 2,
               inativos: 1,
               resp: 1
             }
    end

    test "clínica sem paciente conta zero em tudo" do
      {_owner, _clinic, scope} = owner_and_clinic()

      assert Records.clinic_patient_counts(scope) == %{todos: 0, ativos: 0, inativos: 0, resp: 0}
    end

    test "só conta a clínica do escopo" do
      {_owner_a, clinic_a, scope_a} = owner_and_clinic()
      {_owner_b, clinic_b, _scope_b} = owner_and_clinic()
      create(clinic_a, "Da A")
      create(clinic_b, "Da B 1")
      create(clinic_b, "Da B 2")

      assert Records.clinic_patient_counts(scope_a).todos == 1
    end
  end
end
