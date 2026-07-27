defmodule ApiWeb.ProfessionalsControllerTest do
  @moduledoc """
  Endpoints do diretório de profissionais (fatia Profissionais). Integração real: sessão
  assinada + `LoadScope`, RBAC (leitura para todo membro, escrita só owner/admin), a escada
  401/403/404/422 e as superfícies de grade e exceções.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory

  defp owner_with_clinic do
    owner = sign_in!(email_unico("profc"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp create_prof(clinic, nome \\ "Dra. Marina", overrides \\ %{}) do
    Directory.create_professional!(nome, overrides, tenant: clinic.id, authorize?: false)
  end

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/professionals" do
    test "lista os profissionais e o expediente da clínica", %{conn: conn, clinic: clinic} do
      create_prof(clinic, "Dra. Marina", %{crefito: "C-1", sub: "Ortopedia"})

      body = conn |> get(~p"/api/professionals") |> json_response(200)

      assert [p] = body["professionals"]
      assert p["nome"] == "Dra. Marina"
      assert p["sub"] == "Ortopedia"
      # a grade vem carregada (vazia por ora) e o expediente da clínica vem junto.
      assert p["weekly_hours"] == []
      assert length(body["clinic_hours"]) == 7
    end

    test "o objeto não vaza clinic_id nem timestamps", %{conn: conn, clinic: clinic} do
      create_prof(clinic)
      body = conn |> get(~p"/api/professionals") |> json_response(200)
      [p | _] = body["professionals"]

      refute Map.has_key?(p, "clinic_id")
      refute Map.has_key?(p, "inserted_at")
    end
  end

  describe "POST /api/professionals" do
    test "cria com só o nome e devolve 201", %{conn: conn} do
      body =
        conn |> post(~p"/api/professionals", %{"nome" => "Dr. Novo"}) |> json_response(201)

      assert body["professional"]["nome"] == "Dr. Novo"
      assert body["professional"]["ativo"] == true
      assert body["professional"]["cor_indice"] == 1
    end

    test "nome vazio devolve 422", %{conn: conn} do
      body = conn |> post(~p"/api/professionals", %{"nome" => ""}) |> json_response(422)
      assert body["error"] == "invalid"
    end

    test "clinic_id no corpo é ignorado (vem do escopo)", %{conn: conn, clinic: clinic} do
      other = Ecto.UUID.generate()

      body =
        conn
        |> post(~p"/api/professionals", %{"nome" => "X", "clinic_id" => other})
        |> json_response(201)

      # foi criado na clínica do escopo, não na do corpo.
      prof =
        Directory.get_professional!(body["professional"]["id"],
          tenant: clinic.id,
          authorize?: false
        )

      assert prof.clinic_id == clinic.id
    end
  end

  describe "GET/PATCH /api/professionals/:id" do
    test "show traz a ficha com grade e exceções", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)
      body = conn |> get(~p"/api/professionals/#{prof.id}") |> json_response(200)

      assert body["professional"]["id"] == prof.id
      assert body["professional"]["weekly_hours"] == []
      assert body["professional"]["exceptions"] == []
    end

    test "update parcial", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body =
        conn
        |> patch(~p"/api/professionals/#{prof.id}", %{"sub" => "Pilates", "cor_indice" => 4})
        |> json_response(200)

      assert body["professional"]["sub"] == "Pilates"
      assert body["professional"]["cor_indice"] == 4
    end

    test "id de outra clínica é 404", %{conn: conn} do
      {other_owner, other_clinic} = owner_with_clinic()
      alheio = create_prof(other_clinic)
      _ = other_owner

      assert conn |> get(~p"/api/professionals/#{alheio.id}") |> json_response(404)
    end

    test "id malformado (não-UUID) → 404, não 500", %{conn: conn} do
      assert conn |> get(~p"/api/professionals/nao-e-uuid") |> json_response(404)
      assert conn |> get(~p"/api/professionals/123") |> json_response(404)
    end

    # P1 (2026-07-21): o recorte `OwnProfessionalOnly` vale também na ficha por id — um
    # profissional lê a própria (200) mas a do colega é indistinguível de inexistente (404),
    # sem vazar CPF/dados bancários. `list` idem: só a si.
    test "profissional lê a própria ficha, mas a do colega é 404", %{
      base_conn: base,
      owner: owner,
      clinic: clinic
    } do
      eu = create_prof(clinic, "Eu")
      colega = create_prof(clinic, "Colega")
      prof = sessao_de_membro!(owner, clinic, :profissional, eu.id)
      conn = authed(base, prof)

      assert conn |> get(~p"/api/professionals/#{eu.id}") |> json_response(200)
      assert conn |> get(~p"/api/professionals/#{colega.id}") |> json_response(404)

      %{"professionals" => lista} = conn |> get(~p"/api/professionals") |> json_response(200)
      assert Enum.map(lista, & &1["id"]) == [eu.id]
    end
  end

  describe "deactivate / reactivate" do
    test "arquiva e reativa", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body = conn |> post(~p"/api/professionals/#{prof.id}/deactivate") |> json_response(200)
      assert body["professional"]["ativo"] == false

      body = conn |> post(~p"/api/professionals/#{prof.id}/reactivate") |> json_response(200)
      assert body["professional"]["ativo"] == true
    end
  end

  describe "PATCH /api/professionals/:id/hours" do
    test "grava a grade com custom dentro do horário da clínica", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body =
        conn
        |> patch(~p"/api/professionals/#{prof.id}/hours", %{
          "days" => [%{"dow" => 1, "modo" => "custom", "periods" => [["09:00", "11:00"]]}]
        })
        |> json_response(200)

      assert [%{"dow" => 1, "modo" => "custom", "periods" => [["09:00", "11:00"]]}] =
               body["hours"]
    end

    test "custom fora do horário da clínica é 422", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body =
        conn
        |> patch(~p"/api/professionals/#{prof.id}/hours", %{
          "days" => [%{"dow" => 1, "modo" => "custom", "periods" => [["07:00", "09:00"]]}]
        })
        |> json_response(422)

      assert body["error"] == "invalid"
    end
  end

  describe "exceções de data do profissional" do
    test "cria e apaga uma folga", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      created =
        conn
        |> post(~p"/api/professionals/#{prof.id}/exceptions", %{
          "data" => "2026-08-10",
          "nome" => "Férias",
          "tipo" => "fechado"
        })
        |> json_response(201)

      exc_id = created["exception"]["id"]
      assert created["exception"]["tipo"] == "fechado"

      assert conn
             |> delete(~p"/api/professionals/#{prof.id}/exceptions/#{exc_id}")
             |> response(204)
    end

    test "não apaga a exceção de um profissional pelo :id de outro (404, escopo por dono)",
         %{conn: conn, clinic: clinic} do
      p1 = create_prof(clinic, "P1")
      p2 = create_prof(clinic, "P2")

      created =
        conn
        |> post(~p"/api/professionals/#{p1.id}/exceptions", %{
          "data" => "2026-08-10",
          "tipo" => "fechado"
        })
        |> json_response(201)

      exc_id = created["exception"]["id"]

      # pelo endpoint de P2, a exceção de P1 é indistinguível de inexistente → 404
      assert conn |> delete(~p"/api/professionals/#{p2.id}/exceptions/#{exc_id}") |> response(404)
      # e continua existindo: apagar pelo dono certo funciona
      assert conn |> delete(~p"/api/professionals/#{p1.id}/exceptions/#{exc_id}") |> response(204)
    end
  end

  describe "RBAC e sessão" do
    test "sem sessão devolve 401", %{base_conn: conn} do
      assert conn |> get(~p"/api/professionals") |> json_response(401)
    end

    test "recepção lê mas não escreve", %{base_conn: base, owner: owner, clinic: clinic} do
      recep = sessao_de_membro!(owner, clinic, :recepcao)
      conn = authed(base, recep)

      assert conn |> get(~p"/api/professionals") |> json_response(200)
      assert conn |> post(~p"/api/professionals", %{"nome" => "X"}) |> json_response(403)
    end
  end

  # Bate-volta da Onda 6 (doc 49) — a fronteira manda string, e o `modo` é escolha do cliente.
  describe "grade e folga pela fronteira (A3/D12 + doc 49)" do
    test "modo inventado devolve 422, não 500", %{conn: conn, owner: owner, clinic: clinic} do
      prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)
      _ = owner

      assert conn
             |> patch(~p"/api/professionals/#{prof.id}/hours", %{
               "days" => [%{"dow" => 1, "modo" => "modo_inexistente", "periods" => []}]
             })
             |> json_response(422)
    end

    test "modo ausente também é 422", %{conn: conn, owner: owner, clinic: clinic} do
      prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)
      _ = owner

      assert conn
             |> patch(~p"/api/professionals/#{prof.id}/hours", %{
               "days" => [%{"dow" => 1, "periods" => []}]
             })
             |> json_response(422)
    end

    # A quarta porta do gate. Estava tão morta quanto a da exceção da clínica pelo mesmo motivo
    # (a `data` chega string), e é por isso que este teste atravessa o router.
    test "folga sobre um dia com sessão marcada devolve 409", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      scope = escopo(owner, clinic)
      prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)

      tipo =
        Directory.create_appointment_type!(
          %{nome: "Sessão #{unico()}", duracao_minutos: 50, cor: "#0FB5A6", icon: "Activity"},
          tenant: clinic.id,
          actor: owner
        )

      paciente = Api.Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)

      {:ok, starts_at} =
        Api.Scheduling.LocalTime.to_utc(~D[2027-03-15], "14:00", "America/Sao_Paulo")

      {:ok, _appt} =
        Api.Scheduling.schedule_appointment(
          %{
            starts_at: starts_at,
            professional_id: prof.id,
            appointment_type_id: tipo.id,
            patient_ids: [paciente.id]
          },
          scope: scope
        )

      body =
        conn
        |> post(~p"/api/professionals/#{prof.id}/exceptions", %{
          "data" => "2027-03-15",
          "nome" => "Folga",
          "tipo" => "fechado",
          "periods" => []
        })
        |> json_response(409)

      assert body["code"] == "future_conflicts"
      assert [_] = body["meta"]["conflicts"]
    end
  end
end
