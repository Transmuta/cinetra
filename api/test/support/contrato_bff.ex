defmodule Api.ContratoBff do
  @moduledoc """
  O gravador das **fixtures de contrato BFF↔API** (doc 101, A2) — a fonte única do exemplo.

  ## O problema que ele existe para resolver

  O BFF tem ~68 `interface` TypeScript espelhando a serialização Elixir, e os testes dele mockam
  `fetch` com JSON **escrito no próprio teste**. Isso valida o BFF contra o BFF: renomear um campo
  num serializer da API não quebra build nem teste de nenhum dos dois lados — o campo chega
  `undefined` em runtime, calado. O modo de falha já ocorreu (a nota em `web/src/lib/agenda.ts:17`).

  Aqui o exemplo passa a ter **uma fonte só**: um teste de controller atravessa o roteador de
  verdade, pega o corpo que a API responde e grava em `contratos/bff/<recurso>.json`. Os
  `.test.ts` leem esse arquivo no lugar do mock inventado. Se a serialização mudar, o arquivo
  muda; `git diff` fica sujo depois de `mix test` e o CI reprova.

  **Não é codegen.** Não há esquema gerado nem tipo derivado — é o *exemplo* que é único. É
  deliberadamente a metade barata do problema: pega renomeação, remoção e mudança de forma, que é
  a classe que morde.

  ## Por que a saída precisa ser byte-determinística

  O gate é `git diff --exit-code`. Um único valor volátil no corpo — um uuid novo a cada rodada,
  o `inserted_at` do relógio de parede — deixaria o arquivo sujo em toda execução, e o sinal
  viraria ruído em uma semana. Daí as três normalizações abaixo, e daí este módulo existir em vez
  de um `File.write!` no teste.

    * **uuid** vira `00000000-0000-4000-8000-<n>`, numerado por ordem de primeira aparição no
      arquivo. O mesmo id em duas amostras recebe o mesmo número, então relação continua legível
      (o `patient_ids` do bloco aponta para o `id` do paciente do sidecar);
    * **carimbo de relógio de parede** (a menos de cinco minutos da geração — `agora`,
      `inserted_at`) vira um instante fixo. Ele não descreve o contrato, só a hora em que a suíte
      rodou;
    * **as datas do mundo montado** são deslocadas para a **semana-âncora**. O teste monta o mundo
      em `âncora + 7k` semanas (sempre no futuro, sempre a mesma segunda-feira), e a gravação
      subtrai `7k` dias de tudo. É o que permite o exemplo ser sempre futuro **e** sempre idêntico
      — sem isto, ou a fixture muda de dia todo dia, ou ela apodrece numa data que vira passado.

  ## O que ele não faz

  Não valida nada. Quem cobra os campos é o lado TypeScript
  (`web/src/lib/testing/contrato.ts` e os `.test.ts` que o consomem), porque a exigência é do
  **consumidor**: "a tela lê `usadas`" é afirmação do web, e é lá que ela tem de morar para o dia
  em que a API parar de mandar o campo virar teste vermelho no lugar certo.
  """

  # A raiz do repositório vista de `api/`. No CI o checkout inteiro está em `../`; no container de
  # dev, onde só `api/` é montado em `/app`, o `docker-compose.yml` monta `./contratos` em
  # `/contratos` — e `/app/../contratos` é exatamente esse caminho. Um caminho só nos dois lugares.
  #
  # É o **único** ponto de escrita do repositório fora de `api/` em toda a suíte, e ele é
  # deliberado: a fixture não pertence a nenhum dos dois lados da fronteira, como
  # `contratos/regras-espelhadas.json` (doc 101, A5) já não pertencia.
  @raiz "../contratos/bff"

  # Segunda-feira. Os `dows` do expediente semeado no onboard abrem seg–sex, então a semana-âncora
  # precisa começar num dia em que a clínica atende.
  @ancora ~D[2026-01-05]

  # Antes da âncora de propósito: o `agora` normalizado precisa cair **antes** dos agendamentos da
  # semana-âncora, senão a fixture descreveria uma agenda no passado com o "agora" depois dela.
  @instante_fixo "2026-01-01T12:00:00.000000Z"
  @data_fixa "2026-01-01"

  @janela_volatil 300

  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  A segunda-feira em que o mundo da fixture deve ser montado, e o deslocamento até a âncora.

  Sempre **múltiplo de 7 dias** à frente da âncora: é isso que preserva o dia da semana (a grade
  do pacote é `[1, 3]` — segunda e quarta) e o que torna o deslocamento reversível na gravação.
  Três semanas à frente de hoje, com folga para o mundo ter passado e futuro em volta.
  """
  @spec semana() :: {Date.t(), integer()}
  def semana do
    k = div(Date.diff(Date.utc_today(), @ancora), 7) + 3
    {Date.add(@ancora, 7 * k), 7 * k}
  end

  @doc "O instante UTC de `hhmm` local, no fuso da clínica, em `data`."
  @spec as(Date.t(), String.t(), String.t()) :: DateTime.t()
  def as(data, hhmm, timezone) do
    {:ok, dt} = Api.Scheduling.LocalTime.to_utc(data, hhmm, timezone)
    dt
  end

  @doc """
  Grava `contratos/bff/<recurso>.json` com as amostras normalizadas e devolve o caminho.

  `amostras` é `%{nome => %{rota: "GET /api/...", corpo: corpo_do_json}}`. `deslocamento` é o
  segundo elemento de `semana/0`.

  **Falha em vez de pular** quando o destino não é gravável: uma fixture que some sozinha no
  ambiente errado deixaria os dois lados verdes sobre um contrato que ninguém conferiu.
  """
  @spec gravar(String.t(), integer(), map()) :: String.t()
  def gravar(recurso, deslocamento, amostras) when is_binary(recurso) and is_map(amostras) do
    conteudo = %{
      "_gerado_por" => "api/test/api_web/contrato_bff_test.exs — não editar à mão",
      "_como_regerar" => "mix test test/api_web/contrato_bff_test.exs",
      "_se_o_git_diff_sujar" =>
        "a serialização da API mudou. Confira se o BFF e a tela acompanham antes de commitar.",
      "amostras" => normalizar(amostras, deslocamento)
    }

    File.mkdir_p!(@raiz)
    caminho = Path.join(@raiz, "#{recurso}.json")
    File.write!(caminho, canonico(conteudo))
    caminho
  end

  # ---- normalização ----

  defp normalizar(termo, deslocamento) do
    {normalizado, _estado} =
      caminhar(termo, %{uuids: %{}, proximo: 1, agora: DateTime.utc_now(), dias: deslocamento})

    normalizado
  end

  # Mapas são percorridos em ordem de chave para a numeração dos uuids não depender da ordem em
  # que o Erlang devolve os pares — que é estável para o mesmo conjunto de chaves, mas não é
  # contrato de ninguém.
  defp caminhar(mapa, estado) when is_map(mapa) and not is_struct(mapa) do
    {pares, estado} =
      mapa
      |> Enum.map(fn {k, v} -> {chave(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_reduce(estado, fn {k, v}, acc ->
        {valor, acc} = caminhar(v, acc)
        {{k, valor}, acc}
      end)

    {Map.new(pares), estado}
  end

  defp caminhar(lista, estado) when is_list(lista),
    do: Enum.map_reduce(lista, estado, &caminhar/2)

  defp caminhar(texto, estado) when is_binary(texto) do
    if Regex.match?(@uuid, texto),
      do: uuid(texto, estado),
      else: {temporal(texto, estado), estado}
  end

  defp caminhar(%Date{} = data, estado), do: caminhar(Date.to_iso8601(data), estado)

  defp caminhar(%DateTime{} = dt, estado), do: caminhar(DateTime.to_iso8601(dt), estado)

  defp caminhar(outro, estado), do: {outro, estado}

  defp chave(k) when is_atom(k), do: Atom.to_string(k)
  defp chave(k) when is_binary(k), do: k

  defp uuid(texto, %{uuids: uuids} = estado) do
    case Map.fetch(uuids, texto) do
      {:ok, token} ->
        {token, estado}

      :error ->
        token = token(estado.proximo)

        {token, %{estado | uuids: Map.put(uuids, texto, token), proximo: estado.proximo + 1}}
    end
  end

  defp token(n),
    do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  # Um texto temporal recebe um de dois tratamentos, e a diferença é o que ele descreve:
  #
  #   * perto da geração → é o relógio de parede da suíte (`agora`, `inserted_at`). Vira o
  #     instante fixo: ele não faz parte do contrato;
  #   * qualquer outro → é uma data do mundo montado. Volta `deslocamento` dias para a
  #     semana-âncora, preservando dia da semana e hora.
  defp temporal(texto, estado) do
    case DateTime.from_iso8601(texto) do
      {:ok, dt, _offset} -> datahora(dt, texto, estado)
      _ -> data(texto, estado)
    end
  end

  defp datahora(dt, texto, estado) do
    if abs(DateTime.diff(dt, estado.agora)) <= @janela_volatil do
      @instante_fixo
    else
      dt |> DateTime.add(-estado.dias, :day) |> igual_ao_original(texto)
    end
  end

  # Preserva a **forma** do original (com ou sem microssegundos, `Z` ou offset): o formato é parte
  # do que o outro lado parseia, e trocá-lo silenciosamente por um canônico esconderia justamente
  # uma mudança de contrato.
  defp igual_ao_original(dt, texto) do
    iso = DateTime.to_iso8601(dt)

    if String.contains?(texto, "."), do: iso, else: String.replace(iso, ~r/\.\d+/, "")
  end

  # Uma data recebe o mesmo par de tratamentos do instante, pela mesma razão. O caso volátil aqui
  # é o `today` que a fila devolve (ADR-009): ele é o dia de HOJE, e deslocá-lo pela semana-âncora
  # daria uma data diferente conforme o dia da semana em que a suíte rodasse. A tolerância de um
  # dia cobre a virada de fuso; nenhuma data do mundo montado cai perto de hoje (elas são ~3
  # semanas à frente e ~1 semana atrás).
  defp data(texto, estado) do
    case Date.from_iso8601(texto) do
      {:ok, date} -> data_normalizada(date, estado)
      _ -> texto
    end
  end

  defp data_normalizada(date, estado) do
    if abs(Date.diff(date, DateTime.to_date(estado.agora))) <= 1 do
      @data_fixa
    else
      date |> Date.add(-estado.dias) |> Date.to_iso8601()
    end
  end

  # ---- JSON canônico ----
  #
  # Chaves ordenadas e uma linha por valor, com indentação: o gate é um `git diff`, e diff só
  # ajuda quem o lê se a mudança de um campo aparecer como uma linha. `Jason.encode!` sozinho não
  # garante a ordem das chaves nem quebra linha.

  @doc "O JSON canônico de `termo` — chaves ordenadas, indentado, com quebra de linha ao final."
  @spec canonico(term()) :: String.t()
  def canonico(termo), do: IO.iodata_to_binary([json(termo, 0), "\n"])

  defp json(mapa, nivel) when is_map(mapa) and not is_struct(mapa) do
    case Enum.sort_by(mapa, fn {k, _v} -> chave(k) end) do
      [] ->
        "{}"

      pares ->
        corpo =
          Enum.map_intersperse(pares, ",\n", fn {k, v} ->
            [recuo(nivel + 1), Jason.encode!(chave(k)), ": ", json(v, nivel + 1)]
          end)

        ["{\n", corpo, "\n", recuo(nivel), "}"]
    end
  end

  defp json([], _nivel), do: "[]"

  defp json(lista, nivel) when is_list(lista) do
    corpo =
      Enum.map_intersperse(lista, ",\n", fn item ->
        [recuo(nivel + 1), json(item, nivel + 1)]
      end)

    ["[\n", corpo, "\n", recuo(nivel), "]"]
  end

  defp json(valor, _nivel), do: Jason.encode!(valor)

  defp recuo(nivel), do: String.duplicate("  ", nivel)
end
