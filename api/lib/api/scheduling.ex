defmodule Api.Scheduling do
  @moduledoc """
  Domínio da disponibilidade da clínica (doc 22) — recursos **por-tenant** por atributo
  (`strategy :attribute` sobre `clinic_id`, ADR-017). Por ora `ClinicHours` (o expediente
  semanal) e `ScheduleException` (feriados e exceções de data). `ProfessionalHours` e a
  exceção por profissional entram com a seção Profissionais (doc 22 §5).

  Os wrappers deste módulo centralizam aqui o `Api.Repo.with_clinic/2` (GUC de tenant para a
  RLS) na leitura — é por isso que **os controllers não falam com o Repo** e chamam estas
  funções em vez das code interfaces cruas. A escrita seta a GUC dentro da própria ação, via
  `Api.Tenancy.SetTenantGuc`.

  A frase antiga dizia "controllers e changes não falam com o Repo". Vale para os controllers;
  **não** vale para os changes: `Appointment.Changes.ComputeEndsAt` chama `Api.Repo.with_clinic/2`
  direto, porque precisa da GUC de dentro da transação da própria ação — um `in_clinic` externo
  ali quebraria o caminho de erro (ver `Api.Tenancy`). O que a regra de fato garante é que a
  **fronteira HTTP** não fala com o Repo.
  """
  use Ash.Domain, otp_app: :api, extensions: [AshPaperTrail.Domain]

  # Leitura sob RLS (o corte de tenancy é compartilhado — ver `Api.Tenancy`).
  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query

  # A-D6c: registra automaticamente os recursos `*.Version` gerados pelo AshPaperTrail
  # (`Appointment.Version`, `Attendance.Version`). Sem isto eles não pertencem a domínio
  # nenhum e o Ash recusa a compilação.
  paper_trail do
    include_versions? true
  end

  resources do
    resource Api.Scheduling.Appointment do
      define :list_appointments, action: :in_range, args: [:from, :to]
      define :find_appointments, action: :read
      define :get_appointment, action: :read, get_by: [:id]

      # A interface **crua** da criação. Quem agenda de fora chama `schedule_appointment/2`
      # (abaixo), que decide entre criar e fundir numa turma existente (A-D4).
      define :create_appointment_slot, action: :schedule
      define :add_appointment_participants, action: :add_participant

      # Interfaces **cruas** do ciclo de vida (Entrega 4). Quem chama de fora usa
      # `transition_appointment/5`, que faz o fetch-then-update com o guard de `version` (409).
      define :reschedule_appointment_slot, action: :reschedule
      define :complete_appointment_slot, action: :mark_completed
      define :miss_appointment_slot, action: :mark_missed
      define :cancel_appointment_slot, action: :cancel

      # Pausa/retoma uma sessão de pacote (RN-05/23). Recebe `%{pkg_hold: bool}` antes das opções.
      define :set_appointment_pkg_hold, action: :set_pkg_hold
      define :reopen_appointment_slot, action: :reopen
      define :exclude_appointment_slot, action: :exclude
      define :justify_appointment_absence, action: :set_falta_justificada
    end

    resource Api.Scheduling.Attendance do
      define :list_attendances, action: :read

      # A materialização do pacote (Fatia 3) carimba o `package_id` na presença logo após criar a
      # sessão. Recebe o registro e o novo pacote como argumento extra (mapa antes das opções).
      define :set_attendance_package, action: :set_package
    end

    # Os recursos `*.Version` acima nasciam registrados (`include_versions?`) mas **sem code
    # interface** — então ler a trilha exigia `Ash.read!` cru, que é justamente o que
    # `.claude/rules/ash.md` manda evitar (e o teste da trilha fazia). Com o `define`, a
    # trilha se lê como qualquer outra coleção do domínio.
    resource Api.Scheduling.Appointment.Version do
      define :list_appointment_versions, action: :read
      # A leitura paginada da tela de auditoria (doc 25 §11.4). `list_audit_log/2` a consome.
      define :page_appointment_versions, action: :audit_log
    end

    resource Api.Scheduling.Attendance.Version do
      define :list_attendance_versions, action: :read
      define :page_attendance_versions, action: :audit_log
    end

    resource Api.Scheduling.ClinicHours do
      define :list_clinic_hours_rows, action: :read
      define :set_clinic_hours_day, action: :set_day
    end

    resource Api.Scheduling.ScheduleException do
      define :list_schedule_exceptions, action: :read
      define :get_schedule_exception, action: :read, get_by: [:id]
      define :create_schedule_exception, action: :create
      define :destroy_schedule_exception, action: :destroy
    end

    resource Api.Scheduling.ProfessionalHours do
      define :list_professional_hours_rows, action: :read
      define :set_professional_hours_day, action: :set_day
    end

    # A reserva de vaga da fila (Entrega 5). Mora aqui — não em `Api.Waitlist` — porque a garantia
    # é a mesma exclusion constraint do agendamento (doc 09 §6.2). A orquestração oferta→conversão
    # vive em `Api.Waitlist`, que consome estas interfaces.
  end

  # ---- Agenda: escrita ----

  @doc """
  Agenda — **criando** o bloco, ou **fundindo** o participante numa turma que já existe (A-D4).

  ## Por que a fusão não é uma sutileza estética

  No protótipo, criar num slot com bloco coincidente (mesmo profissional/data/hora/tipo) funde
  o paciente ([`:1053`]) e nunca chama `checkConflict` para grupo — omissão registrada em
  `12:102`. Com a exclusion constraint `appointments_no_overlap`, isso deixou de ser escolha:
  um **segundo** `Appointment` no mesmo profissional/horário é rejeitado pelo banco. Sem a
  fusão, portanto, adicionar o segundo participante de uma turma simplesmente **falha**, com
  um 422 de conflito que descreve mal o que aconteceu.

  ## Lookup-then-add, e por que isso importa para a capacidade

  A fusão é feita como *lookup-then-add*: acha a turma e delega para `:add_participant`. O
  ganho é que criar e fundir passam pela **mesma** validação de capacidade
  (`Validations.GroupCapacity`) — sem isso o teto ficaria validado num caminho e furado no
  outro, que é exatamente o bug do protótipo (A-D3).

  Só tipo de **grupo** funde. Tipo individual no mesmo slot continua sendo conflito, e é o
  banco quem diz. Uma turma `pkg_hold` (Fatia 3) é invisível à leitura por RN-05 e portanto não
  funde — cairia em conflito.

  ## Sobre a corrida

  Entre o lookup e a escrita há janela: dois recepcionistas criando a mesma turma no mesmo
  instante fazem os dois lookups voltarem vazios, e o segundo `INSERT` bate na constraint →
  422 de conflito, não 500 nem linha duplicada. O banco continua sendo a autoridade (A5).
  """
  def schedule_appointment(attrs, opts \\ []) when is_map(attrs) do
    case find_turma(attrs, opts) do
      nil ->
        create_appointment_slot(attrs, opts)

      turma ->
        add_appointment_participants(
          turma,
          %{
            patient_ids: List.wrap(fetch(attrs, :patient_ids)),
            encaixe: fetch(attrs, :encaixe) in [true, "true"]
          },
          opts
        )
    end
  end

  # A turma existente para estes atributos, ou `nil`. Devolve `nil` em toda dúvida (tipo
  # individual, tipo não encontrado, `starts_at` malformado): quem recusa entrada inválida são
  # as validações da ação, com a mensagem certa — não este lookup, calado.
  defp find_turma(attrs, opts) do
    with clinic_id when is_binary(clinic_id) <- clinic_id_from(opts),
         type_id when is_binary(type_id) <- fetch(attrs, :appointment_type_id),
         professional_id when is_binary(professional_id) <- fetch(attrs, :professional_id),
         {:ok, _capacidade} <- Api.Directory.appointment_type_capacity(type_id, clinic_id),
         {:ok, starts_at} <- cast_starts_at(fetch(attrs, :starts_at)) do
      query =
        Ash.Query.filter(
          Api.Scheduling.Appointment,
          professional_id == ^professional_id and appointment_type_id == ^type_id and
            starts_at == ^starts_at and status != :cancelado
        )

      case in_clinic_or_tenant(opts, clinic_id, fn ->
             find_appointments!(Keyword.put(opts, :query, query))
           end) do
        [turma | _] -> turma
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp cast_starts_at(%DateTime{} = starts_at), do: {:ok, starts_at}

  defp cast_starts_at(value) when is_binary(value) do
    case Ash.Type.cast_input(:utc_datetime, value) do
      {:ok, starts_at} -> {:ok, starts_at}
      _ -> :error
    end
  end

  defp cast_starts_at(_), do: :error

  defp clinic_id_from(opts) do
    case Keyword.get(opts, :scope) do
      %Api.Scope{clinic_id: clinic_id} -> clinic_id
      _ -> opts |> Keyword.get(:tenant) |> normalize_tenant()
    end
  end

  defp normalize_tenant(nil), do: nil
  defp normalize_tenant(tenant), do: to_string(tenant)

  # A leitura precisa da GUC (ADR-018) — e `in_clinic/2` exige um `Api.Scope`. Chamada interna
  # com `tenant:` cru (seed, teste) usa o `with_clinic` direto.
  defp in_clinic_or_tenant(opts, clinic_id, fun) do
    case Keyword.get(opts, :scope) do
      %Api.Scope{} = scope ->
        in_clinic(scope, fun)

      _ ->
        {:ok, result} = Api.Repo.with_clinic(clinic_id, fun)
        result
    end
  end

  # `attrs` chega com chaves atom (testes, code interfaces) ou string (corpo HTTP).
  defp fetch(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  @doc """
  O teto de participantes de uma turma: `AppointmentType.capacidade`, ou o
  `Clinic.cap_turma_padrao` quando o tipo é de grupo sem teto próprio (A-D3).

  Retornos: `{:ok, capacidade}` (tipo de grupo) · `:individual` · `:error`.
  """
  def group_capacity(clinic_id, appointment_type_id)
      when is_binary(clinic_id) and is_binary(appointment_type_id) do
    case Api.Directory.appointment_type_capacity(appointment_type_id, clinic_id) do
      {:ok, capacidade} when is_integer(capacidade) -> {:ok, capacidade}
      {:ok, nil} -> {:ok, load_clinic(clinic_id).cap_turma_padrao}
      other -> other
    end
  end

  @doc """
  Quantos participantes um agendamento já tem — o `N` do `N/cap` (A-D3).

  Lido **sem escopo** de propósito: é contagem de invariante, não de exibição. Sob o recorte
  da A7, um `profissional` contaria menos participantes do que a turma tem e o teto se abriria
  sozinho para ele.
  """
  def count_participants(clinic_id, appointment_id)
      when is_binary(clinic_id) and is_binary(appointment_id) do
    {:ok, attendances} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_attendances!(
          tenant: clinic_id,
          authorize?: false,
          query: [filter: [appointment_id: appointment_id]]
        )
      end)

    length(attendances)
  end

  @doc """
  Ciclo de vida do bloco (Entrega 4): remarcar, concluir, faltar, cancelar, reabrir, justificar
  falta. **fetch-then-update** com o guard de locking otimista.

  ## O guard de versão, e por que ele mora aqui (não numa validação atômica)

  `expected_version` é o `version` que o cliente leu. Se o valor no banco já não for esse, a
  escrita é recusada com `{:error, :version_conflict}` → **409** ("seu pedido estava certo, o
  mundo mudou", `09:659`). O guard é feito no fetch, e não como `atomic_update(:version, …)`
  ([`01:535`]), porque `SetTenantGuc` força `require_atomic? false` em toda escrita por-tenant —
  as duas coisas não coexistem (doc 25 §10). A janela entre o fetch e o update que sobra é
  fechada, para conflito de horário, pela exclusion constraint. `expected_version` `nil` pula o
  guard (chamada interna, seed).

  Fora do tenant / inexistente → `{:error, :not_found}` (a preparation `OwnAgendaOnly` some com
  o bloco do colega para o papel `profissional`, então "não é meu" também cai aqui como 404).
  """
  def transition_appointment(scope, id, kind, input \\ %{}, expected_version \\ nil)

  def transition_appointment(%Api.Scope{} = scope, id, kind, input, expected_version)
      when is_binary(id) and is_atom(kind) do
    # A **leitura** vai sob `in_clinic` (GUC para a RLS); a **escrita** NÃO — envolver a escrita
    # numa transação externa quebra o caminho de erro (o 422 vira 500) e segura as notificações
    # do notifier dentro da transação (o push de tempo real não sairia). É o que o moduledoc de
    # `Api.Tenancy.in_clinic/2` avisa; a escrita seta a própria GUC via `SetTenantGuc`.
    with {:ok, appt} <- fetch_for_transition(scope, id, expected_version),
         {:ok, updated} <- dispatch_transition(kind, appt, input, scope) do
      {:ok, com_attendances(updated, appt, scope)}
    end
  end

  defp fetch_for_transition(scope, id, expected_version) do
    case in_clinic(scope, fn ->
           get_appointment(id, scope: scope, load: [:attendances], not_found_error?: false)
         end) do
      {:ok, %{} = appt} ->
        if version_ok?(appt, expected_version),
          do: {:ok, appt},
          else: {:error, :version_conflict}

      _ ->
        {:error, :not_found}
    end
  end

  # A serialização do bloco lê `patient_ids` das `attendances` (`AgendaJSON`) — uma forma só de
  # bloco sai por todas as portas. A questão é de onde elas vêm, e este era o D-J: relê-las
  # aqui custa uma **transação nova depois do commit**, só para reconstruir o que a ação já
  # tinha em mãos. As duas fontes que já existem:
  #
  #   * ações de status — a cascata (`CascadeToAttendances`) devolve as presenças que ela mesma
  #     acabou de atualizar, dentro da transação;
  #   * remarcação — não toca em presença nenhuma, então valem as do fetch que abriu a operação
  #     (o mesmo `get_appointment(load: [:attendances])` que checou a versão).
  #
  # O terceiro caso não deve acontecer (o fetch sempre carrega), mas se acontecer é melhor uma
  # leitura a mais do que um bloco sem `patient_ids` na tela.
  defp com_attendances(%{attendances: att} = updated, _appt, _scope) when is_list(att),
    do: updated

  defp com_attendances(updated, %{attendances: att}, _scope) when is_list(att),
    do: %{updated | attendances: att}

  defp com_attendances(updated, _appt, scope),
    do: in_clinic(scope, fn -> Ash.load!(updated, [:attendances], scope: scope) end)

  defp version_ok?(_appt, nil), do: true
  defp version_ok?(%{version: version}, expected), do: version == expected

  defp dispatch_transition(:reschedule, appt, input, scope),
    do: reschedule_appointment_slot(appt, input, scope: scope)

  defp dispatch_transition(:complete, appt, _input, scope),
    do: complete_appointment_slot(appt, %{}, scope: scope)

  defp dispatch_transition(:miss, appt, _input, scope),
    do: miss_appointment_slot(appt, %{}, scope: scope)

  defp dispatch_transition(:cancel, appt, input, scope),
    do: cancel_appointment_slot(appt, input, scope: scope)

  defp dispatch_transition(:reopen, appt, _input, scope),
    do: reopen_appointment_slot(appt, %{}, scope: scope)

  defp dispatch_transition(:exclude, appt, _input, scope),
    do: exclude_appointment_slot(appt, %{}, scope: scope)

  defp dispatch_transition(:justify, appt, input, scope),
    do: justify_appointment_absence(appt, input, scope: scope)

  # ---- Agenda: leitura da tela ----

  @doc """
  Tudo o que a visão Dia precisa, **numa transação só** com a GUC de tenant setada:
  agendamentos da janela, profissionais e tipos ativos, e os pacientes citados.

  Existe como wrapper — e o controller não chama as code interfaces cruas — porque cada
  leitura precisa da GUC para atravessar a RLS (ADR-018). Chamar
  `Api.Directory.list_professionals!/1` direto devolve **lista vazia** no servidor real e a
  lista certa no `mix test` (sandbox `postgres`, BYPASSRLS): a sidebar aparecia com
  *"Nenhum profissional cadastrado"* com a suíte inteira verde. Um `in_clinic` só, em vez de
  quatro, também é um checkout de conexão em vez de quatro.

  Os pacientes vêm **sem filtro de `ativo`**: um paciente arquivado com sessão marcada
  continua precisando de nome no bloco.
  """
  def load_agenda(%Api.Scope{} = scope, from, to, opts \\ []) do
    in_clinic(scope, fn ->
      appointments =
        list_appointments!(from, to,
          scope: scope,
          query: [filter: Keyword.get(opts, :filter, [])],
          load: [:attendances]
        )

      %{
        appointments: appointments,
        professionals:
          Api.Directory.list_professionals!(scope: scope, query: [filter: [ativo: true]]),
        appointment_types:
          Api.Directory.list_appointment_types!(scope: scope, query: [filter: [ativo: true]]),
        patients: patients_for(scope, appointments)
      }
    end)
  end

  @doc """
  Um agendamento **como este escopo o enxerga**, com os pacientes citados — ou `nil`.

  Existe para o push do `ApiWeb.AgendaChannel` (Entrega 3). O tópico do canal é da clínica
  inteira, mas o papel `profissional` só pode ver a própria agenda: em vez de reimplementar
  esse recorte na fronteira do WebSocket, o canal relê o bloco por aqui com o escopo de cada
  assinante. Quem não pode lê-lo recebe `nil` — a preparation `OwnAgendaOnly` filtra a linha
  e o `get` não acha nada. Uma regra, um caminho.

  Devolve os pacientes junto pelo mesmo motivo que `GET /api/appointments` devolve: o bloco
  carrega `patient_ids`, e o cliente pode não ter aqueles nomes na janela que já baixou.
  """
  def load_visible_appointment(%Api.Scope{} = scope, appointment_id)
      when is_binary(appointment_id) do
    in_clinic(scope, fn ->
      case get_appointment(appointment_id, scope: scope, load: [:attendances]) do
        {:ok, appointment} ->
          %{appointment: appointment, patients: patients_for(scope, [appointment])}

        _ ->
          nil
      end
    end)
  end

  @doc """
  As contagens das visões Semana e Mês (doc 25 §9, Entrega 2), quebradas por **dia ×
  profissional**.

  Devolve, para cada data da janela e cada profissional ativo, quantos agendamentos ocupam a
  grade, quantos minutos eles ocupam, e quantos minutos de expediente aquele profissional tem
  naquele dia. A tela soma o que está visível — é o que faz o toggle da sidebar valer para as
  três visões (B-D2); agregado só por dia, esconder um profissional não mexeria na barra e a
  Semana passaria a discordar do Dia sobre o mesmo dia.

  ## Por que não é um `GROUP BY` no banco

  O doc 25 §9 pedia "uma query agregada `GROUP BY` dia". O que ele estava recusando é o que o
  protótipo fazia: `renderMonth` carregava tudo e contava **42 vezes por render**, no cliente.
  Aqui a leitura é **uma só** para a janela inteira, e o agrupamento é uma passada em memória
  sobre o resultado — a diferença que motivava o pedido está resolvida.

  Descer o `GROUP BY` para SQL exigiria montar a query em Ecto cru, e aí o recorte A7 (o papel
  `profissional` só vê a própria agenda) teria de ser **reescrito à mão** ao lado da versão que
  vive em `OwnAgendaOnly` — o achado (b) do doc 26, que a §7 acabou de fechar, nascendo de novo
  no mesmo mês. Passando pela mesma code interface da visão Dia, o recorte vem de graça e é o
  mesmo. A janela é limitada a 31 dias no controller, então o volume lido é o de um mês.

  As **linhas** são um profissional ativo cada, sem recorte de papel — as mesmas colunas que a
  visão Dia desenha. O que o recorte esconde são os agendamentos, não a existência da escala.
  """
  def load_counts(%Api.Scope{} = scope, %Date{} = from, %Date{} = to, timezone) do
    dates = Date.range(from, to) |> Enum.to_list()

    in_clinic(scope, fn ->
      {janela_de, janela_ate} = Api.Scheduling.LocalTime.window!(from, to, timezone)

      # `select` enxuto: a agregação usa quatro campos, e a leitura trazia as 17 colunas —
      # incluindo `obs`, que é texto livre. Medido no bate-volta: 3,2 MB de heap por request de
      # Mês numa clínica cheia (10 profissionais × 31 dias) para produzir 310 células de
      # contagem. O recorte A7 continua vindo da preparation, que filtra por `professional_id`
      # sem precisar selecioná-lo.
      appointments =
        list_appointments!(janela_de, janela_ate,
          scope: scope,
          query: [select: [:starts_at, :ends_at, :status, :professional_id]]
        )

      professionals =
        Api.Directory.list_professionals!(scope: scope, query: [filter: [ativo: true]])

      ocupacao = occupancy_by_day(appointments, timezone)

      sources =
        gather_sources(Enum.map(professionals, & &1.id), dates,
          tenant: scope.clinic_id,
          authorize?: false
        )

      # Os profissionais vão junto pelo mesmo motivo do `GET /api/appointments`: a barra
      # lateral é a mesma nas quatro visões, e é dela que sai o filtro de ocultar. Devolver só
      # as contagens deixava a lista vazia em Semana e Mês — e o toggle inoperante justamente
      # nas visões que ele precisa recortar.
      %{
        days:
          Enum.map(dates, fn date ->
            %{
              date: date,
              professionals: Enum.map(professionals, &day_count(&1, date, sources, ocupacao))
            }
          end),
        professionals: professionals
      }
    end)
  end

  # `%{{date, professional_id} => {total, minutos}}`. Cancelado fica de fora dos dois: é a
  # mesma regra de `ocupaGrade` (doc 25 §7) — não disputa espaço, então não conta.
  defp occupancy_by_day(appointments, timezone) do
    appointments
    |> Enum.reject(&(&1.status == :cancelado))
    |> Enum.group_by(fn appt ->
      {Api.Scheduling.LocalTime.to_local_date(appt.starts_at, timezone), appt.professional_id}
    end)
    |> Map.new(fn {chave, agendamentos} ->
      minutos =
        Enum.reduce(agendamentos, 0, fn appt, acc ->
          acc + div(DateTime.diff(appt.ends_at, appt.starts_at), 60)
        end)

      {chave, {length(agendamentos), minutos}}
    end)
  end

  defp day_count(professional, date, sources, ocupacao) do
    {total, minutos} = Map.get(ocupacao, {date, professional.id}, {0, 0})

    %{
      professional_id: professional.id,
      total: total,
      ocupado_minutos: minutos,
      capacidade_minutos: capacity_minutes(professional, date, sources)
    }
  end

  # O denominador da barra (A-D11/A-D12): o expediente REAL do dia, resolvido pelas mesmas 4
  # camadas que a visão Dia usa para hachurar. Dia fechado devolve 0 — e 0 é o que a tela lê
  # como "fechado", que não é a mesma coisa que "aberto e vazio".
  defp capacity_minutes(professional, date, sources) do
    case Api.Scheduling.Availability.day_periods(
           date,
           professional,
           Map.fetch!(sources, professional.id)
         ) do
      {:open, periods} ->
        Enum.reduce(periods, 0, fn [ini, fim], acc ->
          # `Kernel.max/2` qualificado: o domínio já define um `max` (agregado do Ash), e o
          # não-qualificado colide na compilação.
          acc +
            Kernel.max(
              0,
              Api.Scheduling.Periods.to_minutes(fim) - Api.Scheduling.Periods.to_minutes(ini)
            )
        end)

      {:closed, _reason} ->
        0
    end
  end

  # ---- Relatórios: snapshot de métricas do período (doc 33, Fatia 9) ----

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

      appointments =
        list_appointments!(janela_de, janela_ate,
          scope: scope,
          query: [
            filter: summary_filter(escopo),
            select: [:starts_at, :ends_at, :status, :professional_id, :appointment_type_id]
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
      list = Map.get(by_date, date, [])

      %{
        date: date,
        total: length(list),
        concluidos: Enum.count(list, &(&1.status == :concluido))
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

  defp summary_totais(appointments, ativos, ocupado, capacidade_dia, dias) do
    concluidos = Enum.count(appointments, &(&1.status == :concluido))
    faltas = Enum.count(appointments, &(&1.status == :faltou))
    capacidade = Enum.sum(capacidade_dia)

    %{
      atendimentos: length(ativos),
      concluidos: concluidos,
      faltas: faltas,
      cancelados: Enum.count(appointments, &(&1.status == :cancelado)),
      futuros:
        Enum.count(appointments, &(&1.status in [:agendado, :confirmado, :em_atendimento])),
      taxa_falta: taxa_falta(concluidos, faltas),
      ocupacao: ocupacao_pct(ocupado, capacidade),
      ocupado_minutos: ocupado,
      capacidade_minutos: capacidade,
      dias_uteis: Enum.count(capacidade_dia, &(&1 > 0)),
      pico: summary_pico(dias)
    }
  end

  defp summary_por_tipo(ativos) do
    ativos
    |> Enum.group_by(& &1.appointment_type_id)
    |> Enum.map(fn {type_id, list} -> %{appointment_type_id: type_id, total: length(list)} end)
    |> Enum.sort_by(& &1.total, :desc)
  end

  defp summary_por_profissional(appointments, professionals) do
    by_prof = Enum.group_by(appointments, & &1.professional_id)

    professionals
    |> Enum.map(fn prof ->
      ativos = by_prof |> Map.get(prof.id, []) |> Enum.reject(&(&1.status == :cancelado))
      concluidos = Enum.count(ativos, &(&1.status == :concluido))
      faltas = Enum.count(ativos, &(&1.status == :faltou))

      %{
        professional_id: prof.id,
        total: length(ativos),
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

  defp patients_for(scope, appointments) do
    ids =
      appointments
      |> Enum.flat_map(fn appt -> Enum.map(appt.attendances || [], & &1.patient_id) end)
      |> Enum.uniq()

    case ids do
      [] ->
        []

      ids ->
        # `select` enxuto: `AgendaJSON.patient/1` usa quatro campos, e a leitura crua traz as ~39
        # colunas do cadastro — CPF, RG, `prefs` — e agora **por assinante por evento**, já que a
        # releitura do canal (`load_visible_appointment/2`) passa por aqui. É o mesmo corte que o
        # doc 27 (Causa 2) aplicou a `load_counts`, que ficou de fora de `patients_for`. Corta PII
        # que não é usada e o peso de coluna no caminho quente do tempo real.
        Api.Records.list_patients!(
          scope: scope,
          query: [filter: [id: [in: ids]], select: [:id, :nome, :tel, :ativo]],
          # `faltas` (agregado) alimenta o cartão do paciente no drawer (Entrega 4). Uma
          # agregação por leitura da janela — e, no caminho quente do tempo real, por bloco.
          load: [:faltas]
        )
    end
  end

  # ---- Agenda: trilha de auditoria (doc 25 §11.4) ----

  # Colunas de `changes` que NÃO viram linha de diff na tela. Chaves são **strings** (`changes`
  # é `:map` sobre jsonb). Três grupos:
  #
  #   * internas/derivadas — `version` (contador de locking, ruído a cada escrita), a PK, o
  #     tenant (implícito), `ends_at` (derivado de `starts_at` + duração — dobraria a linha de
  #     todo remarcar), `pkg_hold`/`package_id` (ganchos da Fatia 3), `inserted_at`/`updated_at`
  #     (já `ignore_attributes` no paper_trail, aqui por defesa);
  #   * FKs por-uuid — `professional_id`, `appointment_type_id`, `patient_id`, `appointment_id`,
  #     `created_by_id`: um diff `<uuid> → <uuid>` não diz nada à recepção, e o **estado atual**
  #     do profissional/paciente/autor já vem enriquecido por nome (o autor em `actor`).
  #     Diferenciá-los por nome no próprio diff é enriquecimento a mais, adiado (o §11.4
  #     exemplifica só `status` e `starts_at`).
  @audit_diff_ignore ~w(version id clinic_id ends_at pkg_hold package_id inserted_at updated_at
                        professional_id appointment_type_id patient_id appointment_id created_by_id)

  @doc """
  Uma **página** da trilha de auditoria da clínica ativa (doc 25 §11.4), pronta para a tela:
  cada entrada traz **quem · quando · qual ação · qual registro** e o **diff campo-a-campo**.

  Opções (todas opcionais): `:resource` (`:appointment` — default — ou `:attendance`),
  `:record_id` (histórico de um registro só), `:user_id` (por autor), `:action_name` (por ação),
  `:from`/`:to` (janela sobre `version_inserted_at`), `:limit`, `:offset`.

  Devolve `%{entries: [...], page: %{limit, offset, total, more}}`.

  ## Por que o diff é montado aqui, não no cliente

  O `change_tracking_mode` é `:changes_only` (A-D13): cada versão guarda **só o valor novo** dos
  campos que mudaram. Para o *"de 08:00 para 09:00"* a tela precisa do valor **anterior**, que se
  reconstrói **encadeando** as versões do mesmo registro. O §11.4 é explícito: isso é trabalho do
  backend — se vazasse para o cliente, viraria N+1 na tabela que mais cresce. Fazemos uma leitura
  a mais (as cadeias dos registros citados na página) e dobramos em memória.

  ## Autorização

  A leitura da página passa por policy (`authorize?: true` + escopo): a trilha é **owner·admin**
  (`TrailMixin`), então um papel abaixo recebe página vazia — o mesmo recorte da agenda. As
  leituras de **enriquecimento** (autor, profissional, paciente, cadeias) são `authorize?: false`,
  detalhe interno já sob o tenant da GUC — o precedente de `count_participants`/`load_clinic`.
  """
  def list_audit_log(%Api.Scope{} = scope, opts \\ []) do
    resource = Keyword.get(opts, :resource, :appointment)
    limit = opts |> Keyword.get(:limit) |> Api.Pagination.limit()
    offset = opts |> Keyword.get(:offset) |> Api.Pagination.offset()

    in_clinic(scope, fn ->
      page = page_versions(resource, scope, opts, limit, offset)

      %{
        entries: enrich_versions(resource, scope, page.results),
        page: %{limit: page.limit, offset: page.offset, total: page.count, more: page.more?}
      }
    end)
  end

  defp page_versions(:appointment, scope, opts, limit, offset) do
    query = audit_query(Api.Scheduling.Appointment.Version, opts)

    page_appointment_versions!(
      scope: scope,
      query: query,
      page: [limit: limit, offset: offset, count: true]
    )
  end

  defp page_versions(:attendance, scope, opts, limit, offset) do
    query = audit_query(Api.Scheduling.Attendance.Version, opts)

    page_attendance_versions!(
      scope: scope,
      query: query,
      page: [limit: limit, offset: offset, count: true]
    )
  end

  # Filtros do §11.4 aplicados condicionalmente sobre o recurso de versão. Explícitos (uma
  # cláusula por campo) e não com nome de campo dinâmico: `Ash.Query.filter` é macro, e um
  # `ref(^field)` só embaralharia o que aqui são cinco linhas legíveis.
  defp audit_query(resource, opts) do
    resource
    |> filter_record(Keyword.get(opts, :record_id))
    |> filter_user(Keyword.get(opts, :user_id))
    |> filter_action(Keyword.get(opts, :action_name))
    |> filter_from(Keyword.get(opts, :from))
    |> filter_to(Keyword.get(opts, :to))
  end

  defp filter_record(query, nil), do: query
  defp filter_record(query, id), do: Ash.Query.filter(query, version_source_id == ^id)

  defp filter_user(query, nil), do: query
  defp filter_user(query, id), do: Ash.Query.filter(query, user_id == ^id)

  defp filter_action(query, nil), do: query
  defp filter_action(query, name), do: Ash.Query.filter(query, version_action_name == ^name)

  defp filter_from(query, nil), do: query
  defp filter_from(query, from), do: Ash.Query.filter(query, version_inserted_at >= ^from)

  defp filter_to(query, nil), do: query
  defp filter_to(query, to), do: Ash.Query.filter(query, version_inserted_at < ^to)

  defp enrich_versions(_resource, _scope, []), do: []

  defp enrich_versions(:appointment, scope, versions) do
    diffs = chain_diffs(:appointment, scope, distinct(versions, & &1.version_source_id))
    actors = actors_map(versions)
    profs = professionals_map(scope, distinct(versions, & &1.professional_id))

    Enum.map(versions, fn v ->
      base_entry(v, actors, diffs)
      |> Map.merge(%{
        resource: :appointment,
        starts_at: v.starts_at,
        professional: Map.get(profs, v.professional_id)
      })
    end)
  end

  defp enrich_versions(:attendance, scope, versions) do
    diffs = chain_diffs(:attendance, scope, distinct(versions, & &1.version_source_id))
    actors = actors_map(versions)
    patients = patients_map(scope, distinct(versions, & &1.patient_id))

    Enum.map(versions, fn v ->
      base_entry(v, actors, diffs)
      |> Map.merge(%{
        resource: :attendance,
        patient: Map.get(patients, v.patient_id),
        appointment_id: v.appointment_id
      })
    end)
  end

  # O que appointment e attendance têm em comum. O contexto específico (starts_at/professional
  # × patient/appointment) é mesclado por cima em `enrich_versions`.
  defp base_entry(v, actors, diffs) do
    %{
      id: v.id,
      record_id: v.version_source_id,
      action: v.version_action_name,
      action_type: v.version_action_type,
      at: v.version_inserted_at,
      status: v.status,
      actor: Map.get(actors, v.user_id),
      diff: Map.get(diffs, v.id, []),
      starts_at: nil,
      professional: nil,
      patient: nil,
      appointment_id: nil
    }
  end

  defp distinct(versions, fun),
    do: versions |> Enum.map(fun) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  # O "de X para Y" (§11.4): lê a cadeia inteira (ascendente) de cada registro citado na página
  # e dobra em memória. Uma leitura para todas as cadeias — `version_source_id in ^ids`.
  defp chain_diffs(_resource, _scope, []), do: %{}

  defp chain_diffs(:appointment, scope, source_ids) do
    list_appointment_versions!(
      scope: scope,
      authorize?: false,
      query: [
        filter: [version_source_id: [in: source_ids]],
        sort: [version_inserted_at: :asc, id: :asc]
      ]
    )
    |> diffs_for_chains()
  end

  defp chain_diffs(:attendance, scope, source_ids) do
    list_attendance_versions!(
      scope: scope,
      authorize?: false,
      query: [
        filter: [version_source_id: [in: source_ids]],
        sort: [version_inserted_at: :asc, id: :asc]
      ]
    )
    |> diffs_for_chains()
  end

  # `%{version_id => [%{field, from, to}]}`. Cada registro é dobrado em separado (o snapshot
  # acumulado de um não contamina o do outro).
  defp diffs_for_chains(versions) do
    versions
    |> Enum.group_by(& &1.version_source_id)
    |> Enum.flat_map(fn {_source, chain} -> Map.to_list(diffs_by_version(chain)) end)
    |> Map.new()
  end

  # Dobra uma cadeia (já ascendente) mantendo o snapshot acumulado; o "de" de cada campo é o
  # que o snapshot tinha ANTES desta versão, o "para" é o valor novo em `changes`.
  defp diffs_by_version(chain) do
    {_snapshot, by_id} =
      Enum.reduce(chain, {%{}, %{}}, fn v, {snapshot, acc} ->
        changes = v.changes || %{}

        diff =
          changes
          |> Map.drop(@audit_diff_ignore)
          |> Enum.map(fn {field, to} ->
            %{field: field, from: Map.get(snapshot, field), to: to}
          end)
          |> Enum.sort_by(& &1.field)

        {Map.merge(snapshot, changes), Map.put(acc, v.id, diff)}
      end)

    by_id
  end

  defp actors_map(versions) do
    case distinct(versions, & &1.user_id) do
      [] ->
        %{}

      ids ->
        # Usuário é GLOBAL (não por-tenant) — sem escopo, `authorize?: false`. `select` enxuto:
        # a tela mostra só o nome do autor.
        Api.Accounts.list_users!(
          authorize?: false,
          query: [filter: [id: [in: ids]], select: [:id, :nome]]
        )
        |> Map.new(&{&1.id, %{id: &1.id, nome: &1.nome}})
    end
  end

  defp professionals_map(_scope, []), do: %{}

  defp professionals_map(scope, ids) do
    Api.Directory.list_professionals!(
      scope: scope,
      authorize?: false,
      query: [filter: [id: [in: ids]], select: [:id, :nome]]
    )
    |> Map.new(&{&1.id, %{id: &1.id, nome: &1.nome}})
  end

  defp patients_map(_scope, []), do: %{}

  defp patients_map(scope, ids) do
    Api.Records.list_patients!(
      scope: scope,
      authorize?: false,
      query: [filter: [id: [in: ids]], select: [:id, :nome]]
    )
    |> Map.new(&{&1.id, %{id: &1.id, nome: &1.nome}})
  end

  # ---- Agenda: fontes de disponibilidade ----

  @doc """
  Carrega a clínica (para o `timezone`, ADR-009) por id, sem policy — é dado de configuração
  lido de dentro de uma ação que já autorizou.
  """
  def load_clinic(clinic_id) when is_binary(clinic_id) do
    Api.Accounts.get_clinic!(clinic_id, authorize?: false)
  end

  @doc """
  Só o fuso da clínica (ADR-009) — **cacheado** (`Api.Accounts.ClinicTimezone`, D-K).

  A imensa maioria dos chamadores de `load_clinic/1` queria uma coluna só, e pagava um PK-hit
  por escrita e por leitura de janela para consegui-la. Quem precisa das outras colunas
  (`cap_turma_padrao`, `slot_minutos` — valores de **validação**, que não se serve de cache)
  continua em `load_clinic/1`.
  """
  def clinic_timezone(clinic_id) when is_binary(clinic_id),
    do: Api.Accounts.ClinicTimezone.fetch(clinic_id)

  @doc """
  O relógio da clínica ativa (ADR-009) já resolvido: `%{timezone, today, now_minutes}` a partir
  do `scope.now`. Fonte única — `Api.Waitlist.find_slots`/`who_fits` e a fronteira derivavam este
  trio (`load_clinic` → `timezone` → `to_local_date`/`to_local_minutes`) cada um por si, e o
  `candidates` chegava a ler a clínica duas vezes por request (bate-volta E5, achado D1).
  """
  def clinic_now(%Api.Scope{clinic_id: clinic_id, now: now}) do
    tz = clinic_timezone(clinic_id)

    %{
      timezone: tz,
      today: Api.Scheduling.LocalTime.to_local_date(now, tz),
      now_minutes: Api.Scheduling.LocalTime.to_local_minutes(now, tz)
    }
  end

  @doc """
  As quatro fontes que `Api.Scheduling.Availability` compõe, para um profissional numa data.

  **Abre a própria transação com a GUC setada** (`Api.Repo.with_clinic/2`), em vez de chamar
  `set_clinic_guc/1` solto. Dois motivos, e os dois só aparecem no servidor real:

    * a GUC é `set_config(..., is_local: true)`, ou seja **vive só dentro de uma transação**.
      Chamada fora de uma, ela vale para o statement corrente e evapora — as leituras
      seguintes rodam sem tenant, a RLS devolve 0 linhas e o dia inteiro parece fechado;
    * não dá para depender do `SetTenantGuc` da ação: os dois são `before_action` e a ordem
      entre eles não é garantida.

  Chamada de **dentro** da transação de uma ação (é o caso do `CheckAvailability`), o
  `Repo.transaction` aninhado apenas se junta à de fora e o `SET LOCAL` cai no lugar certo.

  Nada disto aparece no `mix test`: o sandbox conecta como `postgres` (BYPASSRLS).

  Retornos: `{:ok, professional, sources}` · `{:error, :professional_not_found}`.
  """
  def load_availability_sources(clinic_id, professional_id, %Date{} = date)
      when is_binary(clinic_id) and is_binary(professional_id) do
    in_clinic(clinic_id, fn ->
      case Api.Directory.get_professional(professional_id,
             tenant: clinic_id,
             authorize?: false,
             not_found_error?: false
           ) do
        {:ok, nil} ->
          {:error, :professional_not_found}

        {:error, _} ->
          {:error, :professional_not_found}

        {:ok, professional} ->
          {:ok, professional, sources_for(clinic_id, professional_id, date)}
      end
    end)
  end

  @doc """
  As fontes de disponibilidade de **vários profissionais** ao longo de **uma janela de datas**,
  em um punhado fixo de leituras.

  ## Por que existe (achado (f) do doc 26)

  `load_availability_sources/3` responde por *(profissional, dia)*, e o controller a chamava em
  laço: 30 dias custavam ~254 queries, e o fan-out do BFF (uma requisição por coluna)
  multiplicava isso por profissional — até ~480 leituras para desenhar um dia com 10 colunas.

  O custo aqui **não acompanha nem os dias nem os profissionais**: são cinco leituras —
  profissionais, expediente da clínica, grade dos profissionais, exceções da clínica na janela,
  exceções dos profissionais na janela — e o resto é agrupamento em memória.

  Isso funciona porque `Api.Scheduling.Availability` é puro e já recorta por data (`on_date`) e
  por dia-da-semana: entregar a ele a janela inteira em vez do dia isolado não muda o veredito
  de dia nenhum. A composição por dia continua onde sempre esteve; o que mudou foi só de onde
  vêm as listas.

  Retornos: `{:ok, [{professional, sources}]}` — na ordem de `professional_ids` — ou
  `{:error, :professional_not_found}` se **algum** id não existir na clínica.
  """
  def load_availability_window(clinic_id, professional_ids, %Date{} = from, %Date{} = to)
      when is_binary(clinic_id) and is_list(professional_ids) do
    dates = Date.range(from, to) |> Enum.to_list()

    in_clinic(clinic_id, fn ->
      opts = [tenant: clinic_id, authorize?: false]
      professionals = professionals_by_id(professional_ids, opts)

      # Fail-closed: id desconhecido (ou de outra clínica, que a RLS já esconde) derruba a
      # requisição inteira em 404, em vez de devolver silenciosamente menos colunas do que se
      # pediu — a tela desenharia um dia incompleto sem sinal nenhum de que faltou algo.
      if Enum.any?(professional_ids, &(not Map.has_key?(professionals, &1))) do
        {:error, :professional_not_found}
      else
        {:ok, window_sources(professional_ids, professionals, dates, opts)}
      end
    end)
  end

  defp professionals_by_id(ids, opts) do
    query = Ash.Query.filter(Api.Directory.Professional, id in ^ids)

    [query: query]
    |> Kernel.++(opts)
    |> Api.Directory.list_professionals!()
    |> Map.new(&{&1.id, &1})
  end

  # As quatro fontes de disponibilidade, para N profissionais em N datas. **Ponto único**: a
  # leitura (`load_availability_window/4`, a agenda) e a escrita
  # (`load_availability_sources/3`, o `CheckAvailability` que valida expediente ao agendar)
  # entram as duas por aqui.
  #
  # Elas nasceram como duas funções — uma por-dia, outra por-janela — com as mesmas quatro
  # leituras e só o operador do filtro divergindo (`== ^date` × `in ^dates`). Duas escritas da
  # mesma regra: uma quinta fonte de disponibilidade, ou uma mudança de filtro, entraria num
  # lado só, e a agenda passaria a discordar do validador de escrita sobre o que é expediente —
  # que é literalmente o achado (b) deste mesmo doc 26, só que em outro lugar. Como `in ^lista`
  # cobre `== ^valor` com lista de um, a forma de janela é a geral e a de dia é o caso
  # particular.
  defp gather_sources(ids, dates, opts) do
    clinic_hours = list_clinic_hours_rows!(opts)

    professional_hours =
      [query: Ash.Query.filter(Api.Scheduling.ProfessionalHours, professional_id in ^ids)]
      |> Kernel.++(opts)
      |> list_professional_hours_rows!()
      |> Enum.group_by(& &1.professional_id)

    clinic_exceptions =
      [
        query:
          Ash.Query.filter(
            Api.Scheduling.ScheduleException,
            is_nil(professional_id) and data in ^dates
          )
      ]
      |> Kernel.++(opts)
      |> list_schedule_exceptions!()

    professional_exceptions =
      [
        query:
          Ash.Query.filter(
            Api.Scheduling.ScheduleException,
            professional_id in ^ids and data in ^dates
          )
      ]
      |> Kernel.++(opts)
      |> list_schedule_exceptions!()
      |> Enum.group_by(& &1.professional_id)

    Map.new(ids, fn id ->
      {id,
       %{
         clinic_hours: clinic_hours,
         professional_hours: Map.get(professional_hours, id, []),
         clinic_exceptions: clinic_exceptions,
         professional_exceptions: Map.get(professional_exceptions, id, [])
       }}
    end)
  end

  defp window_sources(ids, professionals, dates, opts) do
    sources = gather_sources(ids, dates, opts)
    Enum.map(ids, &{Map.fetch!(professionals, &1), Map.fetch!(sources, &1)})
  end

  defp sources_for(clinic_id, professional_id, date) do
    [professional_id]
    |> gather_sources([date], tenant: clinic_id, authorize?: false)
    |> Map.fetch!(professional_id)
  end

  # ---- ClinicHours (expediente semanal) ----

  @doc "As 7 linhas do expediente da clínica ativa, ordenadas por dia-da-semana."
  def list_clinic_hours(%Api.Scope{} = scope) do
    in_clinic(scope, fn -> list_clinic_hours_rows!(scope: scope) end)
  end

  @doc """
  Substitui o expediente dos dias em `week` (mapa `%{dow => periods}`), **atomicamente e numa
  única transação**. Valida a semana inteira **antes** de escrever, então nenhuma ação falha no
  meio — o que, sob transação manual, viraria 500 em vez de 422 (ver `SetTenantGuc`). Os upserts
  compartilham a transação (a GUC de cada um, `SET LOCAL`, persiste nela), então é 1 checkout em
  vez de 7. Pedimos as notificações de volta (`return_notifications?`) e as emitimos fora, para
  não perder eventual notifier e não disparar o alerta do Ash. Só os dias no mapa são tocados.

  Retornos: `{:ok, rows}` · `{:error, {:invalid, details}}` (períodos malformados).
  """
  def update_clinic_hours(%Api.Scope{} = scope, week) when is_map(week) do
    case validate_week(week) do
      :ok ->
        {:ok, notifications} =
          Api.Repo.transaction(fn ->
            Enum.flat_map(week, fn {dow, periods} ->
              {:ok, _row, notifications} =
                set_clinic_hours_day(%{dow: dow, periods: periods},
                  scope: scope,
                  return_notifications?: true
                )

              notifications
            end)
          end)

        Ash.Notifier.notify(notifications)
        {:ok, list_clinic_hours(scope)}

      {:error, details} ->
        {:error, {:invalid, details}}
    end
  end

  defp validate_week(week) do
    Enum.reduce_while(week, :ok, fn {dow, periods}, :ok ->
      case Api.Scheduling.Periods.validate(periods) do
        :ok ->
          {:cont, :ok}

        {:error, message} ->
          {:halt, {:error, [%{field: :periods, message: "dia #{dow}: #{message}"}]}}
      end
    end)
  end

  @doc """
  Seed do expediente inicial de uma clínica (do `Clinic.onboard`). Recebe `clinic_id` cru — e
  não um `Api.Scope` — porque roda no `onboard`, quando o tenant acabou de nascer e ainda não
  há escopo. A GUC de cada upsert é setada pelo `SetTenantGuc` da própria ação.
  """
  def seed_clinic_hours(clinic_id, week) when is_binary(clinic_id) and is_list(week) do
    Enum.map(week, &set_clinic_hours_day!(&1, tenant: clinic_id, authorize?: false))
  end

  # ---- ScheduleException (feriados/exceções da clínica) ----

  @doc """
  Os agendamentos **segurados** (`pkg_hold`) de um pacote — a leitura que a retomada precisa e que
  a preparation global esconde de todo mundo (RN-05). Abre a porta `include_held` do `HideHeld` via
  contexto da query; roda sob a GUC de tenant (`in_clinic`), `authorize?: false` (é operação
  interna do pacote, como a materialização). `appointment_ids` vem das presenças do pacote.
  """
  def list_held_sessions(clinic_id, appointment_ids)
      when is_binary(clinic_id) and is_list(appointment_ids) do
    query =
      Api.Scheduling.Appointment
      |> Ash.Query.set_context(%{include_held: true})
      |> Ash.Query.filter(id in ^appointment_ids and pkg_hold == true)

    in_clinic(clinic_id, fn ->
      find_appointments!(query: query, tenant: clinic_id, authorize?: false)
    end)
  end

  @doc """
  As datas de **feriado** da clínica como `MapSet` — exceções da clínica cujo tipo **não** é
  `:horario` (RN-20: só `:fechado` pula a série; expediente especial é dia normal). Recebe o
  `clinic_id` cru, sem `Api.Scope`, porque quem chama pode ser um job de fundo (a materialização do
  pacote) que não tem usuário. Roda sob a GUC de tenant (`in_clinic`), `authorize?: false`.
  """
  def clinic_holidays(clinic_id) when is_binary(clinic_id) do
    query =
      Api.Scheduling.ScheduleException
      |> Ash.Query.filter(is_nil(professional_id))
      |> Ash.Query.filter(tipo != :horario)

    in_clinic(clinic_id, fn ->
      query
      |> list_schedule_exceptions_query(tenant: clinic_id, authorize?: false)
      |> MapSet.new(& &1.data)
    end)
  end

  defp list_schedule_exceptions_query(query, opts) do
    list_schedule_exceptions!(Keyword.put(opts, :query, query))
  end

  @doc "Exceções **da clínica** (professional_id nulo) ativas do escopo, ordenadas por data."
  def list_clinic_exceptions(%Api.Scope{} = scope) do
    # Filtro por `is_nil(professional_id)` via `Ash.Query` (o açúcar `filter: [professional_id:
    # nil]` do code interface não vira `IS NULL`). Passado pela interface, não por `Ash.read!`
    # cru (ash.md).
    query = Ash.Query.filter(Api.Scheduling.ScheduleException, is_nil(professional_id))
    in_clinic(scope, fn -> list_schedule_exceptions!(query: query, scope: scope) end)
  end

  @doc """
  Uma exceção da clínica ativa por id. De outra clínica é indistinguível de inexistente
  (o filtro por atributo não a enxerga) → `{:ok, nil}`, que o controller traduz em 404.
  """
  def fetch_clinic_exception(%Api.Scope{} = scope, id) when is_binary(id) do
    in_clinic(scope, fn -> get_schedule_exception(id, scope: scope) end)
  end

  @doc "Cria uma exceção **da clínica** (professional_id nulo — não é aceito no corpo nesta fatia)."
  def create_clinic_exception(%Api.Scope{} = scope, attrs) do
    create_schedule_exception(attrs, scope: scope)
  end

  @doc "Apaga uma exceção da clínica (doc 22 H4: destroy de verdade)."
  def destroy_clinic_exception(%Api.Scope{} = scope, exception) do
    destroy_schedule_exception(exception, scope: scope)
  end

  # ---- ProfessionalHours (grade semanal do profissional) ----

  @doc "A grade de um profissional (só os dias que ele configurou), ordenada por dia-da-semana."
  def list_professional_hours(%Api.Scope{} = scope, professional_id)
      when is_binary(professional_id) do
    query =
      Ash.Query.filter(Api.Scheduling.ProfessionalHours, professional_id == ^professional_id)

    in_clinic(scope, fn -> list_professional_hours_rows!(query: query, scope: scope) end)
  end

  @doc """
  Substitui a grade de `professional_id` nos dias em `days` (lista de `%{dow:, modo:, periods:}`),
  **atomicamente e numa única transação**. Valida a semana inteira **antes** de escrever —
  forma dos períodos, coerência `modo`↔`periods` e o invariante **prof ⊆ clínica** (custom só
  cabe dentro do expediente da clínica no dia) —, então nenhuma escrita falha no meio. Só os
  dias na lista são tocados (mesmo desenho de `update_clinic_hours/2`).

  Retornos: `{:ok, rows}` · `{:error, :professional_not_in_clinic}` ·
  `{:error, {:invalid, details}}`.
  """
  def update_professional_hours(%Api.Scope{} = scope, professional_id, days)
      when is_binary(professional_id) and is_list(days) do
    with :ok <- ensure_professional_in_clinic(scope, professional_id),
         :ok <- validate_professional_week(scope, days) do
      {:ok, notifications} =
        Api.Repo.transaction(fn ->
          Enum.flat_map(days, fn day ->
            {:ok, _row, notifications} =
              day
              |> Map.put(:professional_id, professional_id)
              |> set_professional_hours_day(scope: scope, return_notifications?: true)

            notifications
          end)
        end)

      Ash.Notifier.notify(notifications)
      {:ok, list_professional_hours(scope, professional_id)}
    end
  end

  defp ensure_professional_in_clinic(%Api.Scope{clinic_id: clinic_id}, professional_id) do
    if Api.Directory.professional_in_clinic?(professional_id, clinic_id),
      do: :ok,
      else: {:error, :professional_not_in_clinic}
  end

  # Confere a semana do profissional contra o expediente da clínica (carregado uma vez).
  defp validate_professional_week(scope, days) do
    clinic = clinic_week_map(scope)

    Enum.reduce_while(days, :ok, fn day, :ok ->
      dow = day[:dow] || day["dow"]

      case validate_professional_day(day, Map.get(clinic, dow, [])) do
        :ok ->
          {:cont, :ok}

        {:error, message} ->
          {:halt, {:error, {:invalid, [%{field: :periods, message: "dia #{dow}: #{message}"}]}}}
      end
    end)
  end

  defp validate_professional_day(day, clinic_periods) do
    modo = day[:modo] || day["modo"]
    periods = day[:periods] || day["periods"] || []

    cond do
      modo in [:herda, :fechado, "herda", "fechado"] and periods != [] ->
        {:error, "modo #{modo} não carrega períodos próprios"}

      modo in [:custom, "custom"] and periods == [] ->
        {:error, "informe ao menos um período para um horário próprio"}

      modo in [:custom, "custom"] ->
        with :ok <- Api.Scheduling.Periods.validate(periods) do
          Api.Scheduling.Periods.within(periods, clinic_periods)
        end

      true ->
        Api.Scheduling.Periods.validate(periods)
    end
  end

  # `%{dow => periods}` do expediente da clínica ativa, para o invariante prof ⊆ clínica.
  defp clinic_week_map(scope) do
    scope
    |> list_clinic_hours()
    |> Map.new(fn row -> {row.dow, row.periods} end)
  end

  # ---- ScheduleException do profissional (folgas/horários pontuais) ----

  @doc "Exceções de um profissional (professional_id preenchido), ordenadas por data."
  def list_professional_exceptions(%Api.Scope{} = scope, professional_id)
      when is_binary(professional_id) do
    query =
      Ash.Query.filter(Api.Scheduling.ScheduleException, professional_id == ^professional_id)

    in_clinic(scope, fn -> list_schedule_exceptions!(query: query, scope: scope) end)
  end

  @doc """
  Cria uma exceção **de um profissional** (folga ou horário pontual). O `professional_id` é
  amarrado aqui (não vem do corpo livre) e precisa ser da clínica ativa.

  Retornos: `{:ok, exception}` · `{:error, :professional_not_in_clinic}` · `{:error, changeset}`.
  """
  def create_professional_exception(%Api.Scope{} = scope, professional_id, attrs)
      when is_binary(professional_id) do
    with :ok <- ensure_professional_in_clinic(scope, professional_id) do
      attrs = Map.put(attrs, :professional_id, professional_id)
      create_schedule_exception(attrs, scope: scope)
    end
  end

  @doc """
  Uma exceção de profissional por id (para o DELETE do controller). De outra clínica é
  indistinguível de inexistente → `{:ok, nil}`, que o controller traduz em 404.
  """
  def fetch_professional_exception(%Api.Scope{} = scope, id) when is_binary(id) do
    in_clinic(scope, fn -> get_schedule_exception(id, scope: scope) end)
  end

  @doc "Apaga uma exceção de profissional (destroy de verdade, como as da clínica)."
  def destroy_professional_exception(%Api.Scope{} = scope, exception) do
    destroy_schedule_exception(exception, scope: scope)
  end
end
