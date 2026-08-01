defmodule Api.Housekeeping.PruneNotifications do
  @moduledoc """
  Poda a caixa de notificações in-app (#54, P3 do doc 32 — "lista sem LIMIT **e tabela sem
  expurgo**"). O LIMIT foi resolvido pela paginação da `:inbox`; o expurgo é este job.

  ## A retenção é assimétrica, e isso é o ponto

    * **lida** — #{Application.compile_env(:api, [__MODULE__, :reter_lidas_dias], 90)} dias. Já
      cumpriu o papel: o usuário viu. O que sobra é histórico do sino, não registro de auditoria
      (esse é a trilha, e tem poda própria em `Api.Housekeeping.PruneTrail`);
    * **não-lida** — #{Application.compile_env(:api, [__MODULE__, :reter_dias], 365)} dias. Uma
      não-lida é trabalho pendente; apagá-la na janela curta seria sumir com um aviso que ninguém
      leu. O teto existe só para que a caixa **abandonada** (usuário que nunca mais entrou)
      também não cresça para sempre.

  Os dois números são decisão humana e moram na config:

      config :api, Api.Housekeeping.PruneNotifications, reter_lidas_dias: 90, reter_dias: 365

  O job aceita `%{"reter_lidas_dias" => n, "reter_dias" => n}` para uma poda pontual (é o que o
  teste usa com `0`).

  ## Como respeita a RLS

  Igual à poda da trilha, e pelo mesmo motivo: varredura **por clínica** dentro de
  `Api.Repo.with_clinic/2`. O mecanismo (lote, `ctid`, GUC) está em `Api.Housekeeping.Poda` —
  esta é a segunda poda do projeto, e ter duas cópias da mesma sutileza é como uma delas
  envelhece errado.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Logger

  alias Api.Housekeeping.Poda

  @tabela "notifications"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    corte_lidas = corte_lidas(args)
    corte_geral = corte_geral(args)

    apagadas =
      Poda.por_clinica(fn clinic_id ->
        Poda.em_lote(
          @tabela,
          """
          clinic_id = $1
          AND (
            (read_at IS NOT NULL AND inserted_at < $2)
            OR (read_at IS NULL AND inserted_at < $3)
          )
          """,
          [Ecto.UUID.dump!(clinic_id), corte_lidas, corte_geral],
          clinic_id
        )
      end)

    if apagadas > 0 do
      Logger.info(
        "PruneNotifications: #{apagadas} notificações apagadas " <>
          "(lidas antes de #{NaiveDateTime.to_iso8601(corte_lidas)}, " <>
          "não-lidas antes de #{NaiveDateTime.to_iso8601(corte_geral)})"
      )
    end

    {:ok, %{apagadas: apagadas}}
  end

  @doc "O corte das lidas que o job usaria agora — exposto para o doc e para diagnóstico."
  def corte_lidas(args \\ %{}),
    do:
      Poda.corte(args, "reter_lidas_dias",
        modulo: __MODULE__,
        chave: :reter_lidas_dias,
        padrao: 90
      )

  @doc "O corte das não-lidas (o teto absoluto da caixa)."
  def corte_geral(args \\ %{}),
    do: Poda.corte(args, "reter_dias", modulo: __MODULE__, chave: :reter_dias, padrao: 365)
end
