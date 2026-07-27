defmodule ApiWeb.ClinicExceptionsControllerTest do
  @moduledoc """
  Endpoints das exceções de data da clínica (doc 22 §3). Integração real: sessão + `LoadScope`,
  RBAC e a escada 401/403/404/422.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Scheduling

  defp owner_with_clinic do
    owner = sign_in!(email_unico("exc"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp scope(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp fechado(overrides \\ %{}),
    do: Map.merge(%{data: ~D[2026-07-09], tipo: :fechado}, overrides)

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/clinic-exceptions" do
    test "lista vazia quando não há exceções", %{conn: conn} do
      body = conn |> get(~p"/api/clinic-exceptions") |> json_response(200)
      assert body["clinic_exceptions"] == []
    end

    test "lista as da clínica ordenadas por data", %{conn: conn, owner: owner, clinic: clinic} do
      Scheduling.create_clinic_exception(scope(owner, clinic), fechado(%{data: ~D[2026-07-24]}))
      Scheduling.create_clinic_exception(scope(owner, clinic), fechado(%{data: ~D[2026-07-09]}))

      body = conn |> get(~p"/api/clinic-exceptions") |> json_response(200)

      assert Enum.map(body["clinic_exceptions"], & &1["data"]) == ["2026-07-09", "2026-07-24"]
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> get(~p"/api/clinic-exceptions") |> json_response(401)
    end

    test "qualquer membro lê (recepção, 200)", %{
      base_conn: base_conn,
      owner: owner,
      clinic: clinic
    } do
      recep = sessao_de_membro!(owner, clinic, :recepcao)
      body = base_conn |> authed(recep) |> get(~p"/api/clinic-exceptions") |> json_response(200)
      assert body["clinic_exceptions"] == []
    end
  end

  describe "POST /api/clinic-exceptions" do
    test "cria dia fechado (201)", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{
          data: "2026-07-09",
          nome: "Feriado",
          tipo: "fechado"
        })
        |> json_response(201)

      assert %{"data" => "2026-07-09", "nome" => "Feriado", "tipo" => "fechado", "periods" => []} =
               body["clinic_exception"]

      assert is_binary(body["clinic_exception"]["id"])
    end

    test "cria horário especial com períodos (201)", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{
          data: "2026-07-24",
          nome: "Reduzido",
          tipo: "horario",
          periods: [["08:00", "12:00"]]
        })
        |> json_response(201)

      assert body["clinic_exception"]["tipo"] == "horario"
      assert body["clinic_exception"]["periods"] == [["08:00", "12:00"]]
    end

    test "o objeto não vaza clinic_id/professional_id/timestamps", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{data: "2026-07-09", tipo: "fechado"})
        |> json_response(201)

      assert Enum.sort(Map.keys(body["clinic_exception"])) == ~w(data id nome periods tipo)
    end

    test "IGNORA professional_id do corpo — a rota é da clínica", %{conn: conn, clinic: clinic} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{
          data: "2026-07-09",
          tipo: "fechado",
          professional_id: Ecto.UUID.generate()
        })
        |> json_response(201)

      # nasceu como exceção da clínica (aparece na listagem, que filtra professional_id nulo).
      _ = clinic
      listadas = conn |> get(~p"/api/clinic-exceptions") |> json_response(200)

      assert Enum.any?(
               listadas["clinic_exceptions"],
               &(&1["id"] == body["clinic_exception"]["id"])
             )
    end

    test "data duplicada devolve 422 (H3)", %{conn: conn} do
      conn |> post(~p"/api/clinic-exceptions", %{data: "2026-12-25", tipo: "fechado"})

      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{data: "2026-12-25", tipo: "fechado", nome: "Outra"})
        |> json_response(422)

      assert body["error"] == "invalid"
    end

    test "horário sem períodos devolve 422", %{conn: conn} do
      assert conn
             |> post(~p"/api/clinic-exceptions", %{data: "2026-07-24", tipo: "horario"})
             |> json_response(422)
    end

    test "recepção não cria (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> post(~p"/api/clinic-exceptions", %{data: "2026-07-09", tipo: "fechado"})
             |> json_response(403)
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn
             |> post(~p"/api/clinic-exceptions", %{data: "2026-07-09", tipo: "fechado"})
             |> json_response(401)
    end
  end

  describe "DELETE /api/clinic-exceptions/:id" do
    test "apaga e devolve 204", %{conn: conn, owner: owner, clinic: clinic} do
      {:ok, exc} = Scheduling.create_clinic_exception(scope(owner, clinic), fechado())

      assert conn |> delete(~p"/api/clinic-exceptions/#{exc.id}") |> response(204)

      assert conn
             |> get(~p"/api/clinic-exceptions")
             |> json_response(200)
             |> Map.get("clinic_exceptions") == []
    end

    test "id inexistente devolve 404", %{conn: conn} do
      assert conn
             |> delete(~p"/api/clinic-exceptions/#{Ecto.UUID.generate()}")
             |> json_response(404)
    end

    test "exceção de outra clínica devolve 404 (isolamento)", %{conn: conn} do
      other = sign_in!(email_unico("exc"))

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      {:ok, alheia} = Scheduling.create_clinic_exception(scope(other, other_clinic), fechado())

      assert conn |> delete(~p"/api/clinic-exceptions/#{alheia.id}") |> json_response(404)
    end

    test "recepção não apaga (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      {:ok, exc} = Scheduling.create_clinic_exception(scope(owner, clinic), fechado())
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> delete(~p"/api/clinic-exceptions/#{exc.id}")
             |> json_response(403)
    end
  end

  # A3/D12 pela fronteira — e o bate-volta da Onda 6 (doc 49) mora aqui.
  #
  # O gate **existia e não disparava**: a `data` chega como string ("2027-03-15") e o
  # agendamento tem `%Date{}`, então a comparação era sempre falsa e a exceção era criada por
  # cima da agenda (201 no lugar de 409). Os testes de domínio passavam `Date` e não viam.
  # Toda regra que atravessa a fronteira precisa de um teste QUE ATRAVESSE a fronteira.
  describe "POST /api/clinic-exceptions — conflitos futuros (A3/D12)" do
    setup %{owner: owner, clinic: clinic} do
      scope = escopo(owner, clinic)
      prof = Api.Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)

      tipo =
        Api.Directory.create_appointment_type!(
          %{nome: "Sessão #{unico()}", duracao_minutos: 50, cor: "#0FB5A6", icon: "Activity"},
          tenant: clinic.id,
          actor: owner
        )

      paciente = Api.Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)

      {:ok, starts_at} =
        Api.Scheduling.LocalTime.to_utc(~D[2027-03-15], "14:00", "America/Sao_Paulo")

      {:ok, appt} =
        Api.Scheduling.schedule_appointment(
          %{
            starts_at: starts_at,
            professional_id: prof.id,
            appointment_type_id: tipo.id,
            patient_ids: [paciente.id]
          },
          scope: scope
        )

      %{appt: appt}
    end

    test "feriado sobre um dia com agenda devolve 409 com a lista", ctx do
      body =
        ctx.conn
        |> post(~p"/api/clinic-exceptions", %{
          "data" => "2027-03-15",
          "nome" => "Feriado",
          "tipo" => "fechado",
          "periods" => []
        })
        |> json_response(409)

      assert body["code"] == "future_conflicts"
      assert [conflito] = body["meta"]["conflicts"]
      assert conflito["appointment_id"] == ctx.appt.id
      assert conflito["reason"] == "sem_atendimento"

      # E nada foi criado.
      assert %{"clinic_exceptions" => []} =
               ctx.conn |> get(~p"/api/clinic-exceptions") |> json_response(200)
    end

    test "com confirm cria assim mesmo", ctx do
      assert ctx.conn
             |> post(~p"/api/clinic-exceptions", %{
               "data" => "2027-03-15",
               "nome" => "Feriado",
               "tipo" => "fechado",
               "periods" => [],
               "confirm" => true
             })
             |> json_response(201)
    end

    test "exceção em dia SEM agenda cria direto", ctx do
      assert ctx.conn
             |> post(~p"/api/clinic-exceptions", %{
               "data" => "2027-03-16",
               "nome" => "Feriado",
               "tipo" => "fechado",
               "periods" => []
             })
             |> json_response(201)
    end

    # O segundo achado do doc 49: `String.to_existing_atom` sobre valor do cliente derrubava a
    # request com 500. O gate se abstém e a validação do recurso responde o 422 de sempre.
    test "tipo inventado continua 422, não 500", ctx do
      assert ctx.conn
             |> post(~p"/api/clinic-exceptions", %{
               "data" => "2027-03-15",
               "nome" => "Xpto",
               "tipo" => "nao_existe",
               "periods" => []
             })
             |> json_response(422)
    end
  end
end
