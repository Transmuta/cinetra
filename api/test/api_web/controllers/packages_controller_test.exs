defmodule ApiWeb.PackagesControllerTest do
  @moduledoc """
  Endpoints dos pacotes (Fatia 3, doc 09). Integração real: sessão + `LoadScope`, a prévia
  (save-gate), a criação com materialização (Oban `:manual`), a lista sob o paciente, e
  pausar/cancelar. A escada 401/404/422 herda do `AppointmentsController`.
  """
  use ApiWeb.ConnCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records

  @segunda "2026-07-20"

  defp fixture do
    owner = sign_in!(email_unico("pkg"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof =
      Directory.create_professional!("Dra. X", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    tipo =
      Directory.create_appointment_type!(
        %{
          nome: "Pilates #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Activity"
        },
        tenant: clinic.id,
        actor: owner
      )

    paciente =
      Records.create_patient!("Paciente", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    %{owner: owner, clinic: clinic, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp body(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        "nome" => "Pilates 4",
        "total" => 4,
        "falta_punitiva" => true,
        "cor" => "#0FB5A6",
        "data_inicio" => @segunda,
        "patient_id" => ctx.paciente.id,
        "appointment_type_id" => ctx.tipo.id,
        "grade" => %{
          "dows" => [1, 3],
          "horarios" => %{"1" => "08:00", "3" => "09:00"},
          "professional_id" => ctx.prof.id
        }
      },
      overrides
    )
  end

  describe "POST /api/packages/preview" do
    test "classifica a série sem escrever" do
      ctx = fixture()
      conn = as(ctx.owner) |> post("/api/packages/preview", body(ctx))

      resp = json_response(conn, 200)
      assert length(resp["ocorrencias"]) == 4
      assert resp["pode_salvar"] == true
      assert Enum.all?(resp["ocorrencias"], &(&1["issue"] == "ok"))
      # nada foi criado
      assert [] ==
               json_response(
                 as(ctx.owner) |> get("/api/patients/#{ctx.paciente.id}/packages"),
                 200
               )["packages"]
    end

    test "forma inválida (sem grade) → 400" do
      ctx = fixture()
      conn = as(ctx.owner) |> post("/api/packages/preview", Map.delete(body(ctx), "grade"))
      assert json_response(conn, 400)["error"] == "bad_request"
    end
  end

  describe "POST /api/packages" do
    test "cria o pacote, enfileira a materialização e devolve os derivados" do
      ctx = fixture()
      conn = as(ctx.owner) |> post("/api/packages", body(ctx))

      pkg = json_response(conn, 201)["package"]
      assert pkg["status"] == "ativo"
      assert pkg["total"] == 4
      assert pkg["restantes"] == 4
      assert pkg["grade"]["dows"] == [1, 3]

      assert_enqueued(worker: Api.Packages.Materializer, args: %{package_id: pkg["id"]})
    end

    # A cadeia inteira numa asserção só: header HTTP → Plug.RequestId → Logger.metadata →
    # Api.Correlacao → meta do job. É o teste que ATRAVESSA a fronteira; um teste de unidade do
    # `Correlacao` prova o helper e não prova que alguém o chamou no caminho real.
    test "o x-request-id do BFF atravessa até o meta do job (correlação, doc 62 §12)" do
      ctx = fixture()
      rid = "bff-0198cafe-4d2b-71a9-b3e0-5f1c8d7a6e04"

      conn =
        as(ctx.owner)
        |> Plug.Conn.put_req_header("x-request-id", rid)
        |> post("/api/packages", body(ctx))

      assert json_response(conn, 201)
      assert [job] = all_enqueued(worker: Api.Packages.Materializer)
      assert job.meta["request_id"] == rid
    end

    # A regra que o BFF precisa respeitar, fixada do lado que a impõe. O `Plug.RequestId` só
    # reaproveita o header quando `byte_size in 20..200`; abaixo disso ele descarta EM SILÊNCIO e
    # gera o próprio id. Sem este teste, um dia alguém encurta o id do BFF, tudo continua verde e
    # a correlação some sem sintoma.
    test "id fora da faixa 20..200 NÃO é reaproveitado — o Plug gera o dele" do
      ctx = fixture()

      conn =
        as(ctx.owner)
        |> Plug.Conn.put_req_header("x-request-id", "curto")
        |> post("/api/packages", body(ctx))

      assert json_response(conn, 201)
      assert [job] = all_enqueued(worker: Api.Packages.Materializer)
      assert job.meta["request_id"] != "curto"
      assert byte_size(job.meta["request_id"]) >= 20
    end

    test "grade fora do expediente → 422 series_blocked com a prévia" do
      ctx = fixture()

      fora =
        body(ctx, %{
          "grade" => %{
            "dows" => [0],
            "horarios" => %{"0" => "10:00"},
            "professional_id" => ctx.prof.id
          },
          "total" => 2
        })

      conn = as(ctx.owner) |> post("/api/packages", fora)
      resp = json_response(conn, 422)
      assert resp["error"] == "series_blocked"
      assert resp["reason"] == "fora_expediente"
      assert resp["preview"]["pode_salvar"] == false
    end

    test "exige autenticação" do
      ctx = fixture()
      conn = Phoenix.ConnTest.build_conn() |> post("/api/packages", body(ctx))
      assert json_response(conn, 401)
    end
  end

  describe "lista, pausar e cancelar" do
    defp criar(ctx) do
      conn = as(ctx.owner) |> post("/api/packages", body(ctx))
      json_response(conn, 201)["package"]
    end

    test "GET /api/patients/:id/packages lista os pacotes do paciente" do
      ctx = fixture()
      pkg = criar(ctx)

      lista =
        json_response(as(ctx.owner) |> get("/api/patients/#{ctx.paciente.id}/packages"), 200)[
          "packages"
        ]

      assert [%{"id" => id}] = lista
      assert id == pkg["id"]
    end

    # A trilha vem JUNTO da lista (doc 69 §7 item 9): é o que o cartão desenha em bolinhas, e
    # buscá-la por pacote seria um N+1 na abertura da ficha.
    test "GET /api/patients/:id/packages traz a trilha de cada pacote" do
      ctx = fixture()
      criar(ctx)
      Oban.drain_queue(queue: :housekeeping)

      [pacote] =
        json_response(as(ctx.owner) |> get("/api/patients/#{ctx.paciente.id}/packages"), 200)[
          "packages"
        ]

      assert length(pacote["sessoes"]) == 4
      assert Enum.all?(pacote["sessoes"], &is_binary(&1["estado"]))
      assert Enum.all?(pacote["sessoes"], &is_binary(&1["starts_at"]))
    end

    test "POST /api/packages/:id/pause vira o status" do
      ctx = fixture()
      pkg = criar(ctx)
      Oban.drain_queue(queue: :housekeeping)

      conn = as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/pause", %{})
      assert json_response(conn, 200)["package"]["status"] == "pausado"
    end

    test "POST /api/packages/:id/resume reprojeta e reativa" do
      ctx = fixture()
      pkg = criar(ctx)
      Oban.drain_queue(queue: :housekeeping)
      as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/pause", %{})

      conn = as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/resume", %{})
      assert json_response(conn, 200)["package"]["status"] == "ativo"
    end

    test "POST /api/packages/:id/cancel vira o status" do
      ctx = fixture()
      pkg = criar(ctx)
      Oban.drain_queue(queue: :housekeeping)

      conn = as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/cancel", %{})
      assert json_response(conn, 200)["package"]["status"] == "cancelado"
    end

    # D1 (doc 69 §10): arquivar é a ÚNICA porta para `:concluido`. A série precisa estar INTEIRA no
    # passado — o `@segunda` do `criar/1` é recente demais e ainda projeta uma sessão à frente.
    test "POST /api/packages/:id/archive marca concluído" do
      ctx = fixture()

      corpo =
        body(ctx, %{
          "data_inicio" => "2026-06-01",
          "total" => 2,
          "grade" => %{
            "dows" => [1],
            "horarios" => %{"1" => "08:00"},
            "professional_id" => ctx.prof.id
          }
        })

      pkg = json_response(as(ctx.owner) |> post("/api/packages", corpo), 201)["package"]
      Oban.drain_queue(queue: :housekeeping)

      conn = as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/archive", %{})
      assert json_response(conn, 200)["package"]["status"] == "concluido"
    end

    test "POST /api/packages/:id/archive recusa com 422 quando há sessão futura" do
      ctx = fixture()

      corpo =
        body(ctx, %{
          "data_inicio" => "2027-03-01",
          "total" => 2,
          "grade" => %{
            "dows" => [1],
            "horarios" => %{"1" => "08:00"},
            "professional_id" => ctx.prof.id
          }
        })

      pkg = json_response(as(ctx.owner) |> post("/api/packages", corpo), 201)["package"]
      Oban.drain_queue(queue: :housekeeping)

      conn = as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/archive", %{})
      assert json_response(conn, 422)["details"] != []

      # e o pacote não mudou de estado
      lista =
        json_response(as(ctx.owner) |> get("/api/patients/#{ctx.paciente.id}/packages"), 200)[
          "packages"
        ]

      assert [%{"status" => "ativo"}] = lista
    end
  end

  # O ciclo de vida reaberto (doc 69 §10 B4): o `+`/`−` do ADR-011, a grade e a trilha.
  describe "sessões e grade" do
    @futuro2 "2027-05-03"

    defp criar_serie_futura(ctx, total \\ 3) do
      corpo =
        body(ctx, %{
          "data_inicio" => @futuro2,
          "total" => total,
          "grade" => %{
            "dows" => [1],
            "horarios" => %{"1" => "08:00"},
            "professional_id" => ctx.prof.id
          }
        })

      pkg = json_response(as(ctx.owner) |> post("/api/packages", corpo), 201)["package"]
      Oban.drain_queue(queue: :housekeeping)
      pkg
    end

    test "POST /api/packages/:id/sessions soma uma sessão" do
      ctx = fixture()
      pkg = criar_serie_futura(ctx)

      conn = as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/sessions", %{})
      assert json_response(conn, 200)["package"]["total"] == 4
    end

    test "DELETE /api/packages/:id/sessions tira a última futura" do
      ctx = fixture()
      pkg = criar_serie_futura(ctx)

      conn = as(ctx.owner) |> delete("/api/packages/#{pkg["id"]}/sessions")
      assert json_response(conn, 200)["package"]["total"] == 2
    end

    test "DELETE recusa com 422 quando não há sessão futura (D3)" do
      ctx = fixture()
      # a série de `@segunda` (2026-07-20) já passou inteira: nada de futuro para tirar
      corpo =
        body(ctx, %{
          "data_inicio" => "2026-06-01",
          "total" => 2,
          "grade" => %{
            "dows" => [1],
            "horarios" => %{"1" => "08:00"},
            "professional_id" => ctx.prof.id
          }
        })

      pkg = json_response(as(ctx.owner) |> post("/api/packages", corpo), 201)["package"]
      Oban.drain_queue(queue: :housekeeping)

      conn = as(ctx.owner) |> delete("/api/packages/#{pkg["id"]}/sessions")
      assert json_response(conn, 422)["details"] != []
    end

    test "PATCH /api/packages/:id/grade troca a grade e remarca as futuras" do
      ctx = fixture()
      pkg = criar_serie_futura(ctx)

      conn =
        as(ctx.owner)
        |> patch("/api/packages/#{pkg["id"]}/grade", %{
          "dows" => [3],
          "horarios" => %{"3" => "10:00"},
          "professional_id" => ctx.prof.id
        })

      assert json_response(conn, 200)["package"]["grade"]["dows"] == [3]
    end

    test "PATCH /grade com grade vazia é 422, não 500" do
      ctx = fixture()
      pkg = criar_serie_futura(ctx)

      conn =
        as(ctx.owner)
        |> patch("/api/packages/#{pkg["id"]}/grade", %{"dows" => [], "horarios" => %{}})

      assert json_response(conn, 422)["details"] != []
    end

    test "GET /api/packages/:id/sessions devolve a trilha com o estado de cada sessão" do
      ctx = fixture()
      pkg = criar_serie_futura(ctx)

      conn = as(ctx.owner) |> get("/api/packages/#{pkg["id"]}/sessions")
      sessoes = json_response(conn, 200)["sessions"]

      assert length(sessoes) == 3
      assert Enum.map(sessoes, & &1["estado"]) == ["proxima", "agendada", "agendada"]
      assert Enum.all?(sessoes, &is_binary(&1["starts_at"]))
    end
  end

  describe "massa por pacote (doc 41 etapa 3)" do
    # A massa só alcança sessões futuras — o `@segunda` dos outros testes já passou.
    @futuro "2027-03-01"

    defp criar_futuro(ctx) do
      corpo =
        body(ctx, %{
          "data_inicio" => @futuro,
          "total" => 2,
          "grade" => %{
            "dows" => [1],
            "horarios" => %{"1" => "08:00"},
            "professional_id" => ctx.prof.id
          }
        })

      pkg = json_response(as(ctx.owner) |> post("/api/packages", corpo), 201)
      Oban.drain_queue(queue: :housekeeping)
      pkg["package"]
    end

    test "bulk_cancel devolve quantas sessões foram tocadas" do
      ctx = fixture()
      pkg = criar_futuro(ctx)

      conn =
        as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/bulk_cancel", %{"escopo" => "todas"})

      assert %{"afetadas" => 2, "package" => %{"id" => _}} = json_response(conn, 200)
    end

    test "bulk_adjust move o horário das sessões do escopo" do
      ctx = fixture()
      pkg = criar_futuro(ctx)

      conn =
        as(ctx.owner)
        |> post("/api/packages/#{pkg["id"]}/bulk_adjust", %{
          "escopo" => "todas",
          "aplicar_horario" => "true",
          "hhmm" => "09:00"
        })

      assert %{"afetadas" => 2} = json_response(conn, 200)

      # a agenda do dia mostra a sessão no horário novo
      dia =
        json_response(
          as(ctx.owner) |> get("/api/appointments?from=#{@futuro}&to=#{@futuro}"),
          200
        )["appointments"]

      assert [%{"starts_at" => starts_at}] = dia
      assert String.contains?(starts_at, "12:00")
    end

    test "sem escolher o que aplicar → 422" do
      ctx = fixture()
      pkg = criar_futuro(ctx)

      conn =
        as(ctx.owner) |> post("/api/packages/#{pkg["id"]}/bulk_adjust", %{"escopo" => "todas"})

      assert %{"error" => "invalid", "details" => [%{"message" => msg}]} =
               json_response(conn, 422)

      assert msg =~ "escolha o que aplicar"
    end

    test "pacote inexistente → 404" do
      ctx = fixture()

      conn =
        as(ctx.owner)
        |> post("/api/packages/#{Ash.UUID.generate()}/bulk_cancel", %{"escopo" => "todas"})

      assert json_response(conn, 404)["error"] == "not_found"
    end

    test "exige autenticação" do
      conn =
        post(
          Phoenix.ConnTest.build_conn(),
          "/api/packages/#{Ash.UUID.generate()}/bulk_cancel",
          %{}
        )

      assert json_response(conn, 401)
    end
  end
end
