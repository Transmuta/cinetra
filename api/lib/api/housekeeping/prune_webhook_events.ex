defmodule Api.Housekeeping.PruneWebhookEvents do
  @moduledoc """
  Poda a tabela de corpos de webhook já vistos (`webhook_events`, doc 96 S-7).

  ## Por que ela precisa de poda, e por que a poda é diferente das outras três

  A tabela cresce **uma linha por evento de webhook** — entrega, leitura, falha e resposta de todo
  paciente de toda clínica. É a única das podadas que **não tem `clinic_id`**: o evento chega antes
  de existir tenant, que é o problema inteiro que o `Api.Messaging.Webhooks` resolve. Logo, aqui
  não há GUC para pôr nem varredura por clínica a fazer — o que sobra é o `DELETE` por idade, e é
  por isso que este job não usa `Api.Housekeeping.Poda.por_clinica/1`.

  Ele **usa** o `em_lote` do mesmo módulo, porém, pela razão de sempre: um ano de eventos numa
  transação só segura conexão do pool.

  ## A janela é o alcance da defesa contra replay

  **#{Application.compile_env(:api, [__MODULE__, :reter_dias], 365)} dias**, e o número é decisão
  humana:

      config :api, Api.Housekeeping.PruneWebhookEvents, reter_dias: 365

  Diferente das outras podas, aqui a retenção **é** a proteção: um corpo assinado da Zernio não
  expira (não há timestamp no material assinado), então o dia em que a linha some é o dia em que
  aquele payload volta a poder ser reentregue. Por isso a janela é larga — o custo é irrisório
  (um digest de 64 caracteres por evento) e o que ela compra é o alcance da defesa.

  **Limitação aceita:** um payload capturado e guardado por mais de um ano volta a funcionar. O
  conserto definitivo não está do nosso lado — exige a Zernio assinar timestamp, como o Svix do
  Resend já faz.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Logger

  alias Api.Housekeeping.Poda

  @tabela "webhook_events"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    corte = corte(args)

    apagados = Poda.em_lote_global(@tabela, "inserted_at < $1", [corte])

    if apagados > 0 do
      Logger.info(
        "PruneWebhookEvents: #{apagados} eventos apagados " <>
          "(corte #{NaiveDateTime.to_iso8601(corte)})"
      )
    end

    {:ok, %{apagados: apagados}}
  end

  @doc "O instante de corte que o job usaria agora — exposto para o doc e para diagnóstico."
  def corte(args \\ %{}),
    do: Poda.corte(args, "reter_dias", modulo: __MODULE__, chave: :reter_dias, padrao: 365)
end
