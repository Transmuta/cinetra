defmodule ApiWeb.RequestLogger do
  @moduledoc """
  **Um** evento estruturado por requisição, no lugar das duas linhas do Phoenix (doc 62 §7.1).

  ## Por que substituir o logger do Phoenix

  O padrão emite duas linhas — `GET /api/agenda` e `Sent 200 in 953µs` — e isso foi medido: 21
  requisições produziram 41 linhas `[info]`. Duas consequências ruins:

    * **dobra o volume** de um evento que é o mais frequente do sistema;
    * cada linha carrega metade da informação. Responder "quais rotas devolveram 500 hoje" exige
      correlacionar as duas pelo `request_id`, em vez de filtrar um campo.

  Aqui sai um evento só, com método, rota, status e duração juntos.

  ## O path é sanitizado, e isso não é cosmético

  `/api/json/patients/019f7c5b-1bee-7a32-9fad-c3d6f0a83177` levaria o **id do paciente** para a
  agregação de log. O doc 05 §1.3 é explícito: `patient_id` é o único identificador que nunca
  pode sair, porque liga o registro a um titular. Todo segmento que parece UUID (ou número) vira
  `:id`, o que também mantém a cardinalidade baixa — a rota vira `/api/json/patients/:id`, que é
  agrupável.

  ## O que fica de fora

  Health checks. O Traefik bate a cada 10s; com 2 serviços × 2 ambientes são **34.560
  requisições/dia** que não dizem nada. Filtrar aqui (e não na consulta) é o que impede o ruído de
  consumir rede, disco e retenção — no cenário de hoje ele seria a maior parte do volume.
  """

  require Logger

  @handler_id :api_request_logger
  @evento [:phoenix, :endpoint, :stop]

  # Rotas de infraestrutura: alto volume, zero informação. Ver o moduledoc.
  @silenciosas ["/api/health", "/api/ready"]

  @doc "Liga o handler. Chamado uma vez, no boot da aplicação."
  def attach do
    :telemetry.detach(@handler_id)
    :telemetry.attach(@handler_id, @evento, &__MODULE__.handle/4, nil)
  end

  @doc false
  def handle(@evento, %{duration: duracao}, %{conn: conn}, _config) do
    if registrar?(conn), do: registrar(conn, duracao)
    :ok
  rescue
    # **O `:telemetry` DESANEXA um handler que levanta** — em silêncio, e até o próximo boot. Sem
    # este `rescue`, uma requisição de formato inesperado (uma conexão abortada antes da resposta,
    # com `status` ou `request_path` nulos) não derrubaria só a si mesma: derrubaria o log de
    # requisição do sistema inteiro, e o sintoma seria um painel vazio que ninguém desconfia.
    #
    # Perder UMA linha é aceitável. Perder todas, caladamente, não é.
    erro -> Logger.warning("request_logger falhou: #{Exception.message(erro)}")
  end

  def handle(_evento, _medidas, _metadata, _config), do: :ok

  # Um health check que FALHA volta a ser interessante: é o sintoma de que a instância saiu da
  # rotação. Só o 2xx é ruído.
  defp registrar?(%{request_path: path, status: status}) when status < 400,
    do: normalizar(path) not in @silenciosas

  defp registrar?(_conn), do: true

  # Barra final removida antes de comparar. Medido: `/api/health/` (com barra) escapou do filtro
  # exato e foi parar no log. Não é hipótese — um proxy, um monitor ou um copiar-colar de URL
  # acrescenta a barra sem avisar, e o filtro voltaria a deixar passar as 8.640 requisições/dia
  # que ele existe para descartar. A raiz "/" é preservada.
  defp normalizar("/"), do: "/"

  defp normalizar(path) when is_binary(path), do: String.trim_trailing(path, "/")

  defp normalizar(path), do: path

  defp registrar(conn, duracao) do
    ms = System.convert_time_unit(duracao, :native, :microsecond) / 1000

    metadata = [
      method: conn.method,
      route: rota(conn.request_path),
      status: conn.status,
      duration_ms: Float.round(ms, 1)
    ]

    Logger.log(nivel(conn.status), "requisição", metadata)
  end

  # **Só 5xx é `:error`.** O nível codifica *acionabilidade*, não gravidade HTTP: 401 de sessão
  # expirada, 404 de robô e 422 de formulário são rotina, e marcá-los como `warning` treina a
  # equipe a ignorar warning — além de ter inundado a saída da própria suíte quando foi tentado.
  # Filtrar erro de cliente continua trivial no log estruturado (`status >= 400`), sem gastar o
  # nível para isso.
  defp nivel(status) when is_integer(status) and status >= 500, do: :error
  defp nivel(_status), do: :info

  @doc """
  Troca por `:id` todo segmento de path que é identificador.

  Pega UUID (com ou sem hífen — o projeto usa UUIDv7) e número. É a barreira que impede
  `patient_id` de sair do processo, e o que mantém a rota agrupável.
  """
  def rota(path) when not is_binary(path), do: "desconhecida"

  def rota(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      segmento ->
        if identificador?(segmento), do: ":id", else: segmento
    end)
  end

  defp identificador?(segmento) do
    String.match?(
      segmento,
      ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
    ) or
      String.match?(segmento, ~r/^[0-9a-fA-F]{32}$/) or
      String.match?(segmento, ~r/^\d+$/)
  end
end
