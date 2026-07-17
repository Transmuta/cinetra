defmodule ApiWeb.AppointmentTypesControllerTest do
  @moduledoc """
  Endpoints do catálogo de tipos de atendimento (doc 20 §3). Integração real: sessão
  assinada + `LoadScope` resolvendo o tenant ativo, RBAC (leitura para todo membro, escrita
  só owner/admin) e a escada de erros 401/403/404/422 do `MembersController`.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory

  defp email, do: "tipos-#{System.unique_integer([:positive])}@example.com"

  # Sign-in de domínio (retorna o User com token de sessão em metadata).
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

  # Convida, ativa e devolve a SESSÃO real de um membro (para exercer o RBAC do controller).
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

  defp create_tipo(clinic, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          nome: "Tipo #{System.unique_integer([:positive])}",
          duracao_minutos: 45,
          cor: "#0072B2",
          icon: "Activity"
        },
        overrides
      )

    Directory.create_appointment_type!(attrs, tenant: clinic.id, authorize?: false)
  end

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/appointment-types" do
    test "lista o catálogo seedado com a sigla derivada", %{conn: conn} do
      body = conn |> get(~p"/api/appointment-types") |> json_response(200)

      assert [avaliacao | _] = body["appointment_types"]

      assert %{
               "nome" => "Avaliação",
               "sigla" => "AVA",
               "duracao_minutos" => 50,
               "cor" => "#0072B2",
               "icon" => "ClipboardList",
               "grupo" => false,
               "capacidade" => nil,
               "ativo" => true
             } = avaliacao

      assert is_binary(avaliacao["id"])
      assert Enum.map(body["appointment_types"], & &1["sigla"]) == ~w(AVA SES RPG PIL REA)
    end

    test "o objeto não vaza o clinic_id nem timestamps internos", %{conn: conn} do
      body = conn |> get(~p"/api/appointment-types") |> json_response(200)
      [tipo | _] = body["appointment_types"]

      assert Map.keys(tipo) |> Enum.sort() ==
               ~w(ativo capacidade cor duracao_minutos grupo icon id nome sigla)
    end

    # O `cap_turma_padrao` viaja junto do GET porque é o default do campo Capacidade no modal
    # e nenhum outro endpoint o expõe (doc 20 §3). Irmão de `appointment_types`, no molde do
    # `{members, professionals}` do MembersController.
    test "traz o cap_turma_padrao da clínica junto do catálogo", %{conn: conn} do
      body = conn |> get(~p"/api/appointment-types") |> json_response(200)

      assert body["cap_turma_padrao"] == 4
    end

    test "o cap_turma_padrao reflete a clínica, não uma constante", %{conn: conn, clinic: clinic} do
      Accounts.update_clinic_settings!(clinic, %{cap_turma_padrao: 9}, authorize?: false)

      body = conn |> get(~p"/api/appointment-types") |> json_response(200)

      assert body["cap_turma_padrao"] == 9
    end

    test "traz ativos E arquivados (a tela é que separa)", %{conn: conn, clinic: clinic} do
      tipo = create_tipo(clinic, %{nome: "Arquivado"})
      Directory.archive_appointment_type!(tipo, %{}, tenant: clinic.id, authorize?: false)

      body = conn |> get(~p"/api/appointment-types") |> json_response(200)
      arquivado = Enum.find(body["appointment_types"], &(&1["nome"] == "Arquivado"))

      assert arquivado["ativo"] == false
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> get(~p"/api/appointment-types") |> json_response(401)
    end

    test "autenticado sem clínica ativa devolve 403", %{base_conn: base_conn} do
      orphan = sign_in(email())

      assert base_conn |> authed(orphan) |> get(~p"/api/appointment-types") |> json_response(403)
    end

    test "qualquer membro lê (recepção, 200)", %{
      base_conn: base_conn,
      owner: owner,
      clinic: clinic
    } do
      recep = active_member_session(owner, clinic, :recepcao)

      body = base_conn |> authed(recep) |> get(~p"/api/appointment-types") |> json_response(200)

      assert length(body["appointment_types"]) == 5
    end

    test "não vaza o catálogo de outra clínica", %{conn: conn} do
      other = sign_in(email())

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      create_tipo(other_clinic, %{nome: "Segredo da outra"})

      body = conn |> get(~p"/api/appointment-types") |> json_response(200)

      refute "Segredo da outra" in Enum.map(body["appointment_types"], & &1["nome"])
    end
  end

  describe "POST /api/appointment-types" do
    test "cria e devolve 201 com a sigla", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/appointment-types", %{
          nome: "Drenagem",
          duracao_minutos: 40,
          cor: "#E69F00",
          icon: "Hand"
        })
        |> json_response(201)

      assert %{
               "nome" => "Drenagem",
               "sigla" => "DRE",
               "duracao_minutos" => 40,
               "cor" => "#E69F00",
               "icon" => "Hand",
               "grupo" => false,
               "capacidade" => nil,
               "ativo" => true
             } = body["appointment_type"]
    end

    test "cria tipo em grupo com capacidade", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/appointment-types", %{
          nome: "Turma",
          duracao_minutos: 60,
          cor: "#2B7FFF",
          icon: "Users",
          grupo: true,
          capacidade: 6
        })
        |> json_response(201)

      assert body["appointment_type"]["grupo"] == true
      assert body["appointment_type"]["capacidade"] == 6
    end

    test "IGNORA clinic_id do corpo — o tenant vem do escopo (09 §8)",
         %{conn: conn, clinic: clinic} do
      other = sign_in(email())

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Alvo #{System.unique_integer([:positive])}", %{}, actor: other)

      body =
        conn
        |> post(~p"/api/appointment-types", %{
          nome: "Injetado",
          duracao_minutos: 30,
          cor: "#0072B2",
          icon: "Bone",
          clinic_id: other_clinic.id
        })
        |> json_response(201)

      # nasceu na clínica da SESSÃO, não na do corpo.
      criado =
        Directory.get_appointment_type!(body["appointment_type"]["id"],
          tenant: clinic.id,
          authorize?: false
        )

      assert criado.clinic_id == clinic.id

      nomes_alvo =
        [tenant: other_clinic.id, authorize?: false]
        |> Directory.list_appointment_types!()
        |> Enum.map(& &1.nome)

      refute "Injetado" in nomes_alvo
    end

    test "recepção não cria (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = active_member_session(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> post(~p"/api/appointment-types", %{
               nome: "Proibido",
               duracao_minutos: 30,
               cor: "#0072B2",
               icon: "Activity"
             })
             |> json_response(403)
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> post(~p"/api/appointment-types", %{nome: "X"}) |> json_response(401)
    end

    test "nome repetido devolve 422 apontando o campo `nome`", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/appointment-types", %{
          nome: "Sessão",
          duracao_minutos: 30,
          cor: "#0072B2",
          icon: "Activity"
        })
        |> json_response(422)

      assert body["error"] == "invalid"
      # O modal precisa saber QUAL input marcar. O erro de identity é `InvalidChanges`, que
      # traz `fields: [:nome]` (plural) e `field: nil` — sem o fallback, o 422 mais
      # importante da tela (T7) chegaria com field null.
      assert [%{"field" => "nome", "message" => message}] = body["details"]
      assert message =~ "já existe um tipo com esse nome"
    end

    test "cor fora da paleta devolve 422", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/appointment-types", %{
          nome: "Cor errada",
          duracao_minutos: 30,
          cor: "#BADA55",
          icon: "Activity"
        })
        |> json_response(422)

      assert body["error"] == "invalid"
    end

    test "ícone fora da paleta devolve 422", %{conn: conn} do
      assert conn
             |> post(~p"/api/appointment-types", %{
               nome: "Ícone errado",
               duracao_minutos: 30,
               cor: "#0072B2",
               icon: "Skull"
             })
             |> json_response(422)
    end

    test "grupo sem capacidade devolve 422", %{conn: conn} do
      assert conn
             |> post(~p"/api/appointment-types", %{
               nome: "Turma sem teto",
               duracao_minutos: 30,
               cor: "#0072B2",
               icon: "Users",
               grupo: true
             })
             |> json_response(422)
    end

    test "duração fora da faixa devolve 422", %{conn: conn} do
      assert conn
             |> post(~p"/api/appointment-types", %{
               nome: "Eterno",
               duracao_minutos: 999,
               cor: "#0072B2",
               icon: "Activity"
             })
             |> json_response(422)
    end

    test "corpo vazio devolve 422", %{conn: conn} do
      assert conn |> post(~p"/api/appointment-types", %{}) |> json_response(422)
    end
  end

  describe "PATCH /api/appointment-types/:id" do
    test "atualiza parcialmente (só o nome)", %{conn: conn, clinic: clinic} do
      tipo = create_tipo(clinic, %{nome: "Antigo", duracao_minutos: 45})

      body =
        conn
        |> patch(~p"/api/appointment-types/#{tipo.id}", %{nome: "Novo nome"})
        |> json_response(200)

      assert body["appointment_type"]["nome"] == "Novo nome"
      # a sigla acompanha o nome (derivada), e o resto não se mexe.
      assert body["appointment_type"]["sigla"] == "NOV"
      assert body["appointment_type"]["duracao_minutos"] == 45
    end

    test "id inexistente devolve 404", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/appointment-types/#{Ecto.UUID.generate()}", %{nome: "X"})
        |> json_response(404)

      assert body["error"] == "not_found"
    end

    test "tipo de outra clínica devolve 404 (isolamento)", %{conn: conn} do
      other = sign_in(email())

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      alheio = create_tipo(other_clinic)

      body =
        conn
        |> patch(~p"/api/appointment-types/#{alheio.id}", %{nome: "Invadido"})
        |> json_response(404)

      assert body["error"] == "not_found"
    end

    # O doc 20 fixa 404 para "inexistente ou fora do tenant" e 422 para "invalid", mas não
    # diz o que fazer com um id que nem é UUID. O Ash devolve `InvalidArgument` (não
    # `NotFound`), então a escada — a mesma do MembersController, que se comporta assim
    # hoje para `PATCH /api/members/nao-e-uuid` — cai em 422. Fica documentado aqui para o
    # comportamento não mudar por acidente.
    test "id malformado devolve 422 (não é NotFound — espelha o MembersController)",
         %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/appointment-types/nao-e-uuid", %{nome: "X"})
        |> json_response(422)

      assert body["error"] == "invalid"
    end

    test "recepção não atualiza (403)",
         %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = active_member_session(owner, clinic, :recepcao)
      tipo = create_tipo(clinic)

      assert base_conn
             |> authed(recep)
             |> patch(~p"/api/appointment-types/#{tipo.id}", %{nome: "Hackeado"})
             |> json_response(403)
    end

    test "nome duplicado devolve 422", %{conn: conn, clinic: clinic} do
      tipo = create_tipo(clinic)

      assert conn
             |> patch(~p"/api/appointment-types/#{tipo.id}", %{nome: "Pilates"})
             |> json_response(422)
    end
  end

  describe "POST /api/appointment-types/:id/archive" do
    test "arquiva e devolve o objeto (200)", %{conn: conn, clinic: clinic} do
      tipo = create_tipo(clinic)

      body =
        conn |> post(~p"/api/appointment-types/#{tipo.id}/archive") |> json_response(200)

      assert body["appointment_type"]["ativo"] == false
      assert body["appointment_type"]["id"] == tipo.id
    end

    test "recepção não arquiva (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = active_member_session(owner, clinic, :recepcao)
      tipo = create_tipo(clinic)

      assert base_conn
             |> authed(recep)
             |> post(~p"/api/appointment-types/#{tipo.id}/archive")
             |> json_response(403)
    end

    test "id inexistente devolve 404", %{conn: conn} do
      assert conn
             |> post(~p"/api/appointment-types/#{Ecto.UUID.generate()}/archive")
             |> json_response(404)
    end

    test "sem sessão devolve 401", %{base_conn: base_conn, clinic: clinic} do
      tipo = create_tipo(clinic)

      assert base_conn
             |> post(~p"/api/appointment-types/#{tipo.id}/archive")
             |> json_response(401)
    end
  end

  describe "POST /api/appointment-types/:id/restore" do
    test "restaura e devolve o objeto (200)", %{conn: conn, clinic: clinic} do
      tipo = create_tipo(clinic)
      Directory.archive_appointment_type!(tipo, %{}, tenant: clinic.id, authorize?: false)

      body =
        conn |> post(~p"/api/appointment-types/#{tipo.id}/restore") |> json_response(200)

      assert body["appointment_type"]["ativo"] == true
    end

    test "restaurar tipo já ativo é idempotente (200)", %{conn: conn, clinic: clinic} do
      tipo = create_tipo(clinic)

      body = conn |> post(~p"/api/appointment-types/#{tipo.id}/restore") |> json_response(200)

      assert body["appointment_type"]["ativo"] == true
    end

    test "recepção não restaura (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = active_member_session(owner, clinic, :recepcao)
      tipo = create_tipo(clinic)

      assert base_conn
             |> authed(recep)
             |> post(~p"/api/appointment-types/#{tipo.id}/restore")
             |> json_response(403)
    end

    test "tipo de outra clínica devolve 404 (isolamento)", %{conn: conn} do
      other = sign_in(email())

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      alheio = create_tipo(other_clinic)

      assert conn
             |> post(~p"/api/appointment-types/#{alheio.id}/restore")
             |> json_response(404)
    end
  end
end
