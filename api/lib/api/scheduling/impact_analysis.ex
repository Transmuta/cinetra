defmodule Api.Scheduling.ImpactAnalysis do
  @moduledoc """
  **A3 / `futureConflicts`** (doc 10 D12, RN-16) — o que uma mudança de horário quebraria na
  agenda que já existe.

  Mexer no expediente é a única operação do sistema que muda o passado do futuro: um agendamento
  marcado ontem, para daqui a três semanas, pode deixar de caber no expediente **sem que ninguém
  toque nele**. Este módulo responde "quais", **antes** de a mudança ser gravada.

  ## O que é conflito, exatamente

  Só quem **cabia antes e deixa de caber depois**. Não é "está fora do novo expediente": um
  agendamento marcado como encaixe, já fora do expediente atual, continua fora depois — a
  mudança não o piorou, e listá-lo transformaria a tela num inventário de encaixes antigos toda
  vez que alguém ajustasse um horário. A comparação é sempre *antes × depois*, nunca *depois*
  sozinho.

  ## Como a simulação evita reimplementar a precedência

  O `depois` **não** é calculado por regra própria: a mudança é **sobreposta nas fontes já
  carregadas** e a pergunta vai para `Api.Scheduling.Availability.day_periods/3` — o mesmo motor
  que a agenda, a validação de escrita e o pacote usam. Consequência prática: a análise não pode
  discordar do que vai acontecer depois de salvar, porque é literalmente a mesma função.

  Isto **resolve** o item aberto da RN-16 (doc 12 §A.3): o protótipo tinha, no `addHoliday`, uma
  precedência própria — a exceção pré-existente do profissional vencia a exceção da clínica sendo
  simulada, *inclusive quando a nova era um fechamento*. Isso contradiz o motor real, onde
  fechamento da clínica é a camada (A) e vence tudo (a assimetria "feriado vence o pontual do
  profissional"). Era divergência do protótipo, não regra: aqui a simulação passa pelas quatro
  camadas na ordem de sempre, então um feriado novo **conta** o agendamento de quem tinha horário
  pontual naquele dia — que é o que de fato aconteceria.

  ## Puro

  Não vai ao banco. Recebe os agendamentos, as fontes por profissional e a mudança; quem carrega
  é `Api.Scheduling.future_conflicts/2`. É o molde de `Availability` e `Periods` — e é o que
  permite testar as quatro formas de mudança sem montar uma clínica inteira.
  """

  alias Api.Scheduling.Availability
  alias Api.Scheduling.LocalTime

  # Os enums que o rascunho pode carregar. Existem aqui para a normalização **não** usar
  # `String.to_existing_atom` sobre valor que o cliente escolhe (ver o fim do módulo).
  @tipos Api.Scheduling.ExceptionKind.values()
  @modos Api.Scheduling.WeekdayMode.values()

  @typedoc """
  A mudança a simular. Cada forma é uma das portas de edição de horário do produto:

    * `{:clinic_hours, %{dow => periods}}` — a semana da clínica (tela Horário);
    * `{:professional_hours, professional_id, [%{dow:, modo:, periods:}]}` — a grade de um
      profissional (ficha do profissional);
    * `{:clinic_exception, %{data:, tipo:, periods:}}` — feriado/exceção da clínica;
    * `{:professional_exception, professional_id, %{data:, tipo:, periods:}}` — folga ou horário
      pontual de um profissional.
  """
  @type change ::
          {:clinic_hours, %{integer() => list()}}
          | {:professional_hours, String.t(), [map()]}
          | {:clinic_exception, map()}
          | {:professional_exception, String.t(), map()}

  @typedoc "Um conflito: o agendamento afetado e por quê."
  @type conflict :: %{
          appointment_id: String.t(),
          date: Date.t(),
          starts_at: DateTime.t(),
          professional_id: String.t(),
          reason: :sem_atendimento | :fora_do_expediente,
          periods_depois: [[String.t()]]
        }

  @doc """
  Os conflitos que `change` provocaria, ordenados por (data, horário).

  `appointments` são os agendamentos **futuros e ativos** (quem filtra é quem carrega);
  `sources_por_prof` é `%{professional_id => {professional, sources}}`, no formato que
  `Api.Scheduling.Availability` consome.
  """
  @spec conflicts([map()], %{String.t() => {map(), map()}}, change(), String.t()) :: [conflict()]
  def conflicts(appointments, sources_por_prof, change, timezone) do
    if valida?(change) do
      appointments
      |> Enum.filter(&afetado_por?(&1, change))
      |> Enum.flat_map(&conflito(&1, sources_por_prof, change, timezone))
      |> Enum.sort_by(&{&1.date, &1.starts_at})
    else
      # Rascunho que nem é válido (data malformada, `tipo` inventado): o gate **se abstém**.
      # Ele é regra de negócio, e quem recusa dado inválido é a validação do recurso, com o 422
      # certo — acusar conflito aqui devolveria 409 para o que na verdade é um 422.
      []
    end
  end

  # Se qualquer campo do rascunho não sobreviveu à normalização, a mudança não descreve um
  # estado possível e não há o que simular.
  defp valida?({:clinic_hours, week}) do
    is_map(week) and Enum.all?(Map.keys(week), &(inteiro(&1) != :invalido))
  end

  defp valida?({:professional_hours, _id, days}) do
    is_list(days) and
      Enum.all?(days, &(dia_da_semana(&1) != :invalido and modo(&1) != :invalido))
  end

  defp valida?({:clinic_exception, attrs}), do: excecao_valida?(attrs)
  defp valida?({:professional_exception, _id, attrs}), do: excecao_valida?(attrs)
  defp valida?(_change), do: false

  defp excecao_valida?(attrs) do
    is_map(attrs) and data_de(attrs) != :invalido and tipo(attrs) != :invalido
  end

  @doc """
  O que a mudança **pode** alcançar, como recorte de leitura: `%{date: …, professional_id: …}`.

  Existe porque `afetado_por?/2` (logo abaixo) descarta em Elixir o que a leitura já poderia não
  ter trazido do banco. Uma folga de um profissional num dia afeta, no máximo, os blocos **daquele
  profissional naquele dia** — e a leitura carregava a agenda futura inteira da clínica para então
  jogar 99,9% fora. Medido em 10.000 blocos futuros: **372 ms**, dos quais 266 ms só de montar as
  structs que seriam descartadas (doc 101, M1).

  Mora aqui, e não em quem lê, **de propósito**: o recorte e o `afetado_por?/2` são a mesma regra
  vista de dois lados, e é exatamente o par que não pode divergir. Se um dia o filtro em Elixir
  passar a alcançar outra coisa, esta função precisa mudar junto — no mesmo arquivo, ao lado, onde
  quem edita uma vê a outra. Foi o argumento do B6 na onda 2: duplicação não é só custo de
  manutenção, é lugar onde um conserto não chega.

  `nil` em qualquer chave significa **não sei recortar por esta dimensão** — quem lê deve trazer
  tudo. É o caso de `:clinic_hours`, que alcança um conjunto de dias-da-semana espalhado pelo
  futuro inteiro: recortá-lo exigiria converter fuso dentro do SQL, e um índice de expressão que
  o AshPostgres não usaria (a lição do doc 35).
  """
  @spec recorte(change()) :: %{date: Date.t() | nil, professional_id: String.t() | nil}
  def recorte(change)

  def recorte({:clinic_exception, attrs}), do: %{date: data_valida(attrs), professional_id: nil}

  def recorte({:professional_exception, professional_id, attrs}),
    do: %{date: data_valida(attrs), professional_id: id_valido(professional_id)}

  def recorte({:professional_hours, professional_id, _days}),
    do: %{date: nil, professional_id: id_valido(professional_id)}

  def recorte(_change), do: %{date: nil, professional_id: nil}

  defp data_valida(attrs) when is_map(attrs) do
    case data_de(attrs) do
      %Date{} = date -> date
      _ -> nil
    end
  end

  defp data_valida(_attrs), do: nil

  defp id_valido(id) when is_binary(id), do: id
  defp id_valido(_id), do: nil

  # Recorte barato ANTES de simular: uma mudança de terça-feira não tem como afetar uma quinta, e
  # uma exceção do dia 24 não afeta o dia 25. Sem isto, a simulação rodaria para todo agendamento
  # futuro da clínica — o que é correto e desperdício.
  #
  # A exceção **do profissional** também recorta por profissional; a **da clínica**, não (vale
  # para todos).
  defp afetado_por?(appt, {:clinic_hours, week}),
    do: Map.has_key?(week, LocalTime.dow(appt.date))

  defp afetado_por?(appt, {:professional_hours, professional_id, days}) do
    appt.professional_id == professional_id and
      Enum.any?(days, &(dia_da_semana(&1) == LocalTime.dow(appt.date)))
  end

  defp afetado_por?(appt, {:clinic_exception, attrs}), do: appt.date == data_de(attrs)

  defp afetado_por?(appt, {:professional_exception, professional_id, attrs}),
    do: appt.professional_id == professional_id and appt.date == data_de(attrs)

  # `day_periods/3` roda **duas vezes por agendamento afetado** (o antes e o depois), e o par
  # depende só de `{professional_id, date}` — o mesmo dia do mesmo profissional é recalculado uma
  # vez por bloco. O doc 101 (M1) apontou isso, e a memoização por par foi **construída, medida e
  # descartada**:
  #
  #     pior caso (semana da clínica, 10.000 blocos futuros, 1.400 afetados,
  #     2.800 chamadas de `day_periods` caindo para 280 — 10× menos)
  #       sem memo : mediana 230,9 ms
  #       com memo : mediana 230,3 ms
  #
  # Ou seja: dentro do ruído. E há razão estrutural para isso, que vale mais que o número —
  # **afetados ≤ carregados**, e carregar uma linha (montar a struct do Ash) custa ordens de
  # grandeza mais que simular um dia. A simulação não tem como dominar; quem domina é a leitura,
  # e é lá que o conserto do M1 foi feito (`Api.Scheduling.agendamentos_futuros/4`).
  #
  # Fica registrado como não-feito, com o porquê: reencontrar "roda duas vezes" daqui a seis meses
  # sem esta nota faria alguém pagar a complexidade de novo pelo mesmo nada.
  defp conflito(appt, sources_por_prof, change, timezone) do
    case Map.fetch(sources_por_prof, appt.professional_id) do
      # Profissional fora do mapa (arquivado, apagado): sem fontes não há veredito, e inventar um
      # seria pior que omitir. Não acontece pelo caminho normal — quem carrega monta o mapa a
      # partir dos próprios agendamentos.
      :error ->
        []

      {:ok, {professional, sources}} ->
        local = LocalTime.to_local_range(appt.starts_at, appt.ends_at, timezone)

        antes = periodos(appt.date, professional, sources)
        depois = periodos(appt.date, professional, aplicar(sources, change))

        if Availability.fits?(antes, local) and not Availability.fits?(depois, local),
          do: [montar(appt, depois)],
          else: []
    end
  end

  defp periodos(date, professional, sources) do
    case Availability.day_periods(date, professional, sources) do
      {:open, periods} -> periods
      {:closed, _reason} -> []
    end
  end

  defp montar(appt, depois) do
    %{
      appointment_id: appt.id,
      date: appt.date,
      starts_at: appt.starts_at,
      professional_id: appt.professional_id,
      # Dois motivos porque a tela diz coisas diferentes: "ninguém atende nesse dia" é uma frase,
      # "não cabe mais em 08:00–12:00" é outra — e a segunda precisa dos períodos.
      reason: if(depois == [], do: :sem_atendimento, else: :fora_do_expediente),
      periods_depois: depois
    }
  end

  # ---- a sobreposição da mudança nas fontes carregadas ----
  #
  # Cada cláusula troca UMA das quatro listas que `Availability` lê. Nada mais: a precedência
  # continua sendo dele.

  defp aplicar(sources, {:clinic_hours, week}) do
    Map.update!(sources, :clinic_hours, fn rows ->
      Enum.map(rows, fn row ->
        case Map.fetch(week, row.dow) do
          {:ok, periods} -> %{row | periods: periods}
          :error -> row
        end
      end) ++ linhas_novas(rows, week)
    end)
  end

  defp aplicar(sources, {:professional_hours, _professional_id, days}) do
    # O `professional_id` não entra aqui: `sources` já é o do profissional em questão (quem
    # carrega separa), e o recorte por profissional aconteceu em `afetado_por?/2`.
    Map.update!(sources, :professional_hours, fn rows ->
      novos = Map.new(days, &{dia_da_semana(&1), &1})

      mantidos = Enum.reject(rows, &Map.has_key?(novos, &1.dow))

      mantidos ++
        Enum.map(days, fn day ->
          %{dow: dia_da_semana(day), modo: modo(day), periods: periodos_do(day)}
        end)
    end)
  end

  defp aplicar(sources, {:clinic_exception, attrs}),
    do: sobrepor_excecao(sources, :clinic_exceptions, attrs)

  defp aplicar(sources, {:professional_exception, _professional_id, attrs}),
    do: sobrepor_excecao(sources, :professional_exceptions, attrs)

  # Uma exceção nova na data **substitui** a que houver ali: a identidade
  # `(clinic_id, data, professional_id)` garante que só existe uma, então simular "somar" as duas
  # descreveria um estado que o banco não aceita.
  defp sobrepor_excecao(sources, chave, attrs) do
    nova = %{data: data_de(attrs), tipo: tipo(attrs), periods: periodos_do(attrs)}

    Map.update(sources, chave, [nova], fn atuais ->
      Enum.reject(atuais, &(&1.data == nova.data)) ++ [nova]
    end)
  end

  # Um dia que a clínica não tinha na tabela (linha ausente) e que o rascunho traz.
  defp linhas_novas(rows, week) do
    existentes = MapSet.new(rows, & &1.dow)

    week
    |> Enum.reject(fn {dow, _periods} -> MapSet.member?(existentes, dow) end)
    |> Enum.map(fn {dow, periods} -> %{dow: dow, periods: periods} end)
  end

  # ---- o rascunho vem da fronteira HTTP, e lá tudo é string ----
  #
  # Este bloco é o conserto do bate-volta ([doc 49](../../../../docs/49-bate-volta-onda-6.md)).
  # O motor é chamado de dois lugares com **formas diferentes** do mesmo dado: do domínio (e dos
  # testes) chegam `%Date{}` e átomos; da fronteira chegam `"2027-03-15"` e `"fechado"`. Sem
  # normalizar, `appt.date == "2027-03-15"` é **sempre falso** — e o gate não acusava nada, com
  # a exceção sendo criada por cima da agenda (201 no lugar de 409). O tipo do dado era a regra,
  # e ninguém tinha escrito qual.

  defp dia_da_semana(day), do: inteiro(day[:dow] || day["dow"])
  defp data_de(attrs), do: data(attrs[:data] || attrs["data"])
  defp periodos_do(map), do: map[:periods] || map["periods"] || []

  defp modo(day), do: normalizar(day[:modo] || day["modo"], @modos)
  defp tipo(attrs), do: normalizar(attrs[:tipo] || attrs["tipo"], @tipos)

  defp data(%Date{} = date), do: date

  defp data(valor) when is_binary(valor) do
    case Date.from_iso8601(valor) do
      {:ok, date} -> date
      _ -> :invalido
    end
  end

  defp data(_valor), do: :invalido

  defp inteiro(valor) when is_integer(valor), do: valor

  defp inteiro(valor) when is_binary(valor) do
    case Integer.parse(valor) do
      {n, ""} -> n
      _ -> :invalido
    end
  end

  defp inteiro(_valor), do: :invalido

  # **Nunca** `String.to_existing_atom` sobre valor que o cliente escolhe: um `tipo` inventado
  # derrubava a request com `ArgumentError` (500) num caminho que devolvia 422 corretamente
  # antes. Valor fora da lista vira `:invalido`, e `valida?/1` faz o gate se abster — o rascunho
  # inválido é problema da validação do recurso, que responde 422 logo em seguida.
  defp normalizar(valor, validos) when is_atom(valor) and not is_nil(valor) do
    if valor in validos, do: valor, else: :invalido
  end

  defp normalizar(valor, validos) when is_binary(valor) do
    Enum.find(validos, :invalido, &(Atom.to_string(&1) == valor))
  end

  defp normalizar(nil, _validos), do: nil
end
