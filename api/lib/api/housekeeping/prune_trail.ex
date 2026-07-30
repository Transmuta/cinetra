defmodule Api.Housekeeping.PruneTrail do
  @moduledoc """
  Poda a trilha de auditoria (`audit_events`) mais velha que a janela de retenção.

  ## Por que existe

  A trilha é a tabela que mais cresce do sistema, e é por isso que a leitura da tela de auditoria
  é paginada. O que faltava era o outro lado: **nada** a diminuía. O bate-volta da Onda 3 mediu a
  trilha de então em 15 MB contra 5.256 kB da tabela base (3×), numa clínica de dev. Sem
  retenção o custo é monotônico — e agora **doze** recursos escrevem ali, mais a trilha de
  leitura de ficha e a de acesso negado (doc 63).

  ## A retenção é decisão humana, e mora num lugar só

  **90 dias** (D-Aud5), e o número vive em `Api.Audit.retencao_dias/0` — não aqui. Este
  moduledoc já foi o segundo lugar onde ele morava, e ficou para trás exatamente como o `@doc` de
  `corte/1` previa: anunciava 365 enquanto o job podava em 90. Era um
  `Application.compile_env(…, 365)` interpolado na prosa, lendo uma chave que ninguém configura.
  Fonte única não é só sobre o código.

  Mudar é uma linha em `config/config.exs`:

      config :api, Api.Audit, retencao_dias: 365

  O job aceita `%{"reter_dias" => n}` nos args para uma poda pontual mais agressiva (é o que o
  teste usa com `0`). **Não** há caminho de aplicação que apague evento: a trilha é imutável para
  quem chega de fora (a policy do `Api.Audit.Event` proíbe escrita a todos); quem poda é este job.

  ## Como respeita a RLS

  `audit_events` tem a mesma `tenant_isolation` das demais tabelas (ADR-018), e o job roda como
  `cinetra_app` no servidor real. Por isso a varredura é **por clínica**, cada uma dentro de
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

  # Uma tabela só desde o doc 63: `audit_events` é a trilha inteira do sistema (antes eram duas
  # tabelas de versão do `AshPaperTrail`, uma por recurso, e a poda tinha de conhecer as duas).
  #
  # A lista continua explícita de propósito: uma tabela nova deve entrar aqui por decisão, não
  # por varredura automática do catálogo.
  @tabelas ~w(audit_events)

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

  @doc """
  O instante de corte que o job usaria agora — exposto para o doc e para diagnóstico.

  O prazo é o de `Api.Audit.retencao_dias/0` (90 dias, D-Aud5) e **não** um número escrito aqui:
  a decisão de retenção é uma só, revisível com o jurídico, e ter o padrão em dois lugares era o
  jeito de um deles ficar para trás. `args` do job continua vencendo (é o que o teste usa com 0).
  """
  def corte(args \\ %{}),
    do:
      Poda.corte(args, "reter_dias",
        modulo: __MODULE__,
        chave: :reter_dias,
        padrao: Api.Audit.retencao_dias()
      )

  # `at` é o relógio do ESCOPO (ADR-009), não o `inserted_at` da linha: a trilha é podada pelo
  # instante em que o evento aconteceu, que é o mesmo que a tela mostra.
  defp podar(tabela, clinic_id, corte) do
    Poda.em_lote(tabela, "clinic_id = $1 AND at < $2", [
      Ecto.UUID.dump!(clinic_id),
      corte
    ])
  end
end
