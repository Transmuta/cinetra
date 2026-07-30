defmodule ApiWeb.AppointmentTypesController do
  @moduledoc """
  Catálogo de tipos de atendimento da clínica (doc 20 §3). Espelha o `MembersController`: lê
  o `Api.Scope` do request, chama os code interfaces do domínio com `scope:` e monta o JSON.
  O `clinic_id` vem **sempre** do escopo, nunca do corpo (09 §8). RBAC ADR-016 / T8 (defesa
  em profundidade sobre as policies do `AppointmentType`): a **leitura** (GET) é liberada a
  qualquer membro ativo — a agenda inteira depende do catálogo —; a **escrita**
  (POST/PATCH/archive/restore) exige owner/admin.

  Não há `DELETE` (T2): arquivar é transição de estado (`POST /:id/archive`), reversível por
  `POST /:id/restore`.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Accounts
  alias Api.Directory

  # GET /api/appointment-types — ativos E arquivados; a tela é que separa (T5).
  #
  # O `cap_turma_padrao` da clínica vem junto (doc 20 §3): é o default do campo Capacidade no
  # modal e nenhum outro endpoint o expõe. Irmão de `appointment_types`, no molde do
  # `{members, professionals}` do MembersController — melhor que um GET extra só por um inteiro.
  def index(conn, _params) do
    with_member_scope(conn, fn scope ->
      clinic = Accounts.get_clinic!(scope.clinic_id, scope: scope)

      json(conn, %{
        appointment_types: Enum.map(Directory.list_clinic_appointment_types(scope), &type_json/1),
        cap_turma_padrao: clinic.cap_turma_padrao
      })
    end)
  end

  # POST /api/appointment-types — cria um tipo no catálogo da clínica ativa.
  def create(conn, params) do
    with_admin_scope(conn, fn scope ->
      case Directory.create_clinic_appointment_type(scope, input(params)) do
        {:ok, tipo} ->
          conn |> put_status(:created) |> json(%{appointment_type: type_json(tipo)})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # PATCH /api/appointment-types/:id — atualização parcial.
  def update(conn, %{"id" => id} = params) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Directory.update_clinic_appointment_type(scope, &1, input(params)))
    end)
  end

  # POST /api/appointment-types/:id/archive — some da lista, sem apagar (T2).
  def archive(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Directory.archive_clinic_appointment_type(scope, &1))
    end)
  end

  # POST /api/appointment-types/:id/restore — volta para a lista.
  def restore(conn, %{"id" => id}) do
    with_admin_scope(conn, fn scope ->
      write(conn, scope, id, &Directory.restore_clinic_appointment_type(scope, &1))
    end)
  end

  # ---- helpers ----

  # Busca-e-escreve: as 3 mutações por id compartilham a mesma escada (404 se não existe ou
  # é de outra clínica; 422 se a ação recusa).
  defp write(conn, scope, id, fun) do
    with {:ok, %{} = tipo} <- Directory.fetch_clinic_appointment_type(scope, id),
         {:ok, updated} <- fun.(tipo) do
      json(conn, %{appointment_type: type_json(updated)})
    else
      {:ok, nil} -> not_found(conn)
      {:error, error} -> error_response(conn, error)
    end
  end

  # `sigla` é derivada (T4) e vem sempre no JSON. `clinic_id` NÃO sai: é o tenant, já
  # implícito na sessão — o cliente não tem o que fazer com ele.
  defp type_json(t) do
    %{
      id: t.id,
      nome: t.nome,
      sigla: t.sigla,
      duracao_minutos: t.duracao_minutos,
      cor: t.cor,
      icon: t.icon,
      grupo: t.grupo,
      capacidade: t.capacidade,
      ativo: t.ativo
    }
  end

  @campos ~w(nome duracao_minutos cor icon grupo capacidade)a

  # `clinic_id`, `ativo` e o que mais vier no corpo são ignorados pela whitelist — o tenant vem
  # do escopo (09 §8), e `ativo` só muda por archive/restore (T2). Serve create e update: no
  # create, obrigatório ausente cai no `allow_nil? false`; no update, ausente não é tocado.
  defp input(params), do: whitelist(params, @campos)
end
