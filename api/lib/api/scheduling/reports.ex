defmodule Api.Scheduling.Reports do
  @moduledoc """
  O snapshot de métricas da tela de Relatórios (doc 33, Fatia 9): totais por status, taxa de
  falta, ocupação canônica e as quebras por dia, tipo e profissional.

  ## Por que mora fora de `Api.Scheduling`

  `Api.Scheduling` acumulava cinco responsabilidades em 1.723 linhas (doc 96, E-1): escrita e
  ciclo de vida da agenda, leitura de tela, relatórios, expediente/exceções e helpers de pacote.
  Este bloco era o mais fácil de separar e o mais claramente distinto — ~245 linhas cujo único
  acoplamento com o resto era `list_appointments!` (a mesma code interface que a agenda usa) e
  `capacity_minutes/3` (o denominador canônico de ocupação).

  A fachada continua em `Api.Scheduling.load_summary/5`: a fronteira não precisa saber em qual
  módulo interno a conta mora.

  ## O que este módulo NÃO faz

  Não reimplementa recorte por papel. A leitura passa pela mesma `list_appointments!` da agenda,
  então a preparation `OwnAgendaOnly` já recorta o `profissional` à própria agenda, fail-closed
  sem vínculo. O que se resolve aqui é o *conjunto de profissionais* do denominador de ocupação e
  das linhas da quebra — que é outra pergunta.
  """
  import Api.Tenancy, only: [in_clinic: 2]

  # As três peças que este módulo toma emprestado do domínio, e por que não são reescritas:
  #
  #   * `list_appointments!/3` — a MESMA code interface da agenda, o que faz a preparation
  #     `OwnAgendaOnly` recortar o papel `profissional` aqui de graça;
  #   * `capacity_minutes/3` — o denominador canônico de ocupação, compartilhado com a barra da
  #     agenda: duas contas divergiriam no primeiro feriado;
  #   * `gather_sources/3` — as quatro fontes de expediente numa leitura por fonte.
  import Api.Scheduling, only: [list_appointments!: 3, capacity_minutes: 3, gather_sources: 3]

  @doc """
  O snapshot de métricas da tela de Relatórios (doc 33): totais por status, taxa de falta,
  ocupação canônica e as quebras por dia/tipo/profissional para uma janela.

  ## Escopo por papel — uma regra, um caminho (doc 33 §3)

  A leitura dos agendamentos passa pela **mesma** code interface da agenda
  (`list_appointments!`), então a preparation `OwnAgendaOnly` já recorta o papel `profissional`
  à própria agenda (fail-closed sem vínculo) — nenhum recorte de papel é reimplementado aqui. O
  que este código resolve é o *conjunto de profissionais* do denominador de ocupação e das
  linhas da quebra: para `profissional`, só ele; para os demais, o filtro pedido ou todos os
  ativos. Relatórios é HTTP puro, então `scope.papel`/`scope.professional_id` são frescos por
  requisição — a ressalva do moduledoc do `Api.Scope` é sobre processos de Channel (Entrega 3).

  ## Ocupação canônica (doc 33 §2.1, GAP-11)

  `minutos_agendados ÷ minutos_de_expediente`, teto 100% — o mesmo `capacity_minutes/3` que
  `load_counts` usa para a barra da agenda. Não os "9 slots fixos" do protótipo, que contavam
  agendamentos e discordavam da agenda. Cancelado fica fora do numerador (não disputa espaço).
  """
  def load_summary(%Api.Scope{} = scope, %Date{} = from, %Date{} = to, professional_id, timezone) do
    dates = Date.range(from, to) |> Enum.to_list()
    escopo = summary_scope(scope, professional_id)

    in_clinic(scope, fn ->
      {janela_de, janela_ate} = Api.Scheduling.LocalTime.window!(from, to, timezone)

      # Dois conjuntos, de propósito (doc 33 §3):
      #   * `breakdown` — o escopo SELECIONADO: alimenta o denominador de ocupação e as linhas da
      #     quebra por profissional. Um filtro por profissional recorta os dois (activeProfs=1 do
      #     protótipo). O papel `profissional` fica preso ao próprio.
      #   * `filter_profs` — a lista da SIDEBAR e o lookup de nome/cor: sempre os ativos (ou só o
      #     próprio, para o papel `profissional`), independentemente do filtro escolhido — senão
      #     selecionar um profissional apagaria os outros da própria lista de filtro.
      breakdown = summary_professionals(scope, escopo)
      filter_profs = summary_filter_professionals(scope, escopo, breakdown)
      prof_ids = Enum.map(breakdown, & &1.id)

      # As PRESENÇAS vêm junto (A-1, doc 88). O desfecho do bloco é o rollup delas — "alguma
      # concluída ⇒ bloco concluído" —, então contar `appointment.status` apaga a falta de quem
      # não veio numa turma: 1 presente + 1 falta virava "1 concluído, 0 faltas". Quem o relatório
      # conta é gente atendida, não bloco; para atendimento individual os dois números coincidem,
      # e é por isso que o desvio ficou invisível até o QA guiado.
      appointments =
        list_appointments!(janela_de, janela_ate,
          scope: scope,
          query: [
            filter: summary_filter(escopo),
            select: [:starts_at, :ends_at, :status, :professional_id, :appointment_type_id],
            load: [:attendances]
          ]
        )

      # Todos os tipos (inclusive arquivados): um tipo desativado ainda pode ter atendimento no
      # período, e a tela precisa do nome/cor para a barra. Lookup-no-cliente por id, como a
      # agenda (`load_agenda`).
      types = Api.Directory.list_appointment_types!(scope: scope)

      ativos = Enum.reject(appointments, &(&1.status == :cancelado))
      sources = gather_sources(prof_ids, dates, tenant: scope.clinic_id, authorize?: false)

      dias = summary_por_dia(ativos, dates, timezone)
      capacidade_dia = summary_capacidade_por_dia(breakdown, dates, sources)
      ocupado = summary_ocupado_minutos(ativos)

      %{
        from: from,
        to: to,
        totais: summary_totais(appointments, ativos, ocupado, capacidade_dia, dias),
        por_dia: dias,
        por_tipo: summary_por_tipo(ativos),
        por_profissional: summary_por_profissional(appointments, breakdown),
        professionals: filter_profs,
        appointment_types: types
      }
    end)
  end

  # O escopo efetivo de profissionais (doc 33 §3). `:none` é o profissional sem vínculo de
  # diretório: relatório zerado (a leitura já vem vazia por `OwnAgendaOnly`, mas as linhas da
  # quebra também não devem existir).
  defp summary_scope(%Api.Scope{papel: :profissional, professional_id: nil}, _requested),
    do: :none

  defp summary_scope(%Api.Scope{papel: :profissional, professional_id: pid}, _requested),
    do: {:one, pid}

  defp summary_scope(_scope, requested) when is_binary(requested) and requested != "",
    do: {:one, requested}

  defp summary_scope(_scope, _requested), do: :all

  # Filtro da leitura de agendamentos. Para `:none`, `[]` basta: `OwnAgendaOnly` já esvazia a
  # leitura do profissional sem vínculo, então não há linha a recortar a mais.
  defp summary_filter({:one, pid}), do: [professional_id: pid]
  defp summary_filter(_), do: []

  defp summary_professionals(scope, {:one, pid}),
    do: Api.Directory.list_professionals!(scope: scope, query: [filter: [id: pid]])

  defp summary_professionals(scope, :all),
    do: Api.Directory.list_professionals!(scope: scope, query: [filter: [ativo: true]])

  defp summary_professionals(_scope, :none), do: []

  # A lista da sidebar/lookup: o papel `profissional` só se enxerga (o `breakdown` já é ele
  # mesmo, ou vazio); os demais veem todos os ativos, sem depender do filtro escolhido. No caso
  # `:all` (o default "todos", o caminho quente) o `breakdown` JÁ é a lista de ativos — reusa em
  # vez de repetir a mesma `list_professionals!` (medido no bate-volta: era 2× na rota todos).
  defp summary_filter_professionals(%Api.Scope{papel: :profissional}, _escopo, breakdown),
    do: breakdown

  defp summary_filter_professionals(_scope, :all, breakdown), do: breakdown

  defp summary_filter_professionals(scope, _escopo, _breakdown),
    do: summary_professionals(scope, :all)

  defp summary_por_dia(ativos, dates, timezone) do
    by_date =
      Enum.group_by(ativos, &Api.Scheduling.LocalTime.to_local_date(&1.starts_at, timezone))

    Enum.map(dates, fn date ->
      # Mesma unidade do cartão (presença, não bloco): senão o gráfico "Volume por dia" somaria
      # 12 embaixo de um KPI que diz 19, e o número volta a ser incontestável por falta de conta.
      presencas = by_date |> Map.get(date, []) |> summary_presencas()

      %{
        date: date,
        total: length(presencas),
        concluidos: Enum.count(presencas, &(&1.status == :concluida))
      }
    end)
  end

  # Capacidade (minutos de expediente) por data — a soma do denominador de ocupação sobre os
  # profissionais no escopo. Guardada por dia para derivar `dias_uteis` (datas com capacidade > 0).
  defp summary_capacidade_por_dia(professionals, dates, sources) do
    Enum.map(dates, fn date ->
      Enum.reduce(professionals, 0, fn prof, acc ->
        acc + capacity_minutes(prof, date, sources)
      end)
    end)
  end

  defp summary_ocupado_minutos(ativos) do
    Enum.reduce(ativos, 0, fn appt, acc ->
      acc + div(DateTime.diff(appt.ends_at, appt.starts_at), 60)
    end)
  end

  # As presenças dos blocos ATIVOS (não-cancelados), que é o recorte que o relatório sempre usou —
  # trocando só a unidade, de bloco para pessoa. A presença `:cancelada` sai junto: é o participante
  # que saiu da turma, e ele não foi atendido nem faltou.
  defp summary_presencas(ativos) do
    ativos
    |> Enum.flat_map(&(&1.attendances || []))
    |> Enum.reject(&(&1.status == :cancelada))
  end

  defp summary_totais(appointments, ativos, ocupado, capacidade_dia, dias) do
    presencas = summary_presencas(ativos)
    concluidos = Enum.count(presencas, &(&1.status == :concluida))
    faltas = Enum.count(presencas, &(&1.status == :faltou))
    capacidade = Enum.sum(capacidade_dia)

    %{
      atendimentos: length(presencas),
      concluidos: concluidos,
      faltas: faltas,
      # `cancelados` segue contando BLOCOS, e de propósito: o cartão se chama "Cancelamentos" e
      # conta o evento de cancelar, que é da fase de agendamento — não um desfecho de presença.
      cancelados: Enum.count(appointments, &(&1.status == :cancelado)),
      futuros: Enum.count(presencas, &(&1.status == :prevista)),
      taxa_falta: taxa_falta(concluidos, faltas),
      ocupacao: ocupacao_pct(ocupado, capacidade),
      ocupado_minutos: ocupado,
      capacidade_minutos: capacidade,
      dias_uteis: Enum.count(capacidade_dia, &(&1 > 0)),
      pico: summary_pico(dias)
    }
  end

  # Mesma unidade das outras três quebras: PRESENÇA, não bloco (A-1, doc 88). Esta ficou para trás
  # na virada e a divergência era visível na própria tela — o card divide `row.total` por
  # `totais.atendimentos`, então uma turma de quatro aparecia como "1 (25%)" embaixo de um KPI
  # dizendo 4, e as porcentagens não somavam 100 por estarem misturando duas contagens.
  #
  # `total: 0` sai da lista: com a unidade nova um bloco pode não contribuir presença nenhuma (o
  # último participante saiu da turma), e uma linha "0" num ranking de volume não diz nada. Não
  # mexe na invariante — zero não soma.
  defp summary_por_tipo(ativos) do
    ativos
    |> Enum.group_by(& &1.appointment_type_id)
    |> Enum.map(fn {type_id, blocos} ->
      %{appointment_type_id: type_id, total: length(summary_presencas(blocos))}
    end)
    |> Enum.reject(&(&1.total == 0))
    |> Enum.sort_by(& &1.total, :desc)
  end

  defp summary_por_profissional(appointments, professionals) do
    by_prof = Enum.group_by(appointments, & &1.professional_id)

    professionals
    |> Enum.map(fn prof ->
      presencas =
        by_prof
        |> Map.get(prof.id, [])
        |> Enum.reject(&(&1.status == :cancelado))
        |> summary_presencas()

      concluidos = Enum.count(presencas, &(&1.status == :concluida))
      faltas = Enum.count(presencas, &(&1.status == :faltou))

      %{
        professional_id: prof.id,
        total: length(presencas),
        concluidos: concluidos,
        faltas: faltas,
        taxa_falta: taxa_falta(concluidos, faltas)
      }
    end)
    |> Enum.sort_by(& &1.total, :desc)
  end

  # O dia mais movimentado (`busiest`, [:3364]). Sem atendimento nenhum não há pico.
  defp summary_pico(dias) do
    case Enum.max_by(dias, & &1.total, fn -> nil end) do
      nil -> nil
      %{total: 0} -> nil
      dia -> %{date: dia.date, total: dia.total}
    end
  end

  # `falta / (concluídos + faltas)`, arredondado — a mesma fórmula do protótipo ([:3346]).
  # Denominador zero (nenhuma sessão fechada) é 0%, não divisão por zero.
  defp taxa_falta(_concluidos, 0), do: 0
  defp taxa_falta(concluidos, faltas), do: round(faltas / (concluidos + faltas) * 100)

  defp ocupacao_pct(_ocupado, 0), do: 0
  # `Kernel.min/2` qualificado: o domínio já define um `min` (agregado do Ash) e o
  # não-qualificado colide na compilação — o mesmo motivo de `Kernel.max/2` em `capacity_minutes`.
  defp ocupacao_pct(ocupado, capacidade), do: Kernel.min(100, round(ocupado / capacidade * 100))
end
