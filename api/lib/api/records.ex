defmodule Api.Records do
  @moduledoc """
  Domínio dos cadastros de paciente da clínica — recurso **por-tenant** por atributo
  (`strategy :attribute` sobre `clinic_id`, ADR-017). Por ora só `Patient` (a ficha
  cadastral da v1). O prontuário completo — `ClinicalTag` cifrado, `Attachment`, `Consent`
  versionado — é v2 (D16); daí o nome "Records" já reservado para quando ele entrar.

  Os wrappers `*_clinic_patient` centralizam o `Api.Repo.with_clinic/2` aqui (na camada de
  domínio) para leitura, espelhando `Api.Directory`. A **escrita** não passa por
  `with_clinic`: ela seta a GUC dentro da própria transação via
  `Api.Directory.Changes.SetTenantGuc` (ver o moduledoc do change) — envolvê-la quebraria o
  caminho de erro (viraria 500 em vez de 422).
  """
  use Ash.Domain, otp_app: :api

  resources do
    resource Api.Records.Patient do
      define :create_patient, action: :create, args: [:nome]
      define :list_patients, action: :read
      define :list_patients_page, action: :list
      define :get_patient, action: :read, get_by: [:id]
      define :update_patient, action: :update
      define :deactivate_patient, action: :deactivate
      define :reactivate_patient, action: :reactivate
    end
  end

  # Roda `fun` com a GUC de tenant setada.
  defp in_clinic(%Api.Scope{clinic_id: clinic_id}, fun) when is_binary(clinic_id) do
    {:ok, result} = Api.Repo.with_clinic(clinic_id, fun)
    result
  end

  @default_limit 50
  @max_limit 200
  # Teto do offset (página ~2000 com 50/página). Existe por robustez, não por performance: sem
  # ele um `?page=` gigante chega cru no Postgrex, que recusa qualquer coisa fora do int64 e
  # derruba a request com 500. Além disso, ninguém pagina até lá — usa a busca.
  @max_offset 100_000

  @doc """
  Uma **página** da lista de pacientes da clínica ativa, já filtrada e buscada no servidor
  (ver `Api.Records.Preparations.FilterPatients`). Devolve `%Ash.Page.Offset{}` — `results`,
  `count` (total do recorte), `limit`, `offset`, `more?`.

  Opções: `:q` (busca), `:status` (`:todos`/`:ativos`/`:inativos`/`:resp`), `:limit`, `:offset`.
  O `limit` é limitado a #{@max_limit} para o cliente não pedir a tabela inteira.
  """
  def list_clinic_patients(%Api.Scope{} = scope, opts \\ []) do
    args = %{q: Keyword.get(opts, :q), status: Keyword.get(opts, :status, :todos)}
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    offset = opts |> Keyword.get(:offset, 0) |> clamp_offset()

    in_clinic(scope, fn ->
      list_patients_page!(args, scope: scope, page: [limit: limit, offset: offset, count: true])
    end)
  end

  # Em cláusulas (e não com `min/2`/`max/2`): o `Ash.Domain` já define locais com esses nomes,
  # e importar as do `Kernel` aqui dá conflito de compilação.
  defp clamp_limit(limit) when is_integer(limit) and limit > @max_limit, do: @max_limit
  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp clamp_limit(_limit), do: @default_limit

  defp clamp_offset(offset) when is_integer(offset) and offset > @max_offset, do: @max_offset
  defp clamp_offset(offset) when is_integer(offset) and offset > 0, do: offset
  defp clamp_offset(_offset), do: 0

  @doc """
  Contagens por segmento para a sidebar (Todos / Ativos / Inativos / Com responsável).

  Precisa vir do servidor: com a lista paginada, contar o que chegou contaria só a página.
  **Independe da busca** — são "quantos pacientes existem em cada segmento", como o
  `sbPacientes` do protótipo ([`:1437`](../../../interface/Movimento.dc.html#L1437)), que conta
  sobre o cadastro inteiro e não sobre o termo digitado. `inativos` é derivado (total − ativos)
  para poupar uma query.
  """
  def clinic_patient_counts(%Api.Scope{} = scope) do
    in_clinic(scope, fn ->
      total = count_status(scope, :todos)
      ativos = count_status(scope, :ativos)

      %{todos: total, ativos: ativos, inativos: total - ativos, resp: count_status(scope, :resp)}
    end)
  end

  # Reusa a própria ação `:list` (e sua preparation), então segmento no contador e segmento na
  # lista não podem divergir.
  defp count_status(%Api.Scope{} = scope, status) do
    Api.Records.Patient
    |> Ash.Query.for_read(:list, %{status: status}, scope: scope)
    |> Ash.count!()
  end

  @doc """
  Uma ficha da clínica ativa por id. De outra clínica é indistinguível de inexistente (o
  filtro por atributo não a enxerga) → `{:ok, nil}`, que o controller traduz em 404.
  """
  def fetch_clinic_patient(%Api.Scope{} = scope, id) when is_binary(id) do
    in_clinic(scope, fn -> get_patient(id, scope: scope, not_found_error?: false) end)
  end

  @doc "Cria um paciente no cadastro da clínica ativa do escopo (só o nome é obrigatório)."
  def create_clinic_patient(%Api.Scope{} = scope, attrs) do
    {nome, rest} = Map.pop(attrs, :nome)
    create_patient(nome, rest, scope: scope)
  end

  @doc "Atualiza (parcialmente) uma ficha da clínica ativa."
  def update_clinic_patient(%Api.Scope{} = scope, patient, attrs) do
    update_patient(patient, attrs, scope: scope)
  end

  @doc "Arquiva um paciente (some da lista de ativos, sem apagar)."
  def deactivate_clinic_patient(%Api.Scope{} = scope, patient) do
    deactivate_patient(patient, %{}, scope: scope)
  end

  @doc "Reativa um paciente arquivado."
  def reactivate_clinic_patient(%Api.Scope{} = scope, patient) do
    reactivate_patient(patient, %{}, scope: scope)
  end
end
