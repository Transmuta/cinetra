defmodule Api.Packages.Series do
  @moduledoc """
  O motor de série de um pacote (RN-18…RN-21, [doc 02 §1.5](../../../../docs/02-regras-e-lacunas.md))
  — o `computeSerie` do protótipo ([`:1081`](../../../../interface/Movimento.dc.html#L1081)) como
  **domínio puro**: sem banco, sem escopo, sem relógio.

  Dada uma âncora, uma grade (`dows` + `horarios`) e um total, devolve as ocorrências que a série
  vai ocupar no calendário. Quem materializa agendamento a partir disso é a ação do pacote; aqui
  só existe calendário.

  ## A regra que dá o nome à coisa (RN-19)

  Feriado **pula e estende**. Um dia da grade que caia em feriado entra na saída marcado
  (`feriado?: true`), **não** conta como sessão útil, e a série anda no calendário até completar o
  total. Uma série de 10 sessões numa clínica com dois feriados ocupa 12 ocorrências. A saída
  inclui os feriados de propósito: é o que permite a UI mostrar o pulo em vez de o paciente
  descobrir sozinho que a série terminou uma semana depois do combinado.

  **Feriado aqui é só `:fechado`** (RN-20). Um dia de expediente especial (`:horario`) é dia
  normal — tratar qualquer exceção como pulo gera séries longas demais. Este módulo recebe o
  conjunto de datas já filtrado; quem chama é que sabe ler `ScheduleException`.

  ## O que mudou em relação ao protótipo, de propósito

  O `computeSerie` original tinha uma válvula `guard < 400` que, ao estourar, devolvia uma série
  **curta em silêncio** — meio pacote materializado, sem aviso. E `dows` vazio simplesmente girava
  a válvula até o fim. Aqui as duas viram erro: é melhor não criar pacote nenhum do que criar um
  pela metade. Idem para o `|| '09:00'` que o protótipo usava quando faltava horário para um dia
  da grade — horário ausente é dado incompleto, não um default.

  ## Convenção de `dow`

  0=domingo … 6=sábado, a mesma de `ClinicHours` e do `getDay()` do protótipo. Ver
  `Api.Scheduling.LocalTime.dow/1`.
  """

  alias Api.Scheduling.LocalTime

  @typedoc "Uma ocorrência projetada no calendário. `feriado?: true` não consome sessão."
  @type ocorrencia :: %{
          data: Date.t(),
          dow: 0..6,
          hhmm: String.t(),
          feriado?: boolean()
        }

  @typedoc "A grade do pacote: em que dias, e a que horas em cada dia."
  @type grade :: %{dows: [0..6], horarios: %{optional(0..6) => String.t()}}

  @type erro ::
          :dows_vazio
          | :total_invalido
          | :horizonte_excedido
          | {:dow_invalido, integer()}
          | {:horario_ausente, 0..6}

  # Teto de dias varridos. Só é alcançável com feriado absurdo (a série normal de N sessões numa
  # grade de 1 dia por semana ocupa ~7N dias). Existe para que dado ruim vire erro, não laço.
  @horizonte_extra_dias 400

  @doc """
  Projeta as ocorrências da série.

  Recebe a `âncora` (o dia a partir do qual a série corre), a `grade`, o `total` de sessões
  **úteis** e o conjunto de datas de feriado. Devolve as ocorrências em ordem cronológica,
  incluindo os feriados pulados.

  ## Opções

    * `:inclusive?` — se a série pode começar no próprio dia-âncora (RN-21). Padrão `true`;
      `false` é o caso "começa depois", que pula a âncora.

  ## Exemplos

      iex> grade = %{dows: [1], horarios: %{1 => "08:00"}}
      iex> {:ok, [primeira | _]} = Api.Packages.Series.project(~D[2026-07-20], grade, 2, MapSet.new())
      iex> primeira
      %{data: ~D[2026-07-20], dow: 1, hhmm: "08:00", feriado?: false}
  """
  @spec project(Date.t(), grade(), pos_integer(), MapSet.t(Date.t()), keyword()) ::
          {:ok, [ocorrencia()]} | {:error, erro()}
  def project(anchor, grade, total, feriados, opts \\ [])

  def project(%Date{} = anchor, %{dows: dows, horarios: horarios}, total, feriados, opts)
      when is_list(dows) and is_map(horarios) and is_integer(total) do
    with :ok <- validar(dows, horarios, total) do
      inicio = if Keyword.get(opts, :inclusive?, true), do: anchor, else: Date.add(anchor, 1)
      limite = Date.add(inicio, total * 7 + @horizonte_extra_dias)

      varrer(inicio, limite, MapSet.new(dows), horarios, total, feriados, [])
    end
  end

  defp validar([], _horarios, _total), do: {:error, :dows_vazio}
  defp validar(_dows, _horarios, total) when total < 1, do: {:error, :total_invalido}

  defp validar(dows, horarios, _total) do
    with :ok <- Enum.reduce_while(dows, :ok, &dow_valido/2) do
      Enum.reduce_while(dows, :ok, fn dow, :ok ->
        case Map.fetch(horarios, dow) do
          {:ok, hhmm} when is_binary(hhmm) -> {:cont, :ok}
          _ -> {:halt, {:error, {:horario_ausente, dow}}}
        end
      end)
    end
  end

  defp dow_valido(dow, :ok) when is_integer(dow) and dow >= 0 and dow <= 6, do: {:cont, :ok}
  defp dow_valido(dow, :ok), do: {:halt, {:error, {:dow_invalido, dow}}}

  # `restantes` conta só sessão ÚTIL: feriado entra na saída e não decrementa (RN-19).
  defp varrer(_dia, _limite, _dows, _horarios, 0, _feriados, acc), do: {:ok, Enum.reverse(acc)}

  defp varrer(dia, limite, dows, horarios, restantes, feriados, acc) do
    if Date.after?(dia, limite) do
      {:error, :horizonte_excedido}
    else
      dow = LocalTime.dow(dia)

      case MapSet.member?(dows, dow) do
        false ->
          varrer(Date.add(dia, 1), limite, dows, horarios, restantes, feriados, acc)

        true ->
          feriado? = MapSet.member?(feriados, dia)

          ocorrencia = %{
            data: dia,
            dow: dow,
            hhmm: Map.fetch!(horarios, dow),
            feriado?: feriado?
          }

          restantes = if feriado?, do: restantes, else: restantes - 1

          varrer(
            Date.add(dia, 1),
            limite,
            dows,
            horarios,
            restantes,
            feriados,
            [ocorrencia | acc]
          )
      end
    end
  end
end
