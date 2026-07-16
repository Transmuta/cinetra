defmodule Api.Directory do
  @moduledoc """
  Domínio do quadro da clínica — recursos **por-tenant** por atributo (`strategy :attribute`
  sobre `clinic_id`, ADR-017). Por ora `Professional` e `AppointmentType` (o catálogo, doc
  20); `PriceVersion` entra com faturamento (v2).
  """
  use Ash.Domain, otp_app: :api

  resources do
    resource Api.Directory.Professional do
      define :create_professional, action: :create, args: [:nome]
      define :list_professionals, action: :read
      define :get_professional, action: :read, get_by: [:id]
    end

    resource Api.Directory.AppointmentType do
      define :create_appointment_type, action: :create
      define :list_appointment_types, action: :read
      define :get_appointment_type, action: :read, get_by: [:id]
      define :update_appointment_type, action: :update
      # T2: "excluir" é arquivar — transição de estado, reversível. Não há destroy.
      define :archive_appointment_type, action: :archive
      define :restore_appointment_type, action: :restore
    end
  end

  # Os recursos daqui são por-tenant sob RLS (ADR-018): o Postgres só devolve/aceita linhas
  # do `clinic_id` que estiver na GUC `movimento.clinic_id`, e a GUC é transação-local.
  # Estes wrappers centralizam o `Api.Repo.with_clinic/2` aqui, na camada de domínio, para
  # que controllers/changes não precisem falar com o Repo (regra ash.md).
  #
  # Isto vale para **leitura**, que não abre transação sozinha. A **escrita** não passa por
  # aqui: ela seta a GUC dentro da própria transação, via
  # `Api.Directory.Changes.SetTenantGuc` (`before_action`) — envolvê-la num `with_clinic`
  # quebraria o caminho de erro (o rollback do Ash na transação interna arrebenta a
  # externa e vira 500 em vez de 422). Ver o moduledoc do change.

  # Roda `fun` com a GUC de tenant setada.
  defp in_clinic(%Api.Scope{clinic_id: clinic_id}, fun) when is_binary(clinic_id) do
    {:ok, result} = Api.Repo.with_clinic(clinic_id, fun)
    result
  end

  @doc """
  Catálogo da clínica ativa do escopo — ativos **e** arquivados (a tela separa), em ordem de
  criação, com a `sigla` derivada carregada (o JSON depende dela).
  """
  def list_clinic_appointment_types(%Api.Scope{} = scope) do
    # A ordem (`inserted_at: :asc`) é preparação do recurso, não daqui.
    in_clinic(scope, fn -> list_appointment_types!(scope: scope, load: [:sigla]) end)
  end

  @doc """
  Um tipo do catálogo da clínica ativa, com a `sigla` carregada. Tipo de outra clínica é
  indistinguível de inexistente (o filtro por atributo não o enxerga) → erro `NotFound`,
  que o controller traduz em 404.
  """
  def fetch_clinic_appointment_type(%Api.Scope{} = scope, id) when is_binary(id) do
    in_clinic(scope, fn -> get_appointment_type(id, scope: scope, load: [:sigla]) end)
  end

  @doc "Cria um tipo no catálogo da clínica ativa do escopo."
  def create_clinic_appointment_type(%Api.Scope{} = scope, attrs) do
    create_appointment_type(attrs, scope: scope, load: [:sigla])
  end

  @doc "Atualiza (parcialmente) um tipo do catálogo da clínica ativa."
  def update_clinic_appointment_type(%Api.Scope{} = scope, tipo, attrs) do
    update_appointment_type(tipo, attrs, scope: scope, load: [:sigla])
  end

  @doc "Arquiva um tipo (T2): some da lista, sem apagar."
  def archive_clinic_appointment_type(%Api.Scope{} = scope, tipo) do
    archive_appointment_type(tipo, %{}, scope: scope, load: [:sigla])
  end

  @doc "Restaura um tipo arquivado (T5)."
  def restore_clinic_appointment_type(%Api.Scope{} = scope, tipo) do
    restore_appointment_type(tipo, %{}, scope: scope, load: [:sigla])
  end

  @doc """
  Cria em lote o catálogo inicial de uma clínica (seed do `Clinic.onboard`, T3). Recebe
  `clinic_id` cru — e não um `Api.Scope` — porque roda dentro do `onboard`, quando o tenant
  acabou de nascer e ainda não há escopo com ele. A GUC de cada INSERT é setada pelo
  `Api.Directory.Changes.SetTenantGuc` da própria ação.
  """
  def seed_appointment_types(clinic_id, tipos) when is_binary(clinic_id) and is_list(tipos) do
    Enum.map(tipos, &create_appointment_type!(&1, tenant: clinic_id, authorize?: false))
  end

  @doc "Profissionais da clínica ativa do escopo (com o GUC de tenant setado)."
  def list_clinic_professionals(%Api.Scope{clinic_id: clinic_id} = scope)
      when is_binary(clinic_id) do
    {:ok, professionals} =
      Api.Repo.with_clinic(clinic_id, fn -> list_professionals!(scope: scope) end)

    professionals
  end

  @doc "Verdadeiro se `professional_id` é um `Professional` da clínica `clinic_id`."
  def professional_in_clinic?(professional_id, clinic_id)
      when is_binary(professional_id) and is_binary(clinic_id) do
    {:ok, found?} =
      Api.Repo.with_clinic(clinic_id, fn ->
        case get_professional(professional_id, tenant: clinic_id, authorize?: false) do
          {:ok, %Api.Directory.Professional{}} -> true
          _ -> false
        end
      end)

    found?
  end

  def professional_in_clinic?(_professional_id, _clinic_id), do: false
end
