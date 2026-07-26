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

  O `DELETE` é em lote com teto, repetido até não sobrar nada: uma clínica com anos de trilha não
  vira uma transação de milhões de linhas segurando conexão do pool.

  Esse mecanismo (GUC por clínica, lote, `ctid`) mora em `Api.Housekeeping.Poda` desde que a
  caixa de notificações ganhou poda própria e viraria a segunda cópia dele.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Logger

  alias Api.Housekeeping.Poda

  # As duas tabelas de versão que o projeto tem hoje (`Appointment` e `Attendance` usam
  # AshPaperTrail). A lista é explícita de propósito: uma tabela nova de versão deve entrar aqui
  # por decisão, não por varredura automática do catálogo.
  @tabelas ~w(appointments_versions attendances_versions)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    corte = corte(args)

    apagadas =
      Poda.por_clinica(fn clinic_id ->
        Enum.reduce(@tabelas, 0, &(&2 + podar(&1, clinic_id, corte)))
      end)

    if apagadas > 0 do
      Logger.info(
        "PruneTrail: #{apagadas} versões apagadas (corte #{NaiveDateTime.to_iso8601(corte)})"
      )
    end

    {:ok, %{apagadas: apagadas}}
  end

  @doc "O instante de corte que o job usaria agora — exposto para o doc e para diagnóstico."
  def corte(args \\ %{}),
    do: Poda.corte(args, "reter_dias", modulo: __MODULE__, chave: :reter_dias, padrao: 365)

  defp podar(tabela, clinic_id, corte) do
    Poda.em_lote(tabela, "clinic_id = $1 AND version_inserted_at < $2", [
      Ecto.UUID.dump!(clinic_id),
      corte
    ])
  end
end
