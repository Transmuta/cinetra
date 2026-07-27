defmodule ApiWeb.ClinicHoursControllerTest do
  @moduledoc """
  Endpoints do horário semanal da clínica (doc 22 §3). Integração real: sessão + `LoadScope`,
  RBAC (leitura para todo membro, escrita só owner/admin) e a escada 401/403/422.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts

  defp owner_with_clinic do
    owner = sign_in!(email_unico("hours"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/clinic-hours" do
    test "devolve o expediente seedado como mapa dow→períodos", %{conn: conn} do
      body = conn |> get(~p"/api/clinic-hours") |> json_response(200)
      hours = body["clinic_hours"]

      assert map_size(hours) == 7
      assert hours["1"] == [["08:00", "12:00"], ["13:00", "18:00"]]
      assert hours["6"] == [["08:00", "12:00"]]
      assert hours["0"] == []
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> get(~p"/api/clinic-hours") |> json_response(401)
    end

    test "autenticado sem clínica ativa devolve 403", %{base_conn: base_conn} do
      orphan = sign_in!(email_unico("hours"))
      assert base_conn |> authed(orphan) |> get(~p"/api/clinic-hours") |> json_response(403)
    end

    test "qualquer membro lê (recepção, 200)", %{
      base_conn: base_conn,
      owner: owner,
      clinic: clinic
    } do
      recep = sessao_de_membro!(owner, clinic, :recepcao)
      body = base_conn |> authed(recep) |> get(~p"/api/clinic-hours") |> json_response(200)
      assert map_size(body["clinic_hours"]) == 7
    end

    test "não vaza o expediente de outra clínica", %{conn: conn} do
      other = sign_in!(email_unico("hours"))

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      # muda a outra clínica; a nossa continua no seed.
      Api.Scheduling.update_clinic_hours(scope(other, other_clinic), %{1 => [["06:00", "07:00"]]})

      body = conn |> get(~p"/api/clinic-hours") |> json_response(200)
      assert body["clinic_hours"]["1"] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end
  end

  describe "PATCH /api/clinic-hours" do
    test "owner substitui os dias enviados (200)", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/clinic-hours", %{clinic_hours: %{"1" => [["09:00", "17:00"]], "0" => []}})
        |> json_response(200)

      assert body["clinic_hours"]["1"] == [["09:00", "17:00"]]
      # dia não enviado mantém o seed.
      assert body["clinic_hours"]["6"] == [["08:00", "12:00"]]
    end

    test "ignora chaves fora de 0..6 e o confirm (whitelist)", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/clinic-hours", %{
          clinic_hours: %{"9" => [["06:00", "07:00"]], "2" => [["10:00", "11:00"]]},
          confirm: true
        })
        |> json_response(200)

      assert body["clinic_hours"]["2"] == [["10:00", "11:00"]]
      refute Map.has_key?(body["clinic_hours"], "9")
    end

    test "períodos inválidos devolvem 422 sem aplicar nada", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/clinic-hours", %{
          clinic_hours: %{"1" => [["09:00", "17:00"]], "2" => [["18:00", "08:00"]]}
        })
        |> json_response(422)

      assert body["error"] == "invalid"
      # o dia 1 não foi tocado (validação da semana inteira antes de escrever).
      novo = conn |> get(~p"/api/clinic-hours") |> json_response(200)
      assert novo["clinic_hours"]["1"] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end

    test "recepção não escreve (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> patch(~p"/api/clinic-hours", %{clinic_hours: %{"1" => [["09:00", "10:00"]]}})
             |> json_response(403)
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn
             |> patch(~p"/api/clinic-hours", %{clinic_hours: %{"1" => []}})
             |> json_response(401)
    end
  end

  defp scope(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  # A3/D12 — a fronteira do gate de conflitos futuros. O motor tem teste próprio
  # (`ImpactAnalysisTest`) e o gate também (`FutureConflictsTest`); aqui prova-se o **contrato
  # HTTP**: o 409 com `code` estável e a lista no `meta`, e o `confirm` que passa por cima.
  describe "PATCH /api/clinic-hours — conflitos futuros (A3/D12)" do
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

      # Uma segunda-feira bem no futuro, às 14h — fora da janela 08–12 que o teste vai propor.
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

      %{appt: appt, prof: prof, paciente: paciente}
    end

    test "encurtar a segunda devolve 409 com a lista dos afetados", ctx do
      body =
        ctx.conn
        |> patch(~p"/api/clinic-hours", %{"clinic_hours" => %{"1" => [["08:00", "12:00"]]}})
        |> json_response(409)

      assert body["error"] == "conflict"
      assert body["code"] == "future_conflicts"

      assert [conflito] = body["meta"]["conflicts"]
      assert conflito["appointment_id"] == ctx.appt.id
      assert conflito["date"] == "2027-03-15"
      assert conflito["hora"] == "14:00"
      assert conflito["reason"] == "fora_do_expediente"
      # A tela desenha nome, não uuid.
      assert conflito["professional"]["nome"] == "Dra. X"
      assert conflito["patients"] == ["Paciente"]
      refute body["meta"]["truncado"]
    end

    test "e NADA foi gravado — o gate bloqueia, não avisa", ctx do
      ctx.conn
      |> patch(~p"/api/clinic-hours", %{"clinic_hours" => %{"1" => [["08:00", "12:00"]]}})

      hours = ctx.conn |> get(~p"/api/clinic-hours") |> json_response(200)
      assert hours["clinic_hours"]["1"] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end

    test "com confirm: true aplica assim mesmo", ctx do
      body =
        ctx.conn
        |> patch(~p"/api/clinic-hours", %{
          "clinic_hours" => %{"1" => [["08:00", "12:00"]]},
          "confirm" => true
        })
        |> json_response(200)

      assert body["clinic_hours"]["1"] == [["08:00", "12:00"]]
    end

    test "só o booleano true confirma — string qualquer não passa o gate", ctx do
      assert ctx.conn
             |> patch(~p"/api/clinic-hours", %{
               "clinic_hours" => %{"1" => [["08:00", "12:00"]]},
               "confirm" => "sim"
             })
             |> json_response(409)
    end

    test "mudança que não quebra nada continua salvando direto", ctx do
      body =
        ctx.conn
        |> patch(~p"/api/clinic-hours", %{"clinic_hours" => %{"1" => [["08:00", "20:00"]]}})
        |> json_response(200)

      assert body["clinic_hours"]["1"] == [["08:00", "20:00"]]
    end
  end
end
