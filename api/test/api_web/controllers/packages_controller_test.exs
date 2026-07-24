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

  defp email, do: "pkg-#{System.unique_integer([:positive])}@example.com"

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
          nome: "Pilates #{System.unique_integer([:positive])}",
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
  end
end
