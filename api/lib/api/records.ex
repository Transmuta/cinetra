defmodule Api.Records do
  @moduledoc """
  Domínio dos cadastros de paciente da clínica — recurso **por-tenant** por atributo
  (`strategy :attribute` sobre `clinic_id`, ADR-017). Por ora só `Patient` (a ficha
  cadastral da v1). O prontuário completo — `ClinicalTag` cifrado, `Attachment`, `Consent`
  versionado — é v2 (D16); daí o nome "Records" já reservado para quando ele entrar.

  Os wrappers `*_clinic_patient` centralizam o `Api.Repo.with_clinic/2` aqui (na camada de
  domínio) para leitura, espelhando `Api.Directory`. A **escrita** não passa por
  `with_clinic`: ela seta a GUC dentro da própria transação via
  `Api.Tenancy.SetTenantGuc` (ver o moduledoc do change) — envolvê-la quebraria o
  caminho de erro (viraria 500 em vez de 422).
  """
  use Ash.Domain, otp_app: :api

  # Leitura sob RLS (o corte de tenancy é compartilhado — ver `Api.Tenancy`).
  import Api.Tenancy, only: [in_clinic: 2]
  # `expr/1` dos filtros das contagens por segmento.
  import Ash.Expr, only: [expr: 1]

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
  sobre o cadastro inteiro e não sobre o termo digitado.

  Os quatro segmentos saem numa **única** query (`count(*) FILTER (WHERE …)`) via
  `Ash.aggregate`: contar um por vez varria as mesmas páginas de heap quatro vezes (medido no
  doc 24 §7: 29,1ms → 10,4ms). E continua dentro do Ash — policies e a ação `:list` valem
  igual, então contador e lista não podem divergir.
  """
  def clinic_patient_counts(%Api.Scope{} = scope) do
    in_clinic(scope, fn ->
      Api.Records.Patient
      |> Ash.Query.for_read(:list, %{}, scope: scope)
      |> Ash.aggregate!(
        [
          {:todos, :count, []},
          {:ativos, :count, [query: [filter: expr(ativo == true)]]},
          {:inativos, :count, [query: [filter: expr(ativo == false)]]},
          {:resp, :count, [query: [filter: expr(not is_nil(responsavel) and responsavel != "")]]}
        ],
        scope: scope
      )
    end)
  end

  @doc """
  Uma ficha da clínica ativa por id. De outra clínica é indistinguível de inexistente (o
  filtro por atributo não a enxerga) → `{:ok, nil}`, que o controller traduz em 404.
  """
  def fetch_clinic_patient(%Api.Scope{} = scope, id) when is_binary(id) do
    # Um id malformado (não-UUID, ex.: link velho/typo) é indistinguível de inexistente: vira
    # {:ok, nil} → 404, e não o `InvalidArgument` que o `get` levanta e viraria 500 no controller.
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        in_clinic(scope, fn -> get_patient(id, scope: scope, not_found_error?: false) end)

      :error ->
        {:ok, nil}
    end
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

  @doc """
  Quais dos `ids` **não** são pacientes desta clínica (inclui os inexistentes).

  Espelha `Api.Directory.professional_in_clinic?/2`, e existe pelo mesmo motivo: id de
  paciente que chega no corpo de uma ação de **outro** recurso (o `patient_ids` do
  agendamento) não passa por lookup escopado nenhum, então nada o impede de ser de outra
  clínica. Devolver os intrusos, e não um booleano, é o que permite ao chamador dizer no 422
  *quais* ids ele recusou.

  Abre a própria transação com a GUC setada — a leitura precisa atravessar a RLS, e sob
  `mix test` (sandbox como `postgres`, BYPASSRLS) a falta disso passaria despercebida.
  """
  def patients_outside_clinic(ids, clinic_id) when is_list(ids) and is_binary(clinic_id) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    {:ok, found} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_patients!(
          tenant: clinic_id,
          authorize?: false,
          query: [filter: [id: [in: ids]]]
        )
      end)

    ids -- Enum.map(found, & &1.id)
  end

  @doc """
  Quais dos `ids` são pacientes desta clínica **arquivados** (doc 25 §7).

  Separado de `patients_outside_clinic/2` porque as duas perguntas têm respostas diferentes na
  fronteira: id de outra clínica não pode nem ser confirmado como existente, enquanto "está
  arquivado" é informação que o operador precisa ver para saber que basta reativar.

  Abre a própria transação com a GUC (mesma razão da irmã): sem ela a leitura volta vazia sob a
  RLS no servidor real — e **passa** no `mix test`, onde o sandbox conecta como `postgres`
  (BYPASSRLS). Voltar vazia aqui significaria "nenhum arquivado", ou seja, a validação
  desligada em produção e verde na suíte.
  """
  def inactive_patients(ids, clinic_id) when is_list(ids) and is_binary(clinic_id) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    {:ok, found} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_patients!(
          tenant: clinic_id,
          authorize?: false,
          query: [filter: [id: [in: ids], ativo: false]]
        )
      end)

    Enum.map(found, & &1.id)
  end
end
