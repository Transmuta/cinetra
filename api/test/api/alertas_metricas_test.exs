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

  # ---------------------------------------------------------------------------------------------
  # 2026-08-06. O alerta `cinetra-coleta-de-metrica-parada` chegou por e-mail dizendo, literalmente:
  #
  #     [no value] ([no value]) parou de responder à raspagem
  #
  # O `summary` promete `{{ $labels.job }} ({{ $labels.instance }})`, mas a consulta era `min(up)`
  # — uma agregação **sem `by`**, que colapsa tudo numa série única SEM rótulo nenhum. O alerta era
  # estruturalmente incapaz de dizer qual alvo caiu: ele acorda alguém às 3h para informar que algo
  # parou, e some com a única informação que decide o que fazer a seguir.
  #
  # Não era um caso, era uma CLASSE — seis regras das quinze tinham o mesmo defeito, e as cinco do
  # Loki (`{{ $labels.env }}` sobre `sum(count_over_time(...))`) escondiam melhor, porque um `env`
  # vazio no meio da frase parece formatação e não perda de dado.
  #
  # ## O que este teste NÃO prova
  #
  # Que o rótulo **existe** na métrica. `increase(node_vmstat_oom_kill[10m])` não apaga rótulo
  # nenhum, então uma citação a `$labels.mountpoint` ali passaria aqui e viria vazia no e-mail.
  # Provar isso exige consultar o Prometheus de pé — é da §12 do `verificar.sh`. O que se prova
  # aqui é a metade que é decidível pelo texto: a consulta não pode DESTRUIR o rótulo que a
  # anotação promete.
  @agregadores ~w(sum min max avg count topk bottomk stddev stdvar group)

  test "todo rótulo citado numa anotação sobrevive à consulta da própria regra", %{
    alertas: alertas
  } do
    regras = regras(alertas)

    # Anti-vacuidade: sem isto, mudar o recuo do YAML faria a quebra por `- uid:` devolver lista
    # vazia e o teste passaria verde sem ter comparado regra nenhuma.
    assert length(regras) >= 10,
           "achei só #{length(regras)} regras — a quebra por `- uid:` falhou?"

    citacoes =
      for {uid, bloco} <- regras,
          consulta = consulta_da_regra(bloco),
          is_binary(consulta),
          rotulo <- rotulos_citados(bloco),
          do: {uid, rotulo, consulta}

    assert length(citacoes) >= 8,
           "achei só #{length(citacoes)} citações de `$labels.` — a extração quebrou?"

    for {uid, rotulo, consulta} <- citacoes do
      assert preserva?(consulta, rotulo),
             """
             `#{uid}` cita `{{ $labels.#{rotulo} }}` numa anotação, mas a consulta da regra apaga
             esse rótulo:

                 #{consulta}

             Agregação sem `by` (ou com um `by` que não inclui o rótulo) colapsa tudo numa série
             sem rótulo algum, e o Grafana renderiza a anotação como **`[no value]`** — foi assim
             que `cinetra-coleta-de-metrica-parada` mandou um e-mail dizendo "[no value] parou de
             responder à raspagem", que é acordar alguém sem dizer o quê.

             Conserto: acrescente o rótulo ao `by (...)` da agregação — `min by (job, instance)
             (up)` no lugar de `min(up)`. Se o rótulo for impossível naquele caminho (regra que só
             dispara por `NoData` não tem rótulo nenhum, venha de onde vier), então o conserto é
             tirar a promessa do texto da anotação.
             """
    end
  end

  # O detector acima é regex sobre PromQL/LogQL, e regex sobre linguagem erra dos dois lados: falso
  # negativo deixa o bug passar, falso positivo obriga a próxima pessoa a inventar exceção. Este
  # teste é o que impede que ele apodreça em silêncio junto com o outro.
  test "o detector distingue consulta que preserva rótulo de consulta que o apaga" do
    assert preserva?("max by (name) (container_health_state{name!=\"\"} == 0)", "name")
    assert preserva?("min by (job, instance) (up)", "instance")
    # Sem agregação nenhuma os rótulos passam intactos.
    assert preserva?(
             "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes",
             "instance"
           )

    # `count_over_time` NÃO é o agregador `count` — se fosse, toda regra de Loki daria falso
    # positivo e a lista de exceções comeria o teste.
    assert preserva?("count_over_time({env=\"prod\"} [5m])", "env")

    refute preserva?("min(up)", "job")
    refute preserva?("sum(count_over_time({env=\"prod\", level=\"error\"} [5m]))", "env")
    # `by ()` explícito e vazio apaga tudo igual — é o caso do `cinetra-latencia-p95`.
    refute preserva?("quantile_over_time(0.95, {env=\"prod\"} | unwrap d [10m]) by ()", "env")
    # `by` que existe mas não inclui o rótulo citado.
    refute preserva?("max by (name) (increase(container_oom_events_total[10m]))", "instance")
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

  # Uma tupla `{uid, bloco}` por regra. `String.split/3` com regex descarta o separador, então cada
  # bloco já começa no valor do uid.
  defp regras(alertas) do
    alertas
    |> String.split(~r/^      - uid: /m)
    |> Enum.drop(1)
    |> Enum.map(&{&1 |> String.split("\n") |> hd() |> String.trim(), &1})
  end

  # Só o que está DENTRO de `annotations:`, e sem as linhas de comentário — pela mesma lição que o
  # `ComposeDeProducao.servico/2` carrega no `@doc`: este arquivo explica as próprias decisões em
  # prosa, e a prosa cita `{{ $labels.env }}` justamente para dizer por que ele NÃO está lá. Varrer
  # o bloco inteiro faria o teste cobrar do comentário o que ele só pode cobrar da anotação —
  # medido: a primeira versão reprovou `cinetra-pipeline-parado` por causa do comentário que
  # documentava o conserto dele.
  defp rotulos_citados(bloco) do
    ~r/\{\{-?\s*\$labels\.(\w+)/
    |> Regex.scan(secao(bloco, "annotations:"))
    |> Enum.map(fn [_todo, rotulo] -> rotulo end)
    |> Enum.uniq()
  end

  # As linhas de uma chave YAML até a próxima no mesmo recuo, já sem comentário.
  defp secao(bloco, chave) do
    linhas = String.split(bloco, "\n")

    case Enum.find_index(linhas, &Regex.match?(~r/^\s*#{Regex.escape(chave)}\s*$/, &1)) do
      nil ->
        ""

      i ->
        [cabeca | resto] = Enum.drop(linhas, i)

        resto
        |> Enum.take_while(&(recuo(&1) > recuo(cabeca)))
        |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
        |> Enum.join("\n")
    end
  end

  # O `expr:` da regra, remontado numa linha só. Precisa lidar com as duas formas usadas no
  # arquivo: valor na própria linha e bloco dobrado (`expr: >-` seguido de linhas mais recuadas).
  # O corte é pelo RECUO, e não por "até a próxima chave", porque `queryType: instant` vem depois
  # do `expr:` no mesmo recuo — e engolir essa linha faria o detector ler texto que não é consulta.
  defp consulta_da_regra(bloco) do
    linhas = String.split(bloco, "\n")

    case Enum.find_index(linhas, &Regex.match?(~r/^\s*expr:/, &1)) do
      nil ->
        nil

      i ->
        [cabeca | resto] = Enum.drop(linhas, i)
        recuo = recuo(cabeca)

        resto
        |> Enum.take_while(&(recuo(&1) > recuo))
        |> then(&Enum.map_join([cabeca | &1], " ", fn l -> String.trim(l) end))
        |> String.replace(~r/\Aexpr:\s*(>-|>|\|-|\|)?\s*/, "")
    end
  end

  defp recuo(linha), do: byte_size(linha) - byte_size(String.trim_leading(linha))

  # Um `by (...)` presente é a palavra final: o que estiver listado sobrevive, o resto morre —
  # inclusive no caso `by ()`, que é a lista vazia e mata tudo. Sem nenhum `by`, o que decide é
  # haver ou não agregação: agregação sem `by` colapsa em série única sem rótulo; sem agregação, os
  # rótulos do vetor passam intactos.
  defp preserva?(consulta, rotulo) do
    grupos =
      ~r/\bby\s*\(([^)]*)\)/
      |> Regex.scan(consulta)
      |> Enum.map(fn [_todo, lista] -> lista |> String.split(",") |> Enum.map(&String.trim/1) end)

    cond do
      grupos != [] -> Enum.any?(grupos, &(rotulo in &1))
      agrega?(consulta) -> false
      true -> true
    end
  end

  # `\s*\(` colado no nome é o que separa o agregador `count(` de `count_over_time(`, que é função
  # de faixa do LogQL e não apaga rótulo nenhum.
  defp agrega?(consulta) do
    Regex.match?(~r/\b(#{Enum.join(@agregadores, "|")})\s*\(/, consulta)
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
