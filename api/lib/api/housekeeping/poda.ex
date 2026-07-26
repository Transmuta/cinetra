defmodule Api.Housekeeping.Poda do
  @moduledoc """
  O mecanismo comum das podas por retenção — hoje `PruneTrail` (trilha de auditoria) e
  `PruneNotifications` (caixa do sino).

  ## Por que é compartilhado

  A segunda poda repetiria três decisões nada óbvias da primeira, e cada uma delas é um jeito
  distinto de errar em silêncio:

    * **por clínica, dentro de `Api.Repo.with_clinic/2`** — as tabelas têm RLS (ADR-018) e o job
      roda como `movimento_app`. Um `DELETE` sem a GUC apaga **zero linha** e passa no `mix test`,
      onde o sandbox conecta como superusuário e bypassa RLS. É a armadilha de sempre;
    * **em lotes com teto** — anos de histórico numa transação só seguram conexão do pool e
      incham o WAL de uma vez;
    * **`ctid` no `IN`** — as tabelas podadas não têm chave natural para o recorte, e passar pelo
      `id` seria um caminho mais caro para o mesmo lugar.

  ## Sobre a interpolação do nome da tabela

  `em_lote/3` interpola `tabela` direto no SQL, porque nome de relação não é parâmetro em
  Postgres. O nome tem de vir **sempre** de literal do módulo que chama (lista fixa, escrita à
  mão) — nunca de args do job, params de request ou varredura do catálogo.
  """

  # Teto por rodada. Repetimos até a tabela não devolver mais nada.
  @lote 5_000

  @doc """
  Roda `fun` uma vez por clínica, cada uma sob a própria GUC, e soma os inteiros devolvidos.

  `fun` recebe o `clinic_id` e devolve quantas linhas apagou.
  """
  @spec por_clinica((String.t() -> non_neg_integer())) :: non_neg_integer()
  def por_clinica(fun) when is_function(fun, 1) do
    Enum.reduce(clinicas(), 0, fn clinic_id, total ->
      {:ok, n} = Api.Repo.with_clinic(clinic_id, fn -> fun.(clinic_id) end)
      total + n
    end)
  end

  @doc "Os ids de todas as clínicas (leitura de sistema — a poda não tem ator)."
  @spec clinicas() :: [String.t()]
  def clinicas do
    Api.Accounts.list_clinics!(authorize?: false) |> Enum.map(& &1.id)
  end

  @doc """
  `DELETE` em lotes até esgotar, e devolve o total apagado.

  `condicao` é o `WHERE` (com `$1`, `$2`… casando com `params`); `tabela` **precisa** ser
  literal do módulo chamador — ver o aviso no moduledoc.
  """
  @spec em_lote(String.t(), String.t(), [term()], non_neg_integer()) :: non_neg_integer()
  def em_lote(tabela, condicao, params, total \\ 0) do
    {:ok, %{num_rows: n}} =
      Api.Repo.query(
        """
        DELETE FROM #{tabela}
        WHERE ctid IN (
          SELECT ctid FROM #{tabela}
          WHERE #{condicao}
          LIMIT #{@lote}
        )
        """,
        params
      )

    if n < @lote, do: total + n, else: em_lote(tabela, condicao, params, total + n)
  end

  @doc """
  O instante de corte de uma janela de retenção em dias.

  A ordem é deliberada: `args` do job (poda pontual, e o que o teste usa com `0`) vence a
  config, que vence o default do chamador.
  """
  @spec corte(map(), String.t(), keyword()) :: NaiveDateTime.t()
  def corte(args, chave, opts) do
    dias =
      case Map.get(args, chave) do
        n when is_integer(n) and n >= 0 -> n
        _ -> configurado(opts)
      end

    NaiveDateTime.utc_now() |> NaiveDateTime.add(-dias * 24 * 3600, :second)
  end

  defp configurado(opts) do
    modulo = Keyword.fetch!(opts, :modulo)
    chave = Keyword.fetch!(opts, :chave)
    padrao = Keyword.fetch!(opts, :padrao)

    Application.get_env(:api, modulo, [])[chave] || padrao
  end
end
