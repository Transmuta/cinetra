defmodule Api.Housekeeping.PruneTrail do
  @moduledoc """
  Poda a trilha de auditoria (`*_versions`) mais velha que a janela de retenção.

  ## Por que existe

  A trilha é a tabela que mais cresce do sistema — o `TrailMixin` já diz isso, e é por isso que a
  leitura da tela de auditoria é paginada. O que faltava era o outro lado: **nada** a diminuía. O
  bate-volta da Onda 3 mediu `appointments_versions` em 15 MB contra 5.256 kB da tabela base (3×),
  numa clínica de dev, com o único cron de poda do projeto removido junto com a reserva de vaga
  (doc 39). Sem retenção, o custo é monotônico — e cada `INSERT`/`UPDATE` da agenda escreve ali.

  ## A retenção é decisão humana, e mora na config

  O default é #{Application.compile_env(:api, [__MODULE__, :reter_dias], 365)} dias. É um número
  escolhido, não derivado: cobre o "quem mudou isso?" de um ano inteiro, que é o horizonte que a
  tela de auditoria serve. Mudar é uma linha em `config/config.exs`:

      config :api, Api.Housekeeping.PruneTrail, reter_dias: 730

  O job aceita `%{"reter_dias" => n}` nos args para uma poda pontual mais agressiva (é o que o
  teste usa com `0`). **Não** há caminho de aplicação que apague versão: a trilha continua
  imutável para quem chega de fora (`TrailMixin` proíbe escrita); quem poda é este job.

  ## Como respeita a RLS

  As tabelas de versão têm a mesma `tenant_isolation` das tabelas base (ADR-018), e o job roda como
  `movimento_app` no servidor real. Por isso a varredura é **por clínica**, cada uma dentro de
  `Api.Repo.with_clinic/2` — um `DELETE` sem GUC apagaria zero linha (e passaria no `mix test`,
  onde o sandbox conecta como superusuário: a armadilha de sempre).

  O `DELETE` é em lote com teto (`@lote`), repetido até não sobrar nada: uma clínica com anos de
  trilha não vira uma transação de milhões de linhas segurando conexão do pool.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Logger

  # As duas tabelas de versão que o projeto tem hoje (`Appointment` e `Attendance` usam
  # AshPaperTrail). A lista é explícita de propósito: uma tabela nova de versão deve entrar aqui
  # por decisão, não por varredura automática do catálogo.
  @tabelas ~w(appointments_versions attendances_versions)

  @lote 5_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    corte = corte(args)

    apagadas =
      Enum.reduce(clinicas(), 0, fn clinic_id, total ->
        {:ok, n} =
          Api.Repo.with_clinic(clinic_id, fn ->
            Enum.reduce(@tabelas, 0, &(&2 + podar(&1, clinic_id, corte)))
          end)

        total + n
      end)

    if apagadas > 0 do
      Logger.info(
        "PruneTrail: #{apagadas} versões apagadas (corte #{NaiveDateTime.to_iso8601(corte)})"
      )
    end

    {:ok, %{apagadas: apagadas}}
  end

  @doc "O instante de corte que o job usaria agora — exposto para o doc e para diagnóstico."
  def corte(args \\ %{}) do
    dias =
      case Map.get(args, "reter_dias") do
        n when is_integer(n) and n >= 0 -> n
        _ -> Application.get_env(:api, __MODULE__, [])[:reter_dias] || 365
      end

    NaiveDateTime.utc_now() |> NaiveDateTime.add(-dias * 24 * 3600, :second)
  end

  defp clinicas do
    Api.Accounts.list_clinics!(authorize?: false) |> Enum.map(& &1.id)
  end

  # Lotes até esgotar. `ctid` no `IN` porque a tabela de versão não tem chave natural para o
  # recorte e o `id` seria só um caminho mais caro para o mesmo lugar.
  defp podar(tabela, clinic_id, corte, total \\ 0) do
    {:ok, %{num_rows: n}} =
      Api.Repo.query(
        """
        DELETE FROM #{tabela}
        WHERE ctid IN (
          SELECT ctid FROM #{tabela}
          WHERE clinic_id = $1 AND version_inserted_at < $2
          LIMIT #{@lote}
        )
        """,
        [Ecto.UUID.dump!(clinic_id), corte]
      )

    if n < @lote, do: total + n, else: podar(tabela, clinic_id, corte, total + n)
  end
end
