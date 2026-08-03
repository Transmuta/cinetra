defmodule Api.Housekeeping.Poda do
  @moduledoc """
  O mecanismo comum das podas por retenção — hoje `PruneTrail` (trilha de auditoria) e
  `PruneNotifications` (caixa do sino).

  ## Por que é compartilhado

  A segunda poda repetiria três decisões nada óbvias da primeira, e cada uma delas é um jeito
  distinto de errar em silêncio:

    * **por clínica, dentro de `Api.Repo.with_clinic/2`** — as tabelas têm RLS (ADR-018) e o job
      roda como `cinetra_app`. Um `DELETE` sem a GUC apaga **zero linha** e passa no `mix test`,
      onde o sandbox conecta como superusuário e bypassa RLS. É a armadilha de sempre;
    * **em lotes com teto** — anos de histórico numa transação só seguram conexão do pool e
      incham o WAL de uma vez;
    * **`ctid` no `IN`** — as tabelas podadas não têm chave natural para o recorte, e passar pelo
      `id` seria um caminho mais caro para o mesmo lugar.

  ## Onde a transação começa e termina (doc 96, P-3)

  **Uma transação por lote, não por clínica.** Isto já foi ao contrário, e o lote não protegia
  nada: `por_clinica/1` abria a transação e `em_lote/4` recursava lá dentro, de modo que o `LIMIT`
  reduzia o tamanho de cada `DELETE` mas **não o da transação**. Uma clínica com 300 mil eventos
  ainda produzia um COMMIT de 300 mil linhas com a conexão presa a passada inteira — exatamente o
  que o segundo item acima diz querer evitar.

  Agora `por_clinica/1` só itera, e quem abre transação é `em_lote/4`, **a cada lote**. Duas
  consequências que valem conhecer:

    * cada `DELETE` tem sua própria GUC (é `with_clinic/2` por lote), então a disciplina de RLS
      continua idêntica — e o gate `mix test --only rls` continua sendo quem a prova;
    * a poda passa a ser **retomável**: se a rodada morrer no meio, os lotes já commitados ficam
      apagados em vez de voltarem todos. Para poda isso é o comportamento desejável — não há
      invariante entre um lote e o seguinte.

  É a mesma estrutura que `PruneAttachments` já usava e documentava.

  ## Sobre a interpolação do nome da tabela

  `em_lote/3` interpola `tabela` direto no SQL, porque nome de relação não é parâmetro em
  Postgres. O nome tem de vir **sempre** de literal do módulo que chama (lista fixa, escrita à
  mão) — nunca de args do job, params de request ou varredura do catálogo.
  """

  require Ash.Query
  require Logger

  # Teto por lote. Repetimos até a tabela não devolver mais nada.
  #
  # Configurável só para o teste conseguir exercitar a **recursão** sem criar 5.000 linhas: com o
  # teto de produção, um único `DELETE` sempre dá conta e o laço nunca dá a segunda volta — ou
  # seja, o caminho que este módulo existe para ter ficaria sem cobertura nenhuma.
  @lote_padrao 5_000

  @doc """
  Roda `fun` uma vez por clínica e soma os inteiros devolvidos.

  `fun` recebe o `clinic_id` e devolve quantas linhas apagou.

  **Não abre transação** (doc 96, P-3): quem a abre é `em_lote/4`, a cada lote. Isto é contrato,
  não detalhe — `fun` é responsável por pôr a GUC de tenant em toda operação que fizer, e o jeito
  suportado de fazer isso é justamente chamar `em_lote/4`. Sem GUC, sob `cinetra_app`, o `DELETE`
  apaga zero linha **em silêncio**.

  **Uma clínica que estoura não derruba as outras** (doc 101, M8). Era um `Enum.reduce` cru: um
  erro em qualquer clínica — o `{:ok, n} =` de `em_lote/4` incluído — matava a rodada inteira, e as
  seguintes nem chegavam a ser varridas. Como os jobs de poda têm `max_attempts`, isso não perdia
  trabalho de vez; ele retentava **inteiro**, então uma falha de dado persistente numa única
  clínica travava a poda de todas indefinidamente, sem sintoma além de tabela crescendo. É o mesmo
  isolamento por unidade que `Api.Housekeeping.PruneAttachments` e `Api.Messaging.ReminderJob` já
  faziam.
  """
  @spec por_clinica((String.t() -> non_neg_integer())) :: non_neg_integer()
  def por_clinica(fun) when is_function(fun, 1) do
    Enum.reduce(clinicas(), 0, fn clinic_id, total -> total + podar(fun, clinic_id) end)
  end

  defp podar(fun, clinic_id) do
    fun.(clinic_id)
  rescue
    erro ->
      Logger.warning("poda: falhou na clínica #{clinic_id} (#{Exception.message(erro)})")
      0
  end

  @doc """
  Os ids de todas as clínicas (leitura de sistema — a poda não tem ator).

  `Ash.stream!` e não `read!` (doc 96, P-5): esta função é chamada pelos crons — `SessionSoonJob`
  roda de 5 em 5 minutos, **288×/dia** — e carregar a tabela inteira de clínicas na memória a cada
  passada não escala com o número de clientes. O consumidor só precisa dos ids, um de cada vez.
  """
  @spec clinicas() :: Enumerable.t()
  def clinicas do
    Api.Accounts.Clinic
    |> Ash.Query.select([:id])
    |> Ash.stream!(authorize?: false, batch_size: 500)
    |> Stream.map(& &1.id)
  end

  @doc """
  `DELETE` em lotes até esgotar, **um lote por transação**, e devolve o total apagado.

  `condicao` é o `WHERE` (com `$1`, `$2`… casando com `params`); `tabela` **precisa** ser
  literal do módulo chamador — ver o aviso no moduledoc. `clinic_id` é a clínica cuja GUC vale
  para cada lote; ele costuma aparecer **também** em `params`, porque a condição de recorte por
  tenant é escrita à mão (a RLS já filtra, mas o `WHERE` explícito é o que faz o `LIMIT` recortar
  a clínica certa em vez de um lote arbitrário da tabela inteira).
  """
  @spec em_lote(String.t(), String.t(), [term()], String.t()) :: non_neg_integer()
  def em_lote(tabela, condicao, params, clinic_id) do
    laco(tabela, condicao, params, clinic_id, 0)
  end

  @doc """
  O mesmo `DELETE` em lotes, para tabela **sem** `clinic_id` — hoje só `webhook_events`.

  Sem GUC porque não há coluna de clínica para uma policy comparar; a tabela está fora da RLS por
  desenho (o evento de webhook chega antes de existir tenant). Cada lote continua na sua própria
  transação, pela mesma razão de sempre.

  Existe separada de `em_lote/4` de propósito: um `clinic_id` opcional ali convidaria a chamar a
  versão por-tenant **sem** ele por engano, e o sintoma seria apagar zero linha em silêncio — a
  armadilha que o moduledoc inteiro existe para evitar.
  """
  @spec em_lote_global(String.t(), String.t(), [term()]) :: non_neg_integer()
  def em_lote_global(tabela, condicao, params, total \\ 0) do
    n = apagar_lote(tabela, condicao, params)

    if n < lote(), do: total + n, else: em_lote_global(tabela, condicao, params, total + n)
  end

  defp laco(tabela, condicao, params, clinic_id, total) do
    {:ok, n} = Api.Repo.with_clinic(clinic_id, fn -> apagar_lote(tabela, condicao, params) end)

    if n < lote(), do: total + n, else: laco(tabela, condicao, params, clinic_id, total + n)
  end

  defp apagar_lote(tabela, condicao, params) do
    {:ok, %{num_rows: n}} =
      Api.Repo.query(
        """
        DELETE FROM #{tabela}
        WHERE ctid IN (
          SELECT ctid FROM #{tabela}
          WHERE #{condicao}
          LIMIT #{lote()}
        )
        """,
        params
      )

    n
  end

  @doc """
  O irmão de `em_lote/4` que **atualiza** em vez de apagar, e devolve quantas linhas tocou.

  Existe para a poda que **anonimiza sem apagar** (`Api.Housekeeping.PruneMessages`): há tabela
  cuja linha é a prova de que algo aconteceu — apagá-la é perder a prova — mas cujas colunas
  carregam dado pessoal que não precisa sobreviver junto. São dois relógios sobre a mesma linha,
  e o mais curto é um `UPDATE`.

  `atribuicoes` é o `SET` (literal do módulo chamador, como `tabela` — ver o moduledoc);
  `condicao` é o `WHERE`, e ela **precisa excluir o que já foi anonimizado**, senão o laço reescreve
  as mesmas linhas para sempre e nunca desce abaixo do teto do lote.
  """
  @spec atualizar_em_lote(String.t(), String.t(), String.t(), [term()], String.t()) ::
          non_neg_integer()
  def atualizar_em_lote(tabela, atribuicoes, condicao, params, clinic_id) do
    laco_update(tabela, atribuicoes, condicao, params, clinic_id, 0)
  end

  defp laco_update(tabela, atribuicoes, condicao, params, clinic_id, total) do
    {:ok, n} =
      Api.Repo.with_clinic(clinic_id, fn ->
        atualizar_lote(tabela, atribuicoes, condicao, params)
      end)

    if n < lote(),
      do: total + n,
      else: laco_update(tabela, atribuicoes, condicao, params, clinic_id, total + n)
  end

  defp atualizar_lote(tabela, atribuicoes, condicao, params) do
    {:ok, %{num_rows: n}} =
      Api.Repo.query(
        """
        UPDATE #{tabela}
        SET #{atribuicoes}
        WHERE ctid IN (
          SELECT ctid FROM #{tabela}
          WHERE #{condicao}
          LIMIT #{lote()}
        )
        """,
        params
      )

    n
  end

  defp lote, do: Application.get_env(:api, __MODULE__, [])[:lote] || @lote_padrao

  @doc """
  O instante de corte de uma janela de retenção em dias.

  A ordem é deliberada: `args` do job (poda pontual, e o que o teste usa com `0`) vence a
  config, que vence o default do chamador.
  """
  @spec corte(map(), String.t(), keyword()) :: NaiveDateTime.t()
  def corte(args, chave, opts) do
    case Map.get(args, chave) do
      n when is_integer(n) and n >= 0 -> corte_em_dias(n)
      _ -> corte_em_dias(configurado(opts))
    end
  end

  @doc """
  O instante de `dias` atrás. Existe separado de `corte/3` para quem já resolveu o número por
  conta própria — é o caso de `Api.Housekeeping.PruneMessages`, que tem **duas** janelas na mesma
  rodada e valida a coerência entre elas antes de podar.
  """
  @spec corte_em_dias(non_neg_integer()) :: NaiveDateTime.t()
  def corte_em_dias(dias) when is_integer(dias) and dias >= 0,
    do: NaiveDateTime.add(NaiveDateTime.utc_now(), -dias * 24 * 3600, :second)

  defp configurado(opts) do
    modulo = Keyword.fetch!(opts, :modulo)
    chave = Keyword.fetch!(opts, :chave)
    padrao = Keyword.fetch!(opts, :padrao)

    Application.get_env(:api, modulo, [])[chave] || padrao
  end
end
