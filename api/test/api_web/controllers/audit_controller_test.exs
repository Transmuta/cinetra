defmodule ApiWeb.AuditControllerTest do
  @moduledoc """
  `GET /api/audit` (doc 25 §11.4) — a fronteira HTTP da tela de auditoria. Integração real:
  sessão + `LoadScope`, o RBAC **owner·admin** (403 para recepção/profissional, não lista
  vazia) e o formato do JSON que o BFF consome.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling

  defp email, do: "audit-http-#{System.unique_integer([:positive])}@example.com"

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

  defp member_session(owner, clinic, papel, professional_id \\ nil) do
    addr = email()
    attrs = %{papel: papel, clinic_id: clinic.id, professional_id: professional_id}
    {:ok, pending} = Accounts.invite_member_by_email(addr, attrs, actor: owner)
    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, _} = Accounts.accept_invite(pending, actor: user)
    sign_in(addr)
  end

  # Uma clínica com um agendamento já cancelado — três versões na trilha (schedule/reschedule/
  # cancel), do owner. Devolve o escopo e o contexto para as asserções.
  defp fixture do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof = Directory.create_professional!("Dra. Bea", %{}, tenant: clinic.id, actor: owner)

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

    paciente = Records.create_patient!("Caio", %{}, tenant: clinic.id, actor: owner)
    scope = scope_for(owner, clinic)

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: ~U[2026-07-20 11:00:00Z],
          professional_id: prof.id,
          appointment_type_id: tipo.id,
          patient_ids: [paciente.id]
        },
        scope: scope
      )

    {:ok, _} =
      Scheduling.transition_appointment(scope, appt.id, :reschedule, %{
        starts_at: ~U[2026-07-20 12:00:00Z]
      })

    {:ok, _} = Scheduling.transition_appointment(scope, appt.id, :cancel, %{cancel_reason: "x"})

    %{owner: owner, clinic: clinic, prof: prof, paciente: paciente, appt: appt}
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  describe "GET /api/audit" do
    test "owner recebe 200 com o feed e a meta de página", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit")

      body = json_response(conn, 200)
      assert %{"entries" => entries, "page" => page} = body
      assert length(entries) == 3
      assert page["total"] == 3
      assert page["more"] == false

      # A entrada mais recente é o cancelamento: quem · quando · ação · registro · diff.
      [first | _] = entries
      assert first["resource"] == "appointment"
      assert first["action"] == "cancel"
      assert first["actor"]["nome"] == ctx.owner.nome
      assert first["professional"]["nome"] == "Dra. Bea"
      assert is_binary(first["at"])
      assert Enum.any?(first["diff"], &(&1["field"] == "status" and &1["to"] == "cancelado"))
    end

    test "admin também lê", %{conn: conn} do
      ctx = fixture()
      admin = member_session(ctx.owner, ctx.clinic, :admin)

      conn = conn |> authed(admin) |> get("/api/audit")
      assert %{"entries" => [_ | _]} = json_response(conn, 200)
    end

    test "recepção recebe 403 (não lista vazia)", %{conn: conn} do
      ctx = fixture()
      recepcao = member_session(ctx.owner, ctx.clinic, :recepcao)

      conn = conn |> authed(recepcao) |> get("/api/audit")
      assert json_response(conn, 403)
    end

    test "profissional recebe 403", %{conn: conn} do
      ctx = fixture()
      prof_user = member_session(ctx.owner, ctx.clinic, :profissional, ctx.prof.id)

      conn = conn |> authed(prof_user) |> get("/api/audit")
      assert json_response(conn, 403)
    end

    test "sem sessão é 401", %{conn: conn} do
      conn = get(conn, "/api/audit")
      assert json_response(conn, 401)
    end

    test "filtra por ação", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?action=cancel")

      assert %{"entries" => [entry]} = json_response(conn, 200)
      assert entry["action"] == "cancel"
    end

    test "resource=attendance devolve as versões de participante com o paciente", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?resource=attendance")

      body = json_response(conn, 200)
      assert Enum.all?(body["entries"], &(&1["resource"] == "attendance"))
      assert [entry | _] = body["entries"]
      assert entry["patient"]["nome"] == "Caio"
    end

    test "pagina por limit/offset", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?limit=2&offset=0")

      body = json_response(conn, 200)
      assert length(body["entries"]) == 2
      assert body["page"]["more"] == true
    end

    test "janela from/to malformada é 422", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?from=nao-e-data")

      assert json_response(conn, 422)
    end

    # Bate-volta (segurança, MÉDIO): um `record_id`/`user_id` não-uuid chegava cru no filtro de
    # coluna UUID e estourava `Ecto.Query.CastError` → HTTP 500. A fronteira valida como já faz
    # com `from`/`to` (422) e `limit`/`offset` (default) — nunca deixa o cast subir.
    test "record_id malformado (não-uuid) é 422, não 500", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?record_id=nao-e-uuid")
      assert json_response(conn, 422)
    end

    test "user_id malformado (não-uuid) é 422, não 500", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?user_id=xxx")
      assert json_response(conn, 422)
    end

    # Bate-volta (verificação): um offset gigante é absorvido pelo clamp (100k) — não chega cru
    # no Postgrex a ponto de estourar o int64 e virar 500. Mesma classe do 500 de uuid.
    test "offset absurdo é clampado, não 500", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?offset=999999999999")
      assert %{"entries" => []} = json_response(conn, 200)
    end

    # `to` anterior a `from` é 422 (a mesma regra de janela da agenda, via parse_window).
    test "janela invertida (to < from) é 422", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?from=2026-07-20&to=2026-07-19")
      assert json_response(conn, 422)
    end

    test "janela válida (from/to) recorta por QUANDO a mudança foi gravada", %{conn: conn} do
      ctx = fixture()

      # A janela é sobre `version_inserted_at` (quando a trilha registrou), não sobre a data do
      # agendamento — então gira em torno de "hoje", que é quando as três versões nasceram.
      hoje = Date.utc_today()
      ontem = Date.add(hoje, -1)
      amanha = Date.add(hoje, 1)

      conn = conn |> authed(ctx.owner) |> get("/api/audit?from=#{ontem}&to=#{amanha}")
      assert %{"entries" => [_, _, _]} = json_response(conn, 200)

      # Uma janela no passado distante não vê nada — a conversão local→UTC segurou a borda.
      conn2 = build_conn() |> authed(ctx.owner) |> get("/api/audit?from=2020-01-01&to=2020-01-02")
      assert %{"entries" => []} = json_response(conn2, 200)
    end

    test "filtra por registro (record_id) e por autor (user_id)", %{conn: conn} do
      ctx = fixture()

      conn = conn |> authed(ctx.owner) |> get("/api/audit?record_id=#{ctx.appt.id}")
      body = json_response(conn, 200)
      assert length(body["entries"]) == 3
      assert Enum.all?(body["entries"], &(&1["record_id"] == ctx.appt.id))

      conn2 = build_conn() |> authed(ctx.owner) |> get("/api/audit?user_id=#{ctx.owner.id}")
      assert %{"entries" => [_ | _]} = json_response(conn2, 200)
    end
  end
end
