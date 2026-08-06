defmodule Api.AlertasMetricasTest do
  @moduledoc """
  **Toda métrica que um alerta cita tem de ser raspada.** R-M14 (doc 95, onda 4 do doc 102).

  ## O bug, que é de uma classe e não de um caso

  `grafana-alertas.yml` manda o operador, no meio do alerta *"pipeline de log parado"* às 3h,
  comparar três contadores: `loki_source_docker_target_entries_total`,
  `loki_write_dropped_entries_total` e `loki_distributor_lines_received_total`. **Nenhum job do
  Prometheus raspava nenhum dos três.**

  O que isso produz não é um painel vazio — é uma **investigação mandada para o lado errado**. Quem
  abre o runbook às 3h, roda as três consultas e recebe "No data" nas três conclui, razoavelmente,
  que a coleta de métrica também caiu. O alerta que existia para orientar passa a desorientar.

  E o mesmo vale para o `expr:` de cada regra: um alerta cuja expressão referencia métrica não
  raspada não fica vermelho nem verde — ele fica em `NoData`, e o `noDataState` de cada regra
  decide o resto. Duas das regras estão em `noDataState: OK`, o que significa **silêncio
  permanente** por um erro de digitação.

  ## Por que este teste é o análogo do `verificar-paineis.py`

  Aquele script já faz isto para **dashboards**: toda métrica desenhada tem de existir. Alertas —
  que são o que acorda alguém — não tinham equivalente. Este arquivo é ele.

  ## O que ele NÃO prova

  Que a métrica **responde** no Prometheus de pé. Ele prova que ela está numa lista de manter de
  algum job — ou seja, que ela foi pensada. Um nome de métrica que não existe no alvo (o caso do
  Tempo, cujos nomes não puderam ser verificados ao vivo) passa aqui e falha lá. Essa metade é da
  §18 do `verificar.sh`, que consulta o Prometheus de verdade.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Repo

  @alertas "deploy/observability/grafana-alertas.yml"
  @prometheus "deploy/observability/prometheus.yml"

  # Os prefixos dos exportadores que este stack raspa. Recortar por prefixo é o que separa nome de
  # métrica de token de LogQL: as regras de log usam `{env="prod"} |= "..."`, e uma extração
  # genérica de identificador com underscore casaria `count_over_time`, `drop_counter_reason` e o
  # resto do vocabulário do Loki.
  @prefixos ~w(node_ container_ loki_ tempo_ grafana_alerting_ grafana_build alloy_ otelcol_ api_prom_ex_ prometheus_)

  # Vem do laço de raspagem do Prometheus, não do alvo — então nenhuma lista de manter a contém, e
  # cobrá-la aqui daria falso positivo. É o que o alerta `cinetra-coleta-de-metrica-parada` usa.
  @do_laco_de_raspagem ~w(up)

  setup_all do
    {:ok, alertas: Repo.ler_do_repo(@alertas), prometheus: Repo.ler_do_repo(@prometheus)}
  end

  test "toda métrica citada num alerta está numa lista de manter de algum job", %{
    alertas: alertas,
    prometheus: prometheus
  } do
    listas = listas_de_manter(prometheus)
    citadas = metricas_citadas(alertas)

    # Anti-vacuidade nas duas pontas: sem isto, uma mudança de forma em qualquer um dos dois
    # arquivos faria este teste passar verde sem ter comparado nada.
    assert length(listas) >= 4, "achei só #{length(listas)} listas de manter no prometheus.yml"

    assert length(citadas) >= 5,
           "achei só #{length(citadas)} métricas citadas: #{inspect(citadas)}"

    for metrica <- citadas do
      assert Enum.any?(listas, &Regex.match?(&1, metrica)),
             """
             `#{metrica}` é citada em `grafana-alertas.yml` e **nenhum job do Prometheus a raspa**.

             Se ela está num `expr:`, a regra fica em `NoData` — e o `noDataState` decide se isso
             vira silêncio permanente ou alerta falso. Se está numa anotação, o runbook manda o
             operador consultar, às 3h, uma métrica que devolve "No data" — e a conclusão natural
             de quem lê isso no meio de um incidente é que a coleta caiu, o que manda a
             investigação para o lado errado.

             Conserto: acrescente o nome à `metric_relabel_configs` do job certo em
             `prometheus.yml`, ou crie o job se o alvo ainda não for raspado.
             """
    end
  end

  # R-B7 (onda 4). Importa porque runbook cita por NÚMERO: `grafana-alertas.yml` manda "rode
  # `verificar.sh`, seção 9", e `criar-volume-limitado.sh` manda "seção 10 mostra o uso deste
  # sistema de arquivos". Havia duas seções "13" e a ordem estava embaralhada (11 → 13 → 12 → 13),
  # então metade das referências apontava para o lugar errado — e quem seguisse o runbook no meio
  # de um incidente leria a checagem de outra coisa.
  test "as seções do verificar.sh são únicas e estão em ordem de execução" do
    numeros =
      ~r/titulo "(\d+)\./
      |> Regex.scan(Repo.ler_do_repo("deploy/observability/verificar.sh"))
      |> Enum.map(fn [_todo, n] -> String.to_integer(n) end)

    assert length(numeros) >= 15, "achei só #{length(numeros)} seções — a extração quebrou?"

    assert numeros == Enum.to_list(1..length(numeros)),
           """
           Os números de seção do `verificar.sh` não são 1..#{length(numeros)} em ordem: \
           #{inspect(numeros)}

           Runbook cita seção por NÚMERO (`grafana-alertas.yml` manda "rode a seção 9"). Número \
           duplicado ou fora de ordem manda quem está no meio de um incidente para a checagem \
           errada.
           """
  end

  # Os `regex:` das ações `keep`, compilados como o Prometheus os aplica: **ancorados nas duas
  # pontas**. Sem as âncoras, `loki_build_info` casaria por engano com `loki_build_info_extra`, e o
  # teste passaria a afirmar mais do que o Prometheus faz.
  defp listas_de_manter(prometheus) do
    ~r/action:\s*keep\s*\n\s*regex:\s*(.+)/
    |> Regex.scan(prometheus)
    |> Enum.map(fn [_todo, regex] -> Regex.compile!("\\A(?:#{String.trim(regex)})\\z") end)
  end

  defp metricas_citadas(alertas) do
    ~r/\b[a-z][a-z0-9_]*\b/
    |> Regex.scan(alertas)
    |> Enum.map(&hd/1)
    |> Enum.filter(fn nome -> Enum.any?(@prefixos, &String.starts_with?(nome, &1)) end)
    |> Enum.reject(&(&1 in @do_laco_de_raspagem))
    # `grafana_folder` e `grafana_data` aparecem como LABEL de agrupamento e como nome de volume,
    # não como métrica. O recorte por prefixo não distingue os dois — e alargar o prefixo para
    # `grafana_alerting_`/`grafana_build` resolve sem lista de exceção.
    |> Enum.uniq()
    |> Enum.sort()
  end
end
