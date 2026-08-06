defmodule Api.PromEx.Otlp do
  @moduledoc """
  O sinal de saúde do **exportador de traces**: `cinetra_otlp_export_failures_total`.

  Contrapartida da linha de log que o `Api.Tracing.OtlpFilter` descarta (doc 96, O-2). "O
  exportador não alcança o coletor" é um **estado**, e estado se observa por métrica e alerta —
  não por uma linha de log repetida a cada 5 segundos, que afoga o próprio sinal que carrega.

  ## O alerta que este contador habilita

      # aumento nas falhas de export nos últimos 5 min = o coletor está inalcançável
      increase(cinetra_otlp_export_failures_total[5m]) > 0

  Sem ele, a queda do Alloy é invisível: os spans param de chegar, os painéis ficam vazios, e o
  único aviso está num `:info` que ninguém lê. Com ele, a ausência de trace tem dono.

  ## Por que um contador, e não um gauge de "up"

  Um gauge exigiria alguém perguntar ativamente ao exportador se ele está bem — e o exportador
  não expõe isso. O que existe é o evento de falha, e contá-lo responde a mesma pergunta pela
  derivada: taxa zero é saúde, taxa positiva é problema.
  """
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    Event.build(:cinetra_otlp_event_metrics, [
      counter(
        [:cinetra, :otlp, :export, :failures, :total],
        event_name: Api.Tracing.OtlpFilter.evento(),
        description: "Falhas de envio de spans ao coletor OTLP (o Alloy).",
        measurement: :count
      )
    ])
  end
end
