defmodule Api.Tracing.OtlpFilter do
  @moduledoc """
  Tira as falhas de export do OTLP do log e as transforma em **métrica**.

  ## O problema que ele resolve

  O exportador do OpenTelemetry tenta enviar spans a cada poucos segundos. Quando o coletor está
  inalcançável, ele loga a falha — em `:info`, e a cada tentativa. Medido no container em
  desenvolvimento: **24 linhas em 200**, 12% do log inteiro.

  Em produção isso é uma inversão perversa: se o Alloy cair, a linha vira volume constante no
  Loki, no nível que ninguém alerta. O sinal de que a observabilidade quebrou fica afogado no
  mesmo canal que ele deveria estar alertando — e consome a retenção que serviria para
  diagnosticar outra coisa (doc 96, O-2).

  ## Por que descartar em vez de subir para `:warning`

  Subir de nível troca ruído em `:info` por ruído em `:warning`, que é pior: treina a equipe a
  ignorar o nível que ela deveria levar a sério. Um throttle resolveria o volume e manteria o
  desenho errado.

  O desenho errado é este: **"o exportador está fora" não é um evento, é um estado.** Estado
  pertence a métrica e alerta; log é para evento. Logar a mesma falha a cada 5 segundos é
  representar um estado com um fluxo de eventos, e é por isso que fica ruim em qualquer nível.

  Então a linha é descartada, e no lugar dela sai um evento de telemetria que o `Api.PromEx`
  transforma no contador `cinetra_otlp_export_failures_total`. O alerta ("falhas > 0 nos últimos
  5 min") vira regra do Prometheus, que é onde alguém de fato olha.

  Nada se perde: hoje, com a linha em `:info`, ninguém descobria a queda do coletor de qualquer
  forma.

  ## O recorte

  Casa **só** a falha de export, pelo módulo de origem (`:otel_exporter_otlp`, no `mfa` do
  metadata) e pela forma da mensagem. Qualquer outra coisa que o exportador tenha a dizer continua
  passando — filtro largo demais aqui esconderia erro de configuração do SDK, que é justamente o
  que se quer ver na largada.

  O nome do módulo foi confirmado na fonte (`deps/opentelemetry_exporter/src/otel_exporter_otlp.erl`),
  e não deduzido do nome do pacote: a primeira versão deste filtro casava
  `"opentelemetry_exporter"` e **não filtrava nada** — o pacote se chama assim, o módulo não.
  """

  @evento [:api, :otlp, :export_failure]

  @doc "O evento de telemetria emitido no lugar da linha de log. Ver `Api.PromEx`."
  def evento, do: @evento

  @doc """
  Filtro do `:logger` (ver `:logger.add_primary_filter/2`).

  Devolve `:stop` para descartar a linha, ou `:ignore` para deixá-la seguir o caminho normal.
  """
  def filtrar(%{msg: msg, meta: meta} = evento_log, _opts) do
    if falha_de_export?(msg, meta) do
      :telemetry.execute(@evento, %{count: 1}, %{})
      :stop
    else
      evento_log
    end
  end

  def filtrar(evento_log, _opts), do: evento_log

  # A mensagem chega em duas formas dependendo de quem loga: `{:string, texto}` do Erlang, e
  # `{format, args}` do `:logger` clássico. Cobrir as duas evita o filtro funcionar em dev e
  # falhar em produção por causa de um detalhe de formatação.
  defp falha_de_export?(msg, meta) do
    do_exportador?(meta) and texto(msg) =~ "export failed"
  end

  defp do_exportador?(%{mfa: {modulo, _f, _a}}),
    do: modulo |> to_string() |> String.contains?("otel_exporter")

  defp do_exportador?(_meta), do: false

  defp texto({:string, texto}) when is_binary(texto), do: texto
  defp texto({:string, texto}) when is_list(texto), do: IO.iodata_to_binary(texto)
  defp texto({formato, _args}) when is_binary(formato), do: formato
  defp texto({formato, _args}) when is_list(formato), do: to_string(formato)
  defp texto(%{} = report), do: inspect(report)
  defp texto(_msg), do: ""
end
