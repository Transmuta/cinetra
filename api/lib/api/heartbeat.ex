defmodule Api.Heartbeat do
  @moduledoc """
  Sinal de vida dos jobs agendados, para um monitor **externo** (doc 62 §9).

  ## O problema que isto resolve

  Alerta responde "algo quebrou". Heartbeat responde a pergunta oposta, e mais difícil: **"algo
  deixou de acontecer"**. Nenhum log, nenhuma métrica e nenhum health check detectam um cron que
  simplesmente parou de rodar — não há erro, não há linha, não há requisição. O sistema fica em
  silêncio, e silêncio é indistinguível de "está tudo bem".

  O `docs/59 §13` já tinha nomeado o caso concreto e o deixado aberto: *"alerta se o `backup-cron`
  parar — backup que morre em silêncio só aparece no dia do incidente"*.

  ## Por que o monitor é de terceiro

  Este é o único componente da observabilidade que **precisa** viver fora da nossa infra. Um
  vigia hospedado na mesma máquina (ou na mesma tenancy) morre junto com o que deveria vigiar. E
  ele não carrega risco de PHI: só recebe um GET numa URL opaca, sem corpo.

  ## Como funciona

  O job não sabe que existe heartbeat. O gancho é o telemetry do Oban:

    * `[:oban, :job, :stop]`      → o job terminou bem  → ping em `<url>`;
    * `[:oban, :job, :exception]` → o job estourou      → ping em `<url>/fail`.

  Distinguir os dois importa: "não rodou" e "rodou e falhou" pedem investigações diferentes, e um
  monitor que só sabe do silêncio trata as duas como a mesma coisa.

  ## Duas armadilhas tratadas aqui

  1. **Handler de telemetry que levanta é DESANEXADO pelo `:telemetry`**, em silêncio e para
     sempre (até o próximo boot). Um heartbeat com bug derrubaria não só a si mesmo. Por isso todo
     o corpo roda dentro de `try`.
  2. **Handler roda no processo que emitiu o evento** — aqui, o processo do job do Oban. Uma
     chamada HTTP síncrona seguraria o slot da fila pelo tempo da rede alheia. O ping sai numa
     `Task` desacoplada, e o resultado dela não interessa a ninguém.

  ## Configuração — dois jeitos, e o primeiro é o recomendado

  **Por slug (uma env por ambiente).** `HEARTBEAT_BASE_URL` guarda a raiz com a chave do projeto
  (`https://hc-ping.com/<ping-key>`) e cada worker tem um slug fixo, definido em código. A URL sai
  de `base <> "/" <> slug`. São **2 variáveis no total** (uma por stack) em vez de 14 — e o que
  distingue produção de homologação é a chave, não 14 colagens sem errar nenhuma.

  Um slug digitado errado falha ALTO, e isso é de propósito: o serviço cria um check novo para o
  slug desconhecido, enquanto o check real deixa de receber sinal e alarma. O erro aparece no
  primeiro ciclo, em vez de virar um monitor verde que não observa nada.

  **Por URL explícita (uma env por job).** `urls` mapeia worker → URL completa e tem precedência.
  Existe para quem prefere as URLs por UUID, ou para um monitor que não use o esquema de slug.

  Sem nenhum dos dois, o worker é ignorado — é o que mantém dev e teste silenciosos.
  """

  require Logger

  @doc "Liga o gancho. Chamado uma vez, no boot."
  def attach do
    :telemetry.detach(__MODULE__)

    :telemetry.attach_many(
      __MODULE__,
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle/4,
      nil
    )
  end

  @doc false
  def handle([:oban, :job, evento], _medidas, %{job: %{worker: worker}}, _config) do
    case url(worker) do
      nil -> :ok
      url -> disparar(if evento == :exception, do: "#{url}/fail", else: url)
    end
  rescue
    # Ver armadilha 1 no moduledoc: sem isto, um erro aqui desanexa o handler e o heartbeat morre
    # calado — exatamente a falha que ele existe para detectar.
    erro -> Logger.warning("heartbeat falhou: #{Exception.message(erro)}")
  end

  def handle(_evento, _medidas, _metadata, _config), do: :ok

  defp url(worker) when is_binary(worker) do
    config = Application.get_env(:api, __MODULE__, [])

    # A URL explícita vence: quem a configurou fez uma escolha, e derivar por cima dela seria
    # ignorá-la em silêncio.
    case config |> Keyword.get(:urls, %{}) |> Map.get(worker) do
      nil -> por_slug(config, worker)
      url -> url
    end
  end

  defp url(_worker), do: nil

  defp por_slug(config, worker) do
    base = Keyword.get(config, :base_url)
    slug = config |> Keyword.get(:slugs, %{}) |> Map.get(worker)
    # Prefixo por ambiente (`prod-`, `hml-`). Com ele, os dois stacks podem dividir UMA chave de
    # projeto e ainda ter checks distintos — `prod-reminder` e `hml-reminder`. Vazio quando cada
    # ambiente tem projeto próprio, que é a alternativa. Ver doc 62 §9.4.
    prefixo = Keyword.get(config, :slug_prefix) || ""

    if base in [nil, ""] or is_nil(slug),
      do: nil,
      else: "#{String.trim_trailing(base, "/")}/#{prefixo}#{slug}"
  end

  # Ver armadilha 2: desacoplado do processo do job. `Task.start/1` (não `async`) porque ninguém
  # espera resposta — heartbeat que falha é problema do heartbeat, não do trabalho que ele observa.
  defp disparar(url) do
    Task.start(fn ->
      try do
        Req.get(url, receive_timeout: 5_000, retry: false)
      rescue
        erro -> Logger.warning("heartbeat não alcançou o monitor: #{Exception.message(erro)}")
      end
    end)

    :ok
  end
end
