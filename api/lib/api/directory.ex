defmodule Api.Directory do
  @moduledoc """
  Domínio do quadro da clínica — recursos **por-tenant** por atributo (`strategy :attribute`
  sobre `clinic_id`, ADR-017). Por ora `Professional` e `AppointmentType` (o catálogo, doc
  20); `PriceVersion` entra com faturamento (v2).
  """
  use Ash.Domain, otp_app: :api

  # Leitura sob RLS (o corte de tenancy é compartilhado — ver `Api.Tenancy`).
  import Api.Tenancy, only: [in_clinic: 2]

  resources do
    resource Api.Directory.Professional do
      define :create_professional, action: :create, args: [:nome]
      define :list_professionals, action: :read
      define :get_professional, action: :read, get_by: [:id]
      define :update_professional, action: :update
      define :deactivate_professional, action: :deactivate
      define :reactivate_professional, action: :reactivate
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
  # `Api.Tenancy.SetTenantGuc` (`before_action`) — envolvê-la num `with_clinic`
  # quebraria o caminho de erro (o rollback do Ash na transação interna arrebenta a
  # externa e vira 500 em vez de 422). Ver o moduledoc do change.

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
  `Api.Tenancy.SetTenantGuc` da própria ação.
  """
  def seed_appointment_types(clinic_id, tipos) when is_binary(clinic_id) and is_list(tipos) do
    Enum.map(tipos, &create_appointment_type!(&1, tenant: clinic_id, authorize?: false))
  end

  @doc """
  Profissionais da clínica ativa do escopo (com o GUC de tenant setado), com a grade semanal
  (`weekly_hours`) carregada — a coluna "Atendimento" da lista a resolve contra o expediente
  da clínica.
  """
  def list_clinic_professionals(%Api.Scope{clinic_id: clinic_id} = scope)
      when is_binary(clinic_id) do
    {:ok, professionals} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_professionals!(scope: scope, load: [:weekly_hours])
      end)

    professionals
  end

  @doc """
  Um profissional da clínica ativa por id, com a grade e as exceções carregadas (a ficha
  precisa delas). De outra clínica é indistinguível de inexistente (o filtro por atributo não
  o enxerga) → `{:ok, nil}`, que o controller traduz em 404.
  """
  def fetch_clinic_professional(%Api.Scope{} = scope, id, opts \\ []) when is_binary(id) do
    load = Keyword.get(opts, :load, [])

    in_clinic(scope, fn ->
      get_professional(id, scope: scope, load: load, not_found_error?: false)
    end)
  end

  @doc "Cria um profissional no diretório da clínica ativa do escopo."
  def create_clinic_professional(%Api.Scope{} = scope, attrs) do
    {nome, rest} = Map.pop(attrs, :nome)
    create_professional(nome, rest, scope: scope)
  end

  @doc "Atualiza (parcialmente) um profissional da clínica ativa."
  def update_clinic_professional(%Api.Scope{} = scope, professional, attrs) do
    update_professional(professional, attrs, scope: scope)
  end

  @doc "Arquiva um profissional (some da lista de ativos, sem apagar)."
  def deactivate_clinic_professional(%Api.Scope{} = scope, professional) do
    deactivate_professional(professional, %{}, scope: scope)
  end

  @doc "Reativa um profissional arquivado."
  def reactivate_clinic_professional(%Api.Scope{} = scope, professional) do
    reactivate_professional(professional, %{}, scope: scope)
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

  @doc """
  Verdadeiro só quando o profissional **existe nesta clínica e está inativo**.

  A forma negativa é deliberada: id inexistente ou de outra clínica responde `false`, porque
  quem recusa esse caso é o lookup escopado de `CheckAvailability`, com a mensagem certa
  ("profissional não encontrado nesta clínica"). Uma função que respondesse `true` para
  "não achei" empilharia dois erros diferentes sobre o mesmo campo.
  """
  def professional_inactive?(professional_id, clinic_id)
      when is_binary(professional_id) and is_binary(clinic_id) do
    {:ok, inactive?} =
      Api.Repo.with_clinic(clinic_id, fn ->
        case get_professional(professional_id,
               tenant: clinic_id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %Api.Directory.Professional{ativo: false}} -> true
          _ -> false
        end
      end)

    inactive?
  end

  def professional_inactive?(_professional_id, _clinic_id), do: false

  @doc """
  Verdadeiro só quando o tipo **existe nesta clínica e está arquivado** (T2: arquivar, não
  excluir). Mesma forma negativa de `professional_inactive?/2`, pelo mesmo motivo.
  """
  def appointment_type_archived?(type_id, clinic_id)
      when is_binary(type_id) and is_binary(clinic_id) do
    {:ok, archived?} =
      Api.Repo.with_clinic(clinic_id, fn ->
        case get_appointment_type(type_id,
               tenant: clinic_id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %Api.Directory.AppointmentType{ativo: false}} -> true
          _ -> false
        end
      end)

    archived?
  end

  def appointment_type_archived?(_type_id, _clinic_id), do: false

  @doc """
  O teto de participantes de uma turma: `capacidade` do tipo, ou `nil` quando o tipo é de
  grupo mas não define teto (o chamador cai no `cap_turma_padrao` da clínica).

  Retornos: `{:ok, capacidade | nil}` (tipo de grupo) · `:individual` · `:error` (não achado).
  """
  def appointment_type_capacity(type_id, clinic_id)
      when is_binary(type_id) and is_binary(clinic_id) do
    {:ok, result} =
      Api.Repo.with_clinic(clinic_id, fn ->
        case get_appointment_type(type_id,
               tenant: clinic_id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %Api.Directory.AppointmentType{grupo: true, capacidade: cap}} -> {:ok, cap}
          {:ok, %Api.Directory.AppointmentType{}} -> :individual
          _ -> :error
        end
      end)

    result
  end

  def appointment_type_capacity(_type_id, _clinic_id), do: :error
end
