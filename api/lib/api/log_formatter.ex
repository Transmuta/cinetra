defmodule Api.LogFormatter do
  @moduledoc """
  O JSON de uma linha de log, com os campos **na raiz** — o formato que o Loki consegue consultar.

  ## Por que não o `LoggerJSON.Formatters.Basic`

  Ele aninha todo o metadata sob a chave `metadata`:

      {"message":"requisição","severity":"info","time":"…",
       "metadata":{"status":422,"route":"/api/patients/:id"}}

  E o parser `| json` do Loki **achata objeto aninhado com `_`**. Os rótulos que existiam eram
  `metadata_status` e `metadata_route`; os treze dashboards perguntavam por `status` e `route`.
  Consulta certa sobre campo inexistente não dá erro — devolve zero linhas. O resultado, medido em
  produção (doc 99): todo painel de 4xx abria "No data" com o log inteiro presente no Loki, o que
  é indistinguível de "não houve nenhum 4xx".

  Aqui a mesma linha sai assim:

      {"time":"…","severity":"info","message":"requisição",
       "status":422,"route":"/api/patients/:id","duration_ms":12.3}

  É também o formato que o BFF já emitia (`web/src/lib/server/log.ts`) — cujo moduledoc afirma que
  "o formato acompanha o do lado Elixir para que uma consulta no Loki não precise saber de qual
  serviço veio o registro". Isso passou a ser verdade.

  ## O contrato, campo a campo

  Três chaves são **estrutura**, e valem para toda linha de todo serviço:

    * `time` — ISO 8601 em UTC;
    * `severity` — `info` | `warning` | `error`. É de onde o Alloy extrai o rótulo `level`
      (`deploy/observability/alloy.alloy`, estágio 4); renomear esta chave apaga o rótulo em
      silêncio;
    * `message` — o texto do evento.

  O resto são campos do evento, e numa requisição HTTP eles cobrem os dois lados:

  | Lado | Campos |
  | --- | --- |
  | request | `method`, `route` (com `:id` no lugar de identificador), `client_ip` |
  | response | `status`, `duration_ms` |
  | correlação | `request_id`, `trace_id`, `clinic_id`, `actor_id` |

  Quem produz esses campos é o `ApiWeb.RequestLogger`; a lista do que sai fica em `config/prod.exs`
  e é uma **allowlist** — metadata fora dela é descartada aqui.

  **Corpo de request e de response entram na linha — só em 4xx/5xx, e só redigidos** (ADR-025).
  São mais três campos, produzidos pelo `ApiWeb.RequestLogger`:

  | Campo | O quê |
  | --- | --- |
  | `payload` | o `body_params` da requisição recusada |
  | `query` | a query string, quando há (num GET ela **é** o payload) |
  | `response` | o corpo devolvido, capturado por `ApiWeb.Plugs.CapturarResposta` |

  Os três passam por `Api.LogRedacao` antes de entrar no `Logger`: todo campo da blocklist vira
  `"***"`. Requisição bem-sucedida não carrega nenhum dos três — é o que mantém dado de paciente
  fora do log em ~todo o tráfego. Ler o moduledoc de `Api.LogRedacao` antes de mexer nisso: ele
  descreve o que a camada cobre, e principalmente o que ela **não** cobre.

  ## Evento estruturado vira campo, não texto

  `Oban.Telemetry.attach_default_logger(encode: false)` (ver `Api.Application`) entrega um **mapa**
  ao Logger. Esse mapa é achatado na raiz, pelo mesmo motivo do metadata: é assim que `worker` e
  `queue` viram rótulo consultável em vez de `message_worker`. O `event` do próprio Oban
  (`job:stop`, `job:exception`) vira a `message` — sem ele a coluna de mensagem do painel de log
  ficaria vazia em toda linha de job, e campo do contrato presente em metade das linhas é pior que
  campo ausente.

  As três chaves de estrutura são escritas **por último**: campo de evento não sobrescreve
  `severity` nem `time`, aconteça o que acontecer com o mapa que chegar.
  """

  import LoggerJSON.Formatter.{DateTime, MapBuilder, Message, Metadata, RedactorEncoder}
  require LoggerJSON.Formatter, as: Formatter

  @behaviour Formatter

  @encoder Formatter.encoder()

  # Nunca chegam à linha, mesmo com `metadata: :all`. A `conn` arrastaria cabeçalhos, cookies e
  # corpo; os dois de OTel já viajam como `trace_id`, carimbado pelo `ApiWeb.Plugs.TraceMetadata`.
  @descartadas ~w[conn otel_span_id otel_trace_id]a

  @impl Formatter
  def new(opts \\ []), do: {__MODULE__, config(opts)}

  @impl Formatter
  def format(%{level: nivel, meta: meta, msg: msg}, config_or_opts) do
    %{encoder_opts: encoder_opts, metadata: seletor, redactors: redactors} =
      config(config_or_opts)

    campos_do_evento =
      msg
      |> format_message(meta, %{
        binary: &{:texto, IO.chardata_to_string(&1)},
        structured: &{:campos, Map.new(&1)},
        crash: fn texto, _motivo -> {:texto, IO.chardata_to_string(texto)} end
      })
      |> achatar(redactors)

    campos_do_metadata =
      meta
      |> take_metadata(seletor)
      |> maybe_update(:file, &IO.chardata_to_string/1)
      |> encode(redactors)

    linha =
      campos_do_evento
      |> Map.merge(campos_do_metadata)
      |> Map.merge(%{time: utc_time(meta), severity: Atom.to_string(nivel)})
      |> @encoder.encode_to_iodata!(encoder_opts)

    [linha, "\n"]
  end

  defp config(%{} = map), do: map

  defp config(opts) do
    opts = Keyword.new(opts)

    %{
      encoder_opts: Keyword.get_lazy(opts, :encoder_opts, &Formatter.default_encoder_opts/0),
      metadata: update_metadata_selector(Keyword.get(opts, :metadata, []), @descartadas),
      redactors: Keyword.get(opts, :redactors, [])
    }
  end

  defp achatar({:texto, texto}, redactors), do: %{message: encode(texto, redactors)}

  defp achatar({:campos, campos}, redactors) do
    campos = encode(campos, redactors)

    maybe_put(campos, :message, campos[:event])
  end
end
