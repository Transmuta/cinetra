defmodule ApiWeb.MembersControllerTest do
  @moduledoc """
  Endpoints de gestão de membros (Fatia 10). Integração real: sessão assinada + `LoadScope`
  resolvendo o tenant ativo, RBAC owner/admin, e o convite por e-mail ponta-a-ponta.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts

  setup %{conn: conn} do
    owner = sign_in!(email_unico("user"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/members" do
    test "lista membros da clínica e profissionais", %{conn: conn, clinic: clinic} do
      {:ok, _prof} =
        Api.Directory.create_professional("Dra. Ana", %{}, tenant: clinic.id, authorize?: false)

      body = conn |> get(~p"/api/members") |> json_response(200)

      assert [%{"papel" => "owner", "status" => "ativo"} = owner_json] = body["members"]
      assert owner_json["email"] =~ "@"
      assert [%{"nome" => "Dra. Ana"}] = body["professionals"]
    end

    # `id` é o do VÍNCULO (é por ele que se edita/revoga o membro), não o do usuário. Quem
    # precisa do usuário é o filtro "por autor" da auditoria: a trilha grava `user_id`, e sem
    # este campo não há como ligar um nome da equipe às linhas que ele escreveu.
    test "expõe o user_id além do id do vínculo", %{conn: conn, owner: owner} do
      body = conn |> get(~p"/api/members") |> json_response(200)

      assert [%{"id" => membership_id, "user_id" => user_id}] = body["members"]
      assert user_id == owner.id
      refute membership_id == user_id
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> get(~p"/api/members") |> json_response(401)
    end

    test "autenticado sem clínica ativa devolve 403", %{base_conn: base_conn} do
      # usuário logado, mas sem nenhuma clínica (não fez onboarding nem foi convidado):
      # o scope não tem clinic_id, então `with_member_scope` barra (403, não 401).
      orphan = sign_in!(email_unico("user"))

      assert base_conn |> authed(orphan) |> get(~p"/api/members") |> json_response(403)
    end

    test "qualquer membro autenticado vê os membros (recepção, 200)",
         %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      body = base_conn |> authed(recep) |> get(~p"/api/members") |> json_response(200)

      papeis = Enum.map(body["members"], & &1["papel"])
      # a recepção (não-gestora) enxerga todos os vínculos, inclusive o próprio e o do owner.
      assert "recepcao" in papeis
      assert "owner" in papeis
    end
  end

  describe "POST /api/members" do
    test "convida por e-mail e cria vínculo pendente", %{conn: conn} do
      invitee = email_unico("user")

      body =
        conn
        |> post(~p"/api/members", %{email: invitee, nome: "Novo", papel: "recepcao"})
        |> json_response(201)

      assert body["member"]["status"] == "pendente"
      assert body["member"]["papel"] == "recepcao"
      assert body["member"]["email"] == invitee
      # o magic link de convite saiu para o convidado.
      assert_receive {:email, mail}, 1_000
      assert [{_, ^invitee}] = mail.to
    end

    test "recepção não pode convidar (403)",
         %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> post(~p"/api/members", %{email: email_unico("user"), papel: "recepcao"})
             |> json_response(403)
    end

    test "papel inválido devolve 422", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/members", %{email: email_unico("user"), papel: "faxineiro"})
        |> json_response(422)

      assert body["error"] == "invalid"
    end

    # Regressão do conserto do docs/23: o erro de identity duplicada (`unique_user_per_clinic`)
    # reporta o campo em `:fields` (plural). A cópia antiga de `error_messages` do controller só
    # olhava `:field` (singular), então este 422 saía com `field: null` e o form não sabia qual
    # input marcar. Depois de migrar para o `ApiWeb.TenantScope` (com o fallback `:fields`), vem
    # preenchido.
    test "convite do mesmo e-mail duas vezes devolve 422 com o campo preenchido (não null)",
         %{conn: conn} do
      invitee = email_unico("user")
      conn |> post(~p"/api/members", %{email: invitee, papel: "recepcao"}) |> json_response(201)

      body =
        conn
        |> post(~p"/api/members", %{email: invitee, papel: "recepcao"})
        |> json_response(422)

      assert body["error"] == "invalid"
      assert [%{"field" => field} | _] = body["details"]
      refute is_nil(field)
    end

    test "convite de profissional carrega o vínculo (professional_id)", %{
      conn: conn,
      clinic: clinic
    } do
      {:ok, prof} =
        Api.Directory.create_professional("Dr. Vínculo", %{},
          tenant: clinic.id,
          authorize?: false
        )

      body =
        conn
        |> post(~p"/api/members", %{
          email: email_unico("user"),
          nome: "Prof",
          papel: "profissional",
          professional_id: prof.id
        })
        |> json_response(201)

      assert body["member"]["papel"] == "profissional"
      assert body["member"]["professional_id"] == prof.id
    end
  end

  describe "PATCH /api/members/:id" do
    test "troca o papel do membro", %{conn: conn, owner: owner, clinic: clinic} do
      {:ok, m} =
        Accounts.invite_member_by_email(
          email_unico("user"),
          %{papel: :recepcao, clinic_id: clinic.id},
          actor: owner
        )

      body = conn |> patch(~p"/api/members/#{m.id}", %{papel: "admin"}) |> json_response(200)
      assert body["member"]["papel"] == "admin"
    end

    test "id inexistente devolve 404", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/members/#{Ecto.UUID.generate()}", %{papel: "admin"})
        |> json_response(404)

      assert body["error"] == "not_found"
    end

    test "não altera vínculo de outra clínica (isolamento → 404)", %{conn: conn} do
      # um owner de OUTRA clínica, com seu próprio vínculo owner.
      other = sign_in!(email_unico("user"))

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      [alheio] = Accounts.list_clinic_members!(other_clinic.id, actor: other)

      # o owner logado (clínica diferente) não enxerga nem altera o vínculo alheio.
      body = conn |> patch(~p"/api/members/#{alheio.id}", %{papel: "admin"}) |> json_response(404)
      assert body["error"] == "not_found"
    end

    test "vincula e desvincula profissional (professional_id)", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      {:ok, prof} =
        Api.Directory.create_professional("Dra. Liga", %{}, tenant: clinic.id, authorize?: false)

      {:ok, m} =
        Accounts.invite_member_by_email(
          email_unico("user"),
          %{papel: :profissional, clinic_id: clinic.id},
          actor: owner
        )

      linked =
        conn |> patch(~p"/api/members/#{m.id}", %{professional_id: prof.id}) |> json_response(200)

      assert linked["member"]["professional_id"] == prof.id

      unlinked =
        conn |> patch(~p"/api/members/#{m.id}", %{professional_id: ""}) |> json_response(200)

      assert unlinked["member"]["professional_id"] == nil
    end
  end

  describe "DELETE /api/members/:id" do
    test "revoga o acesso (204)", %{conn: conn, owner: owner, clinic: clinic} do
      {:ok, m} =
        Accounts.invite_member_by_email(
          email_unico("user"),
          %{papel: :recepcao, clinic_id: clinic.id},
          actor: owner
        )

      assert conn |> delete(~p"/api/members/#{m.id}") |> response(204)
      # o vínculo foi de fato removido (hard delete).
      assert {:error, %Ash.Error.Invalid{}} = Accounts.get_membership(m.id, authorize?: false)
    end
  end
end
