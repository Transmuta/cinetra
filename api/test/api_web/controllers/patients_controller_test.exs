defmodule ApiWeb.PatientsControllerTest do
  @moduledoc """
  Endpoints do cadastro de pacientes (fatia Pacientes). Integração real: sessão assinada +
  `LoadScope`, RBAC (leitura para todo membro, escrita só owner/admin), a escada 401/403/404/422
  e a garantia de que o `clinic_id` vem do escopo, nunca do corpo.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Records

  defp owner_with_clinic do
    owner = sign_in!(email_unico("pacc"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  # Soma as LINHAS devolvidas pelo banco numa tabela durante `fun` — o instrumento que separa
  # "devolveu 5" de "leu 30 e jogou 25 fora".
  defp com_linhas(source, fun) do
    parent = self()
    ref = make_ref()

    handler = fn _e, _m, meta, _c ->
      if meta[:source] == source do
        n =
          case meta[:result] do
            {:ok, %{num_rows: n}} -> n
            _ -> 0
          end

        send(parent, {ref, n})
      end
    end

    :telemetry.attach({__MODULE__, ref}, [:api, :repo, :query], handler, nil)
    resultado = fun.()
    :telemetry.detach({__MODULE__, ref})
    {resultado, drenar(ref, 0)}
  end

  defp drenar(ref, acc) do
    receive do
      {^ref, n} -> drenar(ref, acc + n)
    after
      50 -> acc
    end
  end

  # Telefone por default: ele virou obrigatório (doc 52 §9). Quem testa o campo passa o seu.
  defp create_patient(clinic, nome \\ "Mariana Alves", overrides \\ %{}) do
    overrides = Map.merge(%{tel: Api.Generators.telefone_unico()}, Map.new(overrides))

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
      recepcao = sessao_de_membro!(owner, clinic, :recepcao)

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

  describe "telefone obrigatório (doc 52 §9 / D6b)" do
    test "criar sem telefone é 422, com o campo apontado", %{conn: conn} do
      # A regra atravessa a fronteira, então o teste também: do domínio chega átomo, daqui chega
      # string, e é aqui que a recepção vê a mensagem (a lição do doc 49).
      body =
        conn
        |> post(~p"/api/patients", %{"nome" => "Sem Telefone"})
        |> json_response(422)

      assert %{"field" => "tel", "message" => "Telefone é obrigatório"} in body["details"]
    end

    test "telefone que não é telefone é 422 e diz o que fazer", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/patients", %{"nome" => "Torto", "tel" => "1234"})
        |> json_response(422)

      assert %{"field" => "tel", "message" => "Telefone inválido — use DDD + número"} in body[
               "details"
             ]
    end

    test "a máscara do formulário é aceita e guardada em E.164", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/patients", %{"nome" => "Com Máscara", "tel" => "(11) 98765-4321"})
        |> json_response(201)

      assert body["patient"]["tel"] == "+5511987654321"
    end

    test "fixo é aceito — quem não recebe WhatsApp cai para o e-mail", %{conn: conn} do
      # Exigir celular empurraria a recepção a inventar número para conseguir salvar. Quem decide
      # que o fixo não serve para WhatsApp é o envio, não o cadastro.
      body =
        conn
        |> post(~p"/api/patients", %{"nome" => "Só Fixo", "tel" => "(11) 3456-7890"})
        |> json_response(201)

      assert body["patient"]["tel"] == "+551134567890"
    end

    test "a ficha LEGADA sem telefone só é cobrada quando alguém a edita", %{
      conn: conn,
      clinic: clinic,
      owner: owner
    } do
      # D6 opção (b): sem backfill e sem `NOT NULL` numa tabela com linhas nulas. A linha antiga
      # continua legível; o próximo save é que cobra.
      legado = paciente_legado_sem_tel!(%{clinic: clinic, owner: owner}, %{})

      assert conn |> get(~p"/api/patients/#{legado.id}") |> json_response(200)

      body =
        conn
        |> patch(~p"/api/patients/#{legado.id}", %{"medico" => "Dr. Novo"})
        |> json_response(422)

      assert %{"field" => "tel", "message" => "Telefone é obrigatório"} in body["details"]
    end
  end

  describe "POST /api/patients" do
    test "owner cria (201) e o corpo NÃO define clinic_id", %{conn: conn, clinic: clinic} do
      params = %{
        "nome" => "Novo Paciente",
        "cpf" => "123.456.789-00",
        "tel" => "(11) 98765-4321",
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
      admin = sessao_de_membro!(owner, clinic, :admin)

      body =
        base
        |> authed(admin)
        |> post(~p"/api/patients", %{"nome" => "Pela Admin", "tel" => "11987650001"})
        |> json_response(201)

      assert body["patient"]["nome"] == "Pela Admin"
    end

    test "recepção e profissional → 403", %{base_conn: base, owner: owner, clinic: clinic} do
      for papel <- [:recepcao, :profissional] do
        user = sessao_de_membro!(owner, clinic, papel)

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

    test "a ficha traz `faltas`, e é a ÚNICA porta que paga o agregado", %{
      conn: conn,
      clinic: clinic
    } do
      p = create_patient(clinic, "Com Faltas")

      # A ficha precisa do número: é o stat do cabeçalho (doc 51 §L3).
      {body, sql_show} =
        com_sql(fn -> conn |> get(~p"/api/patients/#{p.id}") |> json_response(200) end)

      assert body["patient"]["faltas"] == 0
      assert Enum.any?(sql_show, &(&1 =~ "attendances"))

      # As outras portas usam o MESMO lookup e não querem o número. O agregado vira um LATERAL
      # JOIN sobre `attendances` (medido: +67 buffers, ~0,9 ms por chamada, e a ficha resolve o
      # paciente 3×: ela, o histórico e os anexos). Pendurá-lo no lookup compartilhado fazia
      # todo mundo pagar por um dado que só uma tela lê — inclusive a ESCRITA.
      {_, sql_patch} =
        com_sql(fn ->
          conn
          |> patch(~p"/api/patients/#{p.id}", %{"tel" => "11999998888"})
          |> json_response(200)
        end)

      refute Enum.any?(sql_patch, &(&1 =~ "attendances"))
    end
  end

  # Captura o TEXTO das queries emitidas durante `fun` — o contador de linhas não distingue
  # "carregou o agregado" de "não carregou", porque o LATERAL viaja dentro da mesma query de
  # `patients`.
  defp com_sql(fun) do
    parent = self()
    ref = make_ref()

    handler = fn _e, _m, meta, _c -> send(parent, {ref, meta[:query]}) end
    :telemetry.attach({__MODULE__, ref, :sql}, [:api, :repo, :query], handler, nil)
    resultado = fun.()
    :telemetry.detach({__MODULE__, ref, :sql})

    {resultado, drenar_sql(ref, [])}
  end

  defp drenar_sql(ref, acc) do
    receive do
      {^ref, sql} -> drenar_sql(ref, [to_string(sql) | acc])
    after
      50 -> acc
    end
  end

  describe "PATCH /api/patients/:id" do
    test "atualiza parcialmente (200)", %{conn: conn, clinic: clinic} do
      p = create_patient(clinic, "Editar", %{tel: "(11) 90000-0000"})

      body =
        conn
        |> patch(~p"/api/patients/#{p.id}", %{"tel" => "(11) 98888-7777", "medico" => "Dr. Novo"})
        |> json_response(200)

      # Guardado em E.164 (a forma canônica que o opt-out e o envio comparam); a máscara volta
      # na tela, por `web/src/lib/telefone.ts`.
      assert body["patient"]["tel"] == "+5511988887777"
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
      recepcao = sessao_de_membro!(owner, clinic, :recepcao)

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
      recepcao = sessao_de_membro!(owner, clinic, :recepcao)

      assert base
             |> authed(recepcao)
             |> post(~p"/api/patients/#{p.id}/deactivate")
             |> json_response(403)
    end
  end

  # C13 / Frente 7: o histórico é a lista de PRESENÇAS do paciente, não de blocos — numa turma o
  # bloco pode estar concluído com a presença dele faltando.
  describe "GET /api/patients/:patient_id/history" do
    # `n` dias atrás, **recuando até cair em dia útil**. Sem o recuo isto é uma bomba-relógio de
    # calendário: `dias_atras/2` sempre cai no mesmo dia-da-semana de hoje, então a suíte inteira
    # ficava vermelha aos domingos com "A clínica não atende neste dia" — o seed do onboard abre
    # seg–sáb. Explodiu de verdade em 2026-07-26 (um domingo); passou verde no sábado anterior.
    defp dias_atras(n, hhmm) do
      data = Date.utc_today() |> Date.add(-n) |> recua_para_util()
      {:ok, dt} = Api.Scheduling.LocalTime.to_utc(data, hhmm, "America/Sao_Paulo")
      dt
    end

    defp recua_para_util(data) do
      if Date.day_of_week(data) == 7, do: Date.add(data, -1), else: data
    end

    defp sessao_para(clinic, owner, paciente, starts_at) do
      prof =
        Api.Directory.create_professional!("Dra. H", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

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

    # Bate-volta da Onda 3: o `limit` era aplicado com `Enum.take` DEPOIS de ler tudo — a ficha de
    # um paciente antigo trazia o histórico inteiro do banco para desenhar 50 cartões. O teste mede
    # as LINHAS que vêm do banco, não as devolvidas: é a diferença que o `Enum.take` esconde.
    test "não lê o histórico inteiro para devolver a página", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Muitas sessões")

      prof =
        Api.Directory.create_professional!("Dra. H", %{tel: Api.Generators.telefone_unico()},
          tenant: clinic.id,
          actor: owner
        )

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

      # 30 sessões; pedimos 5. Semeadas direto (o volume é o ponto do teste, não o expediente —
      # agendar pela ação esbarraria no fim de semana).
      for i <- 1..30 do
        {:ok, dt} =
          Api.Scheduling.LocalTime.to_utc(
            Date.add(Date.utc_today(), -i),
            "08:00",
            "America/Sao_Paulo"
          )

        appt =
          Ash.Seed.seed!(
            Api.Scheduling.Appointment,
            %{
              starts_at: dt,
              ends_at: DateTime.add(dt, 50 * 60, :second),
              professional_id: prof.id,
              appointment_type_id: tipo.id,
              status: :concluido,
              clinic_id: clinic.id
            },
            tenant: clinic.id
          )

        Ash.Seed.seed!(
          Api.Scheduling.Attendance,
          %{
            appointment_id: appt.id,
            patient_id: paciente.id,
            status: :concluida,
            clinic_id: clinic.id,
            session_starts_at: appt.starts_at
          },
          tenant: clinic.id
        )
      end

      {resp, linhas} =
        com_linhas("attendances", fn ->
          get(conn, "/api/patients/#{paciente.id}/history?limit=5")
        end)

      assert length(json_response(resp, 200)["sessions"]) == 5

      # 5 pedidas + 1 para saber se há mais. O teto é generoso de propósito (a leitura pode ter
      # mais de uma query); o que ele barra é ler as 30.
      assert linhas <= 12, "leu #{linhas} linhas de attendances para devolver 5"
    end

    # doc 56 — o histórico ordenava `desc` sem recorte de data, então uma sessão AGENDADA para
    # setembro aparecia no topo de "Histórico de atendimentos" com o selo "Previsto". Medido ao
    # vivo: as ~10 primeiras linhas de um paciente com pacote eram futuro. Pior, o teto de 50 era
    # gasto com elas — paciente com muita sessão marcada não enxergava o próprio passado.
    defp daqui_a(n, hhmm) do
      data = Date.utc_today() |> Date.add(n) |> avanca_para_util()
      {:ok, dt} = Api.Scheduling.LocalTime.to_utc(data, hhmm, "America/Sao_Paulo")
      dt
    end

    defp avanca_para_util(data) do
      if Date.day_of_week(data) == 7, do: Date.add(data, 1), else: data
    end

    test "o que ainda vai acontecer não entra no histórico", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Com sessão marcada")
      sessao_para(clinic, owner, paciente, dias_atras(7, "08:00"))
      sessao_para(clinic, owner, paciente, daqui_a(7, "09:00"))

      body = json_response(get(conn, "/api/patients/#{paciente.id}/history"), 200)

      assert [passada] = body["sessions"]
      assert [proxima] = body["upcoming"]
      assert passada["starts_at"] < proxima["starts_at"]
    end

    test "as próximas vêm da mais próxima para a mais distante", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Agenda cheia")
      sessao_para(clinic, owner, paciente, daqui_a(20, "08:00"))
      sessao_para(clinic, owner, paciente, daqui_a(3, "08:00"))

      body = json_response(get(conn, "/api/patients/#{paciente.id}/history"), 200)

      # o histórico é do mais novo para o mais velho; as próximas são o contrário — a pergunta
      # que o cartão responde é "quando ele volta?", e a resposta é a PRIMEIRA linha
      assert [primeira, segunda] = body["upcoming"]
      assert primeira["starts_at"] < segunda["starts_at"]
      assert body["upcoming_more"] == false
    end

    test "as próximas param em 5 e avisam que há mais", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Pacote longo")
      Enum.each(1..6, &sessao_para(clinic, owner, paciente, daqui_a(&1 * 2, "08:00")))

      body = json_response(get(conn, "/api/patients/#{paciente.id}/history"), 200)

      assert length(body["upcoming"]) == 5
      assert body["upcoming_more"] == true
    end

    test "paginando o histórico, as próximas não voltam junto", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      paciente = create_patient(clinic, "Segunda página")
      Enum.each(1..3, &sessao_para(clinic, owner, paciente, dias_atras(&1, "08:00")))
      sessao_para(clinic, owner, paciente, daqui_a(5, "08:00"))

      body =
        json_response(get(conn, "/api/patients/#{paciente.id}/history?limit=2&offset=2"), 200)

      # a segunda página do histórico é do histórico: recalcular as próximas seria trabalho de
      # banco para um cartão que já está desenhado na tela
      assert length(body["sessions"]) == 1
      assert body["upcoming"] == []
      assert body["upcoming_more"] == false
    end

    test "offset pula as sessões já mostradas", %{conn: conn, owner: owner, clinic: clinic} do
      paciente = create_patient(clinic, "Ver mais")
      Enum.each(1..3, &sessao_para(clinic, owner, paciente, dias_atras(&1, "08:00")))

      pagina1 = json_response(get(conn, "/api/patients/#{paciente.id}/history?limit=2"), 200)

      pagina2 =
        json_response(get(conn, "/api/patients/#{paciente.id}/history?limit=2&offset=2"), 200)

      ids = fn body -> Enum.map(body["sessions"], & &1["id"]) end

      assert length(ids.(pagina1)) == 2
      assert length(ids.(pagina2)) == 1
      assert ids.(pagina1) -- ids.(pagina2) == ids.(pagina1)
      assert pagina2["more"] == false
    end

    test "patient_id malformado não estoura 500", %{conn: conn} do
      # O mesmo id em `GET /patients/:id` degrada para 404 (o `fetchPatient` já tratava); a rota
      # nova entrava no read do Ash sem cast e subia `MatchError` — 500 na ficha.
      assert json_response(get(conn, "/api/patients/nao-e-uuid/history"), 404)["error"] ==
               "not_found"
    end

    test "exige autenticação", %{base_conn: base_conn} do
      assert json_response(get(base_conn, "/api/patients/#{Ash.UUID.generate()}/history"), 401)
    end
  end
end
