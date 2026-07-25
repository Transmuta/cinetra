defmodule ApiWeb.PatientsControllerTest do
  @moduledoc """
  Endpoints do cadastro de pacientes (fatia Pacientes). Integração real: sessão assinada +
  `LoadScope`, RBAC (leitura para todo membro, escrita só owner/admin), a escada 401/403/404/422
  e a garantia de que o `clinic_id` vem do escopo, nunca do corpo.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Records

  defp email, do: "pacc-#{System.unique_integer([:positive])}@example.com"

  defp sign_in(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  defp authed(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp active_member_session(owner, clinic, papel) do
    addr = email()

    {:ok, pending} =
      Accounts.invite_member_by_email(addr, %{papel: papel, clinic_id: clinic.id}, actor: owner)

    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, _} = Accounts.accept_invite(pending, actor: user)
    sign_in(addr)
  end

  defp owner_with_clinic do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp create_patient(clinic, nome \\ "Mariana Alves", overrides \\ %{}) do
    Records.create_patient!(nome, overrides, tenant: clinic.id, authorize?: false)
  end

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/patients" do
    test "lista os pacientes da clínica ativa", %{conn: conn, clinic: clinic} do
      create_patient(clinic, "Ana")
      create_patient(clinic, "Bruno")

      body = conn |> get(~p"/api/patients") |> json_response(200)
      nomes = Enum.map(body["patients"], & &1["nome"])

      assert "Ana" in nomes
      assert "Bruno" in nomes
    end

    test "qualquer membro lê (recepção)", %{base_conn: base, owner: owner, clinic: clinic} do
      create_patient(clinic, "Visível")
      recepcao = active_member_session(owner, clinic, :recepcao)

      body = base |> authed(recepcao) |> get(~p"/api/patients") |> json_response(200)
      assert "Visível" in Enum.map(body["patients"], & &1["nome"])
    end

    test "sem sessão → 401", %{base_conn: base} do
      assert base |> get(~p"/api/patients") |> json_response(401)
    end
  end

  describe "GET /api/patients — paginação, busca e contagens" do
    test "devolve a página + o total + as contagens da sidebar", %{conn: conn, clinic: clinic} do
      for i <- 1..3, do: create_patient(clinic, "Paciente #{i}")

      body = conn |> get(~p"/api/patients?limit=2&offset=0") |> json_response(200)

      assert length(body["patients"]) == 2
      assert body["page"] == %{"limit" => 2, "offset" => 0, "total" => 3, "more" => true}
      assert body["counts"] == %{"todos" => 3, "ativos" => 3, "inativos" => 0, "resp" => 0}
    end

    test "a segunda página fecha a lista", %{conn: conn, clinic: clinic} do
      for i <- 1..3, do: create_patient(clinic, "Paciente #{i}")

      body = conn |> get(~p"/api/patients?limit=2&offset=2") |> json_response(200)

      assert length(body["patients"]) == 1
      refute body["page"]["more"]
    end

    test "?q= busca por nome e por dígitos do CPF", %{conn: conn, clinic: clinic} do
      create_patient(clinic, "Mariana Alves", %{cpf: "123.456.789-00"})
      create_patient(clinic, "João Souza", %{cpf: "999.888.777-66"})

      por_nome = conn |> get(~p"/api/patients?q=mari") |> json_response(200)
      assert Enum.map(por_nome["patients"], & &1["nome"]) == ["Mariana Alves"]
      assert por_nome["page"]["total"] == 1

      por_cpf = conn |> get(~p"/api/patients?q=45678") |> json_response(200)
      assert Enum.map(por_cpf["patients"], & &1["nome"]) == ["Mariana Alves"]
    end

    test "?filter= recorta o segmento e as contagens acompanham", %{conn: conn, clinic: clinic} do
      create_patient(clinic, "Ativo")
      arquivado = create_patient(clinic, "Arquivado")
      conn |> post(~p"/api/patients/#{arquivado.id}/deactivate") |> json_response(200)

      inativos = conn |> get(~p"/api/patients?filter=inativos") |> json_response(200)
      assert Enum.map(inativos["patients"], & &1["nome"]) == ["Arquivado"]

      assert inativos["counts"] == %{"todos" => 2, "ativos" => 1, "inativos" => 1, "resp" => 0}
    end

    test "?q= combinado com página >1 recorta o conjunto FILTRADO", %{conn: conn, clinic: clinic} do
      for i <- 1..3, do: create_patient(clinic, "Ana #{i}")
      create_patient(clinic, "Bruno Fora")

      p1 = conn |> get(~p"/api/patients?q=ana&limit=2&offset=0") |> json_response(200)
      assert length(p1["patients"]) == 2
      assert p1["page"]["total"] == 3
      assert p1["page"]["more"]

      p2 = conn |> get(~p"/api/patients?q=ana&limit=2&offset=2") |> json_response(200)
      assert length(p2["patients"]) == 1
      refute p2["page"]["more"]

      # o filtro é aplicado ANTES do recorte: quem não casa nunca entra em página nenhuma
      nomes = Enum.map(p1["patients"] ++ p2["patients"], & &1["nome"])
      assert Enum.all?(nomes, &String.starts_with?(&1, "Ana"))
    end

    test "limit inválido cai no default (a lista não quebra)", %{conn: conn, clinic: clinic} do
      create_patient(clinic, "Único")

      body = conn |> get(~p"/api/patients?limit=abc&offset=xyz") |> json_response(200)

      assert body["page"]["limit"] == 50
      assert body["page"]["offset"] == 0
    end

    test "limit acima do teto é limitado a 200", %{conn: conn, clinic: clinic} do
      create_patient(clinic, "Único")

      body = conn |> get(~p"/api/patients?limit=5000") |> json_response(200)

      assert body["page"]["limit"] == 200
    end
  end

  describe "POST /api/patients" do
    test "owner cria (201) e o corpo NÃO define clinic_id", %{conn: conn, clinic: clinic} do
      params = %{
        "nome" => "Novo Paciente",
        "cpf" => "123.456.789-00",
        "clinic_id" => Ecto.UUID.generate()
      }

      body = conn |> post(~p"/api/patients", params) |> json_response(201)

      assert body["patient"]["nome"] == "Novo Paciente"
      assert body["patient"]["cpf"] == "123.456.789-00"
      refute Map.has_key?(body["patient"], "clinic_id")

      # foi mesmo para a clínica do escopo (não para o clinic_id do corpo)
      [p] = Records.list_patients!(tenant: clinic.id, authorize?: false)
      assert p.nome == "Novo Paciente"
    end

    test "admin cria (201)", %{base_conn: base, owner: owner, clinic: clinic} do
      admin = active_member_session(owner, clinic, :admin)

      body =
        base
        |> authed(admin)
        |> post(~p"/api/patients", %{"nome" => "Pela Admin"})
        |> json_response(201)

      assert body["patient"]["nome"] == "Pela Admin"
    end

    test "recepção e profissional → 403", %{base_conn: base, owner: owner, clinic: clinic} do
      for papel <- [:recepcao, :profissional] do
        user = active_member_session(owner, clinic, papel)

        assert base
               |> authed(user)
               |> post(~p"/api/patients", %{"nome" => "X"})
               |> json_response(403)
      end
    end

    test "sem sessão → 401", %{base_conn: base} do
      assert base |> post(~p"/api/patients", %{"nome" => "X"}) |> json_response(401)
    end

    test "nome vazio → 422 com detalhe do campo", %{conn: conn} do
      body = conn |> post(~p"/api/patients", %{"nome" => ""}) |> json_response(422)
      assert body["error"] == "invalid"
      assert Enum.any?(body["details"], &(&1["field"] == "nome"))
    end
  end

  describe "GET /api/patients/:id" do
    test "devolve a ficha", %{conn: conn, clinic: clinic} do
      p = create_patient(clinic, "Detalhe", %{tags: ["tendinite"]})

      body = conn |> get(~p"/api/patients/#{p.id}") |> json_response(200)
      assert body["patient"]["nome"] == "Detalhe"
      assert body["patient"]["tags"] == ["tendinite"]
    end

    test "id inexistente → 404", %{conn: conn} do
      assert conn |> get(~p"/api/patients/#{Ecto.UUID.generate()}") |> json_response(404)
    end

    test "id malformado (não-UUID) → 404, não 500", %{conn: conn} do
      assert conn |> get(~p"/api/patients/nao-e-uuid") |> json_response(404)
      assert conn |> get(~p"/api/patients/123") |> json_response(404)
    end

    test "paciente de outra clínica → 404 (isolamento)", %{conn: conn} do
      {_owner_b, clinic_b} = owner_with_clinic()
      alheio = create_patient(clinic_b, "De Outra")

      assert conn |> get(~p"/api/patients/#{alheio.id}") |> json_response(404)
    end
  end

  describe "PATCH /api/patients/:id" do
    test "atualiza parcialmente (200)", %{conn: conn, clinic: clinic} do
      p = create_patient(clinic, "Editar", %{tel: "(11) 90000-0000"})

      body =
        conn
        |> patch(~p"/api/patients/#{p.id}", %{"tel" => "(11) 98888-7777", "medico" => "Dr. Novo"})
        |> json_response(200)

      assert body["patient"]["tel"] == "(11) 98888-7777"
      assert body["patient"]["medico"] == "Dr. Novo"
    end

    test "corpo inválido → 422 com detalhe (a escada de erro vale no update)", %{
      conn: conn,
      clinic: clinic
    } do
      p = create_patient(clinic, "Editar")
      body = conn |> patch(~p"/api/patients/#{p.id}", %{"nome" => ""}) |> json_response(422)
      assert body["error"] == "invalid"
      assert Enum.any?(body["details"], &(&1["field"] == "nome"))
    end

    test "recepção não atualiza → 403", %{base_conn: base, owner: owner, clinic: clinic} do
      p = create_patient(clinic)
      recepcao = active_member_session(owner, clinic, :recepcao)

      assert base
             |> authed(recepcao)
             |> patch(~p"/api/patients/#{p.id}", %{"tel" => "x"})
             |> json_response(403)
    end

    test "id inexistente → 404", %{conn: conn} do
      assert conn
             |> patch(~p"/api/patients/#{Ecto.UUID.generate()}", %{"tel" => "x"})
             |> json_response(404)
    end
  end

  describe "arquivar / reativar" do
    test "deactivate e reactivate alternam ativo", %{conn: conn, clinic: clinic} do
      p = create_patient(clinic)

      arq = conn |> post(~p"/api/patients/#{p.id}/deactivate") |> json_response(200)
      refute arq["patient"]["ativo"]

      rea = conn |> post(~p"/api/patients/#{p.id}/reactivate") |> json_response(200)
      assert rea["patient"]["ativo"]
    end

    test "recepção não arquiva → 403", %{base_conn: base, owner: owner, clinic: clinic} do
      p = create_patient(clinic)
      recepcao = active_member_session(owner, clinic, :recepcao)

      assert base
             |> authed(recepcao)
             |> post(~p"/api/patients/#{p.id}/deactivate")
             |> json_response(403)
    end
  end

  # C13 / Frente 7: o histórico é a lista de PRESENÇAS do paciente, não de blocos — numa turma o
  # bloco pode estar concluído com a presença dele faltando.
  describe "GET /api/patients/:patient_id/history" do
    defp dias_atras(n, hhmm) do
      hoje = Date.utc_today()
      {:ok, dt} = Api.Scheduling.LocalTime.to_utc(Date.add(hoje, -n), hhmm, "America/Sao_Paulo")
      dt
    end

    defp sessao_para(clinic, owner, paciente, starts_at) do
      prof = Api.Directory.create_professional!("Dra. H", %{}, tenant: clinic.id, actor: owner)

      tipo =
        Api.Directory.create_appointment_type!(
          %{
            nome: "Sessão #{System.unique_integer([:positive])}",
            duracao_minutos: 50,
            cor: "#0FB5A6",
            icon: "Activity"
          },
          tenant: clinic.id,
          actor: owner
        )

      {:ok, appt} =
        Api.Scheduling.schedule_appointment(
          %{
            starts_at: starts_at,
            professional_id: prof.id,
            appointment_type_id: tipo.id,
            patient_ids: [paciente.id]
          },
          tenant: clinic.id,
          authorize?: false
        )

      {appt, tipo}
    end

    test "lista da sessão mais recente para a mais antiga", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Histórico")
      sessao_para(clinic, owner, paciente, dias_atras(14, "08:00"))
      {_appt, tipo} = sessao_para(clinic, owner, paciente, dias_atras(7, "09:00"))

      body = json_response(get(conn, "/api/patients/#{paciente.id}/history"), 200)

      assert [primeira, segunda] = body["sessions"]
      assert primeira["starts_at"] > segunda["starts_at"]
      assert primeira["tipo"] == tipo.nome
      assert primeira["status"] == "prevista"
      assert primeira["profissional"] == "Dra. H"
      assert body["more"] == false
    end

    test "o que aparece é a presença DELE, não o desfecho do bloco", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Dono da turma")
      {appt, _tipo} = sessao_para(clinic, owner, paciente, dias_atras(1, "08:00"))
      colega = create_patient(clinic, "Colega")

      {:ok, _} =
        Api.Scheduling.add_appointment_participants(appt, %{patient_ids: [colega.id]},
          tenant: clinic.id,
          authorize?: false
        )

      presencas =
        Api.Scheduling.list_attendances!(
          tenant: clinic.id,
          authorize?: false,
          query: [filter: [appointment_id: appt.id]]
        )

      presenca = fn patient_id -> Enum.find(presencas, &(&1.patient_id == patient_id)) end

      # o dono compareceu, o colega faltou → o BLOCO rola para `:concluido` ("aconteceu para pelo
      # menos um"), e é justamente isso que a ficha do colega não pode mostrar como concluída
      {:ok, _} =
        Api.Scheduling.mark_attendance_present(presenca.(paciente.id), %{},
          tenant: clinic.id,
          authorize?: false
        )

      {:ok, _} =
        Api.Scheduling.mark_attendance_absent(presenca.(colega.id), %{},
          tenant: clinic.id,
          authorize?: false
        )

      dono = json_response(get(conn, "/api/patients/#{paciente.id}/history"), 200)["sessions"]
      outro = json_response(get(conn, "/api/patients/#{colega.id}/history"), 200)["sessions"]

      assert [%{"status" => "concluida"}] = dono
      # mesmo bloco, presença diferente — é o ponto do modelo (attendance.ex:8)
      assert [%{"status" => "faltou", "appointment_status" => "concluido"}] = outro
    end

    test "respeita o limite e avisa que ficou coisa para trás", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Muitas sessões")
      Enum.each(1..3, &sessao_para(clinic, owner, paciente, dias_atras(&1, "08:00")))

      body = json_response(get(conn, "/api/patients/#{paciente.id}/history?limit=2"), 200)

      assert length(body["sessions"]) == 2
      assert body["more"] == true
    end

    test "exige autenticação", %{base_conn: base_conn} do
      assert json_response(get(base_conn, "/api/patients/#{Ash.UUID.generate()}/history"), 401)
    end
  end
end
