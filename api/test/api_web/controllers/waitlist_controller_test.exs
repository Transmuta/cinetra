defmodule ApiWeb.WaitlistControllerTest do
  @moduledoc """
  Endpoints da fila de espera (doc 25, Entrega 5 / doc 09 §3.6). Integração real: sessão +
  `LoadScope`, o CRUD com upsert por paciente, o motor `find_slots`, a oferta com **409
  `slot_held`** e a conversão. A escada 401/404/422 herda do `AppointmentsController`.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records

  defp email, do: "wl-#{System.unique_integer([:positive])}@example.com"

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

  defp as(user), do: authed(Phoenix.ConnTest.build_conn(), user)

  defp fixture do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)

    tipo =
      Directory.create_appointment_type!(
        %{
          nome: "Sessão #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Activity"
        },
        tenant: clinic.id,
        actor: owner
      )

    paciente = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)
    %{owner: owner, clinic: clinic, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp enqueue(ctx, overrides \\ %{}) do
    body = Map.merge(%{"patient_id" => ctx.paciente.id, "prio" => "normal"}, overrides)
    conn = as(ctx.owner) |> post("/api/waitlist", body)
    json_response(conn, 201)["entry"]
  end

  describe "POST /api/waitlist" do
    test "enfileira e devolve o item com regras, paciente e dias_na_fila" do
      ctx = fixture()

      entry =
        enqueue(ctx, %{
          "prio" => "urgente",
          "janela" => "manha",
          "obs" => "Dor aguda",
          "rules" => [%{"tipo" => "semana", "dows" => [1, 3], "periodos" => [["09:00", "11:00"]]}]
        })

      assert entry["prio"] == "urgente"
      assert entry["janela"] == "manha"
      assert entry["obs"] == "Dor aguda"
      assert entry["patient"]["nome"] == "Paciente"
      assert entry["dias_na_fila"] == 0
      assert [rule] = entry["rules"]
      assert rule["dows"] == [1, 3]
    end

    test "re-enfileirar o mesmo paciente edita (upsert)" do
      ctx = fixture()
      first = enqueue(ctx, %{"prio" => "normal"})
      second = enqueue(ctx, %{"prio" => "alta"})

      assert first["id"] == second["id"]
      assert second["prio"] == "alta"
      assert length(json_response(as(ctx.owner) |> get("/api/waitlist"), 200)["waitlist"]) == 1
    end

    test "sem sessão → 401" do
      ctx = fixture()

      conn =
        post(Phoenix.ConnTest.build_conn(), "/api/waitlist", %{"patient_id" => ctx.paciente.id})

      assert json_response(conn, 401)
    end
  end

  describe "GET /api/waitlist" do
    test "lista ordenada por prioridade + os profissionais" do
      ctx = fixture()
      p2 = Records.create_patient!("Outro", %{}, tenant: ctx.clinic.id, actor: ctx.owner)
      enqueue(ctx, %{"prio" => "baixa"})
      enqueue(Map.put(ctx, :paciente, p2), %{"prio" => "urgente"})

      body = json_response(as(ctx.owner) |> get("/api/waitlist"), 200)
      assert Enum.map(body["waitlist"], & &1["prio"]) == ["urgente", "baixa"]
      assert length(body["professionals"]) == 1
    end

    test "traz `today` (data local ISO) para a lista marcar regra expirada" do
      ctx = fixture()
      body = json_response(as(ctx.owner) |> get("/api/waitlist"), 200)
      assert {:ok, _} = Date.from_iso8601(body["today"])
    end
  end

  describe "PATCH / DELETE /api/waitlist/:id" do
    test "edita a prioridade" do
      ctx = fixture()
      entry = enqueue(ctx)
      conn = as(ctx.owner) |> patch("/api/waitlist/#{entry["id"]}", %{"prio" => "alta"})
      assert json_response(conn, 200)["entry"]["prio"] == "alta"
    end

    test "remove da fila → 204" do
      ctx = fixture()
      entry = enqueue(ctx)
      conn = as(ctx.owner) |> delete("/api/waitlist/#{entry["id"]}")
      assert response(conn, 204)
      assert json_response(as(ctx.owner) |> get("/api/waitlist"), 200)["waitlist"] == []
    end

    test "id inexistente → 404" do
      ctx = fixture()
      conn = as(ctx.owner) |> patch("/api/waitlist/#{Ecto.UUID.generate()}", %{"prio" => "alta"})
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/waitlist/:id/slots" do
    test "devolve as vagas do motor" do
      ctx = fixture()
      entry = enqueue(ctx)
      conn = as(ctx.owner) |> get("/api/waitlist/#{entry["id"]}/slots")
      body = json_response(conn, 200)
      assert is_list(body["slots"])
      assert Enum.all?(body["slots"], &Map.has_key?(&1, "professional_id"))
    end
  end

  describe "GET /api/waitlist/slots (batch)" do
    test "mapeia entry_id → vagas, e bate com o endpoint por-item" do
      ctx = fixture()
      p2 = Records.create_patient!("Outro", %{}, tenant: ctx.clinic.id, actor: ctx.owner)
      a = enqueue(ctx)
      b = enqueue(Map.put(ctx, :paciente, p2), %{"prio" => "alta"})

      body = json_response(as(ctx.owner) |> get("/api/waitlist/slots"), 200)
      by_entry = body["slots_by_entry"]

      assert Map.keys(by_entry) |> Enum.sort() == Enum.sort([a["id"], b["id"]])
      # A passada em lote é idêntica à do endpoint por-item (mesma fonte, `find_slots` delega).
      per_item =
        json_response(as(ctx.owner) |> get("/api/waitlist/#{a["id"]}/slots"), 200)["slots"]

      assert by_entry[a["id"]] == per_item
    end

    test "sem sessão → 401" do
      assert json_response(get(Phoenix.ConnTest.build_conn(), "/api/waitlist/slots"), 401)
    end
  end

  describe "POST /api/waitlist/:id/offer" do
    test "segura a vaga → 201; a segunda oferta sobreposta → 409 slot_held com meta" do
      ctx = fixture()
      entry = enqueue(ctx)
      body = %{"professional_id" => ctx.prof.id, "starts_at" => "2026-07-20T12:00:00Z"}

      conn = as(ctx.owner) |> post("/api/waitlist/#{entry["id"]}/offer", body)
      assert json_response(conn, 201)["hold"]["expires_at"]

      conn2 =
        as(ctx.owner)
        |> post("/api/waitlist/#{entry["id"]}/offer", %{
          "professional_id" => ctx.prof.id,
          "starts_at" => "2026-07-20T12:30:00Z"
        })

      body2 = json_response(conn2, 409)
      assert body2["code"] == "slot_held"
      assert body2["meta"]["held_by"]["id"] == ctx.owner.id
      assert body2["meta"]["expires_at"]
    end
  end

  describe "GET /api/waitlist/candidates" do
    test "devolve os itens compatíveis com a vaga; sem params → 422" do
      ctx = fixture()
      enqueue(ctx)

      conn =
        as(ctx.owner)
        |> get("/api/waitlist/candidates", %{
          "professional_id" => ctx.prof.id,
          "starts_at" => "2026-07-20T12:00:00Z",
          "ends_at" => "2026-07-20T12:50:00Z"
        })

      assert %{"candidates" => [c]} = json_response(conn, 200)
      assert c["patient"]["nome"] == "Paciente"

      assert json_response(as(ctx.owner) |> get("/api/waitlist/candidates"), 422)
    end
  end

  describe "POST /api/waitlist/:id/convert" do
    test "cria o agendamento e tira o paciente da fila" do
      ctx = fixture()
      entry = enqueue(ctx)

      conn =
        as(ctx.owner)
        |> post("/api/waitlist/#{entry["id"]}/convert", %{
          "starts_at" => "2026-07-20T12:00:00Z",
          "professional_id" => ctx.prof.id,
          "appointment_type_id" => ctx.tipo.id
        })

      assert %{"appointment" => appt} = json_response(conn, 201)
      assert appt["patient_ids"] == [ctx.paciente.id]
      assert json_response(as(ctx.owner) |> get("/api/waitlist"), 200)["waitlist"] == []
    end
  end
end
