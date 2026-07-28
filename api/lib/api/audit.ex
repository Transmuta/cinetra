defmodule Api.Audit do
  @moduledoc """
  A trilha de auditoria do sistema inteiro (doc 63) — **uma** tabela de eventos, e não uma tabela
  de versões por recurso.

  Domínio próprio, e não um canto de `Api.Scheduling`: a trilha deixou de ser da agenda no
  momento em que passou a cobrir equipe (quem deu e tirou acesso), ficha (o consentimento), dados
  bancários e **leitura** de dado de saúde.

  Como nos demais domínios por-tenant, os wrappers deste módulo centralizam o
  `Api.Repo.with_clinic/2` (a GUC de tenant para a RLS) na leitura; a escrita seta a GUC dentro
  da própria ação (`SetTenantGuc`).

  ## Retenção — o número mora aqui (D-Aud5)

  90 dias para tudo, revogando o P2 ("guardar para sempre", com poda de 365). A razão é de custo:
  a trilha é a tabela que mais cresce do projeto e a maior parte do que ela guarda nunca é lida.

  **Uma consequência a assumir de olhos abertos**, e está registrada para quando a revisão com o
  jurídico acontecer: 90 dias vale igual para *"quem teve acesso administrativo"* e *"quem leu o
  laudo"* — que são justamente os registros que uma auditoria externa costuma pedir de anos
  anteriores. Por isso o prazo está **num lugar só** e sobrescrevível por config: mudá-lo é
  editar um número, não caçar constantes.
  """
  use Ash.Domain, otp_app: :api

  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query

  @retencao_dias 90

  # O teto das colunas de rótulo (`label`, `user_label`) do `Api.Audit.Event`. Mora aqui, e não
  # só no recurso, porque quem PRECISA respeitá-lo é quem monta o payload — e ele estava sendo
  # respeitado por ninguém.
  @max_rotulo 200

  resources do
    resource Api.Audit.Event do
      define :record_event, action: :record
      define :page_events, action: :feed
      define :list_recent_duplicates, action: :recent_duplicate
    end
  end

  @doc """
  Normaliza um rótulo para caber na coluna (`label`/`user_label`, 200 caracteres).

  Existe porque o que chega nesses campos vem **de fora**: o nome do usuário (que ele mesmo
  edita, e que era o único rótulo do sistema sem teto próprio) e o caminho da request (que o
  cliente escolhe). Sem isto, o teto da coluna decidia — e decidia de dois jeitos opostos:

    * pelo `Api.Audit.Capture`, que grava com a versão **bang** dentro da transação de negócio,
      um rótulo longo **derrubava a escrita observada**. Medido: um membro com nome de 201
      caracteres não podia ser removido da clínica (`DELETE /api/members` → 500, vínculo
      intacto), e ele mesmo não conseguia editar uma ficha;
    * pelo `Api.Audit.Acesso`, que grava sem bang e descartava o retorno, o rótulo longo fazia o
      evento **sumir em silêncio** — bastava encher a URL para o 403 não deixar rastro.

  A trilha observa. Ela não tem direito de vetar a operação nem de calar por conta própria, e
  truncar na fronteira é o que garante as duas coisas para qualquer rótulo futuro, venha ele de
  um campo com teto ou sem.
  """
  @spec rotulo(term()) :: String.t() | nil
  def rotulo(nil), do: nil

  def rotulo(valor) when is_binary(valor) do
    if String.length(valor) > @max_rotulo, do: String.slice(valor, 0, @max_rotulo), else: valor
  end

  def rotulo(valor), do: valor |> to_string() |> rotulo()

  @doc "O teto de caracteres de um rótulo da trilha."
  def max_rotulo, do: @max_rotulo

  @doc """
  Por quantos dias a trilha é retida (D-Aud5). Config vence o default:

      config :api, Api.Audit, retencao_dias: 365
  """
  def retencao_dias do
    :api
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retencao_dias, @retencao_dias)
  end

  @doc """
  Uma **página** da trilha da clínica ativa, pronta para a tela: cada entrada traz
  **quem · quando · qual ação · qual registro** e o diff campo-a-campo.

  Opções (todas opcionais): `:resource` (um `Api.Audit.ResourceKind` ou lista deles),
  `:record_id`, `:user_id`, `:action`, `:from`/`:to` (janela sobre `at`), `:limit`, `:offset`.

  Sem `:resource`, o feed é **da clínica inteira** — a pergunta que o admin de fato faz, e a que
  o modelo anterior (uma tabela de versões por recurso) não conseguia responder.

  ## Sem `total` — o D-Aud1 continua de pé

  Esta função já devolveu o total, com o argumento de que a retenção de 90 dias (D-Aud5) tornava
  a tabela "limitada por construção". **O bate-volta mediu, e o argumento não se sustenta:** ele
  é sobre *tamanho*, não sobre *custo por request*. Noventa dias de trilha numa clínica movimentada
  continuam sendo dezenas de milhares de linhas, e o `COUNT(*)` — que o Ash emite como uma
  **segunda query**, não como `COUNT(*) OVER ()` — lê o recorte inteiro, imune ao `LIMIT`:

      recorte de  84.002 linhas: página 0,090 ms · 9 buffers   ·  count 23,9 ms · 191 buffers   (265×)
      recorte de 586.185 linhas: página 0,085 ms · 6 buffers   ·  count 62,3 ms · 1.963 buffers (733×)

  Ou seja: o total era **~99% do tempo de banco** de cada abertura da tela. O `more?` continua
  exato (o Ash busca `limit + 1`), o rodapé mostra a faixa e a página, e o caminho sem total já
  existia na tela (`web/src/lib/audit.ts`, `auditPageLabel/3`).

  O teto de queries está travado em `test/api/audit/feed_queries_test.exs` — uma leitura de
  `audit_events` por página, não duas.
  """
  def list_events(%Api.Scope{} = scope, opts \\ []) do
    limit = opts |> Keyword.get(:limit) |> Api.Pagination.limit()
    offset = opts |> Keyword.get(:offset) |> Api.Pagination.offset()

    in_clinic(scope, fn ->
      page =
        page_events!(
          scope: scope,
          query: feed_query(opts),
          page: [limit: limit, offset: offset, count: false]
        )

      %{
        entries: enrich(scope, page.results),
        page: %{
          limit: page.limit,
          offset: page.offset,
          more: page.more?
        }
      }
    end)
  end

  # ---- enriquecimento ----
  #
  # A linha já traz `label` e `user_label` gravados (o registro e o autor), então o que falta é
  # só o **contexto** que mora em `meta` como uuid: de qual paciente e de qual profissional a
  # linha fala. Duas leituras em LOTE por página — nunca uma por entrada, que é o N+1 que o doc
  # 25 §11.4 já proibia na tabela que mais cresce.
  #
  # `authorize?: false` e `select` enxuto: é detalhe interno da montagem da página, já sob o
  # tenant da GUC, e a leitura crua de `patients` traz as ~39 colunas do cadastro (CPF, RG) —
  # o mesmo corte que a agenda aplica em `patients_for`.
  defp enrich(_scope, []), do: []

  defp enrich(scope, events) do
    pacientes = nomes(scope, :patient, ids(events, "patient_id"))
    profissionais = nomes(scope, :professional, ids(events, "professional_id"))

    Enum.map(events, fn e ->
      %{
        id: e.id,
        resource: e.resource,
        record_id: e.record_id,
        label: e.label,
        action: e.action,
        action_type: e.action_type,
        at: e.at,
        actor: ator(e),
        patient: Map.get(pacientes, e.meta["patient_id"]),
        professional: Map.get(profissionais, e.meta["professional_id"]),
        diff: e.diff,
        meta: e.meta
      }
    end)
  end

  defp ator(%{user_id: nil, user_label: nil}), do: nil
  defp ator(e), do: %{id: e.user_id, nome: e.user_label}

  defp ids(events, chave) do
    events
    |> Enum.map(& &1.meta[chave])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp nomes(_scope, _tipo, []), do: %{}

  defp nomes(scope, :patient, ids) do
    Api.Records.list_patients!(
      scope: scope,
      authorize?: false,
      query: [filter: [id: [in: ids]], select: [:id, :nome]]
    )
    |> Map.new(&{&1.id, %{id: &1.id, nome: &1.nome}})
  end

  defp nomes(scope, :professional, ids) do
    Api.Directory.list_professionals!(
      scope: scope,
      authorize?: false,
      query: [filter: [id: [in: ids]], select: [:id, :nome]]
    )
    |> Map.new(&{&1.id, %{id: &1.id, nome: &1.nome}})
  end

  # Os filtros aplicados condicionalmente. Explícitos (uma cláusula por campo) e não com nome de
  # campo dinâmico: `Ash.Query.filter` é macro, e um `ref(^field)` só embaralharia o que aqui são
  # seis linhas legíveis. Mesma forma do `audit_query/2` que este módulo aposenta.
  defp feed_query(opts) do
    Api.Audit.Event
    |> filter_resource(Keyword.get(opts, :resource))
    |> filter_record(Keyword.get(opts, :record_id))
    |> filter_user(Keyword.get(opts, :user_id))
    |> filter_action(Keyword.get(opts, :action))
    |> filter_from(Keyword.get(opts, :from))
    |> filter_to(Keyword.get(opts, :to))
  end

  defp filter_resource(query, nil), do: query

  defp filter_resource(query, list) when is_list(list),
    do: Ash.Query.filter(query, resource in ^list)

  defp filter_resource(query, kind), do: Ash.Query.filter(query, resource == ^kind)

  defp filter_record(query, nil), do: query
  defp filter_record(query, id), do: Ash.Query.filter(query, record_id == ^id)

  defp filter_user(query, nil), do: query
  defp filter_user(query, id), do: Ash.Query.filter(query, user_id == ^id)

  defp filter_action(query, nil), do: query
  defp filter_action(query, name), do: Ash.Query.filter(query, action == ^name)

  defp filter_from(query, nil), do: query
  defp filter_from(query, from), do: Ash.Query.filter(query, at >= ^from)

  defp filter_to(query, nil), do: query
  defp filter_to(query, to), do: Ash.Query.filter(query, at < ^to)
end
