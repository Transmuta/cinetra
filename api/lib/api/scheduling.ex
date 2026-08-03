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
  use Ash.Domain, otp_app: :api

  # Leitura sob RLS (o corte de tenancy é compartilhado — ver `Api.Tenancy`).
  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query

  resources do
    resource Api.Scheduling.Appointment do
      define :list_appointments, action: :in_range, args: [:from, :to]
      define :find_appointments, action: :read
      define :get_appointment, action: :read, get_by: [:id]

      # A interface **crua** da criação. Quem agenda de fora chama `schedule_appointment/2`
      # (abaixo), que decide entre criar e fundir numa turma existente (A-D4).
      define :create_appointment_slot, action: :schedule
      define :add_appointment_participants, action: :add_participant
      define :remove_appointment_participants, action: :remove_participant

      # Interfaces **cruas** do ciclo de vida (Entrega 4). Quem chama de fora usa
      # `transition_appointment/5`, que faz o fetch-then-update com o guard de `version` (409).
      define :reschedule_appointment_slot, action: :reschedule
      define :cancel_appointment_slot, action: :cancel

      # Pausa/retoma uma sessão de pacote (RN-05/23). Recebe `%{pkg_hold: bool}` antes das opções.
      define :set_appointment_pkg_hold, action: :set_pkg_hold
      define :reopen_appointment_slot, action: :reopen
      define :exclude_appointment_slot, action: :exclude
    end

    resource Api.Scheduling.Attendance do
      define :list_attendances, action: :read

      # O recorte do lembrete por relógio (doc 96, A-4): estava escrito à mão dentro do
      # `Api.Messaging.ReminderJob`, com filtro solto sobre a query crua.
      define :list_attendances_na_janela, action: :na_janela, args: [:de, :ate]

      # Segura/solta a presença na pausa do pacote (doc 43 §5c) — cascata interna de `Api.Packages`.
      define :set_attendance_pkg_hold, action: :set_pkg_hold

      # Transições de presença POR PARTICIPANTE (Frente 6/A2). Cruas: quem chama de fora usa
      # `transition_participant/6`, que faz o fetch-then-update com o guard de `version` (409) e o
      # `SessionStarted` sobre o bloco.
      define :mark_attendance_present, action: :mark_present
      define :mark_attendance_absent, action: :mark_absent
      define :reopen_attendance_slot, action: :reopen_attendance
      define :justify_attendance_absence, action: :justify_absence
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

  @doc """
  O `load` do bloco **como ele sai para a fronteira** — as presenças com o que o cartão da agenda
  precisa dizer sobre o pacote (`Attendance.package_sessao` e companhia).

  É uma lista só, e não `load: [:attendances]` repetido em cada porta, pelo mesmo motivo que a
  serialização é uma só (`ApiWeb.AgendaJSON`): o bloco sai por quatro caminhos — o GET da janela,
  o POST que cria, as transições e o push do canal — e um `load` que divergisse entre eles faria
  o cartão **perder** o pacote na primeira vez que alguém marcasse presença. O defeito só
  apareceria depois da escrita, que é o que nenhum teste do GET percorre.
  """
  def bloco_load,
    do: [
      attendances: [
        :package_nome,
        :package_total,
        :package_sessao,
        :package_falta_punitiva,
        # A resposta do paciente ao link (doc 52 §5) — o sinal do card. Desce no mesmo SELECT das
        # presenças, como os quatro de pacote, e por isso sai igual pelas quatro portas do bloco.
        :resposta_do_paciente
      ]
    ]

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
            encaixe: fetch(attrs, :encaixe) in [true, "true"],
            # O pacote atravessa a fusão (doc 41 etapa 2): a série que cai numa turma existente
            # carimba a presença que entrou, e só ela.
            package_id: fetch(attrs, :package_id)
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
         {:ok, _capacidade} <- capacidade_do_tipo(opts, clinic_id, type_id),
         {:ok, starts_at} <- cast_starts_at(fetch(attrs, :starts_at)) do
      query =
        Ash.Query.filter(
          Api.Scheduling.Appointment,
          professional_id == ^professional_id and appointment_type_id == ^type_id and
            starts_at == ^starts_at and status != :cancelado
        )

      # `return_notifications?` é opção de escrita e chega aqui porque `schedule_appointment/2`
      # recebe os mesmos `opts` das duas pontas (a massa do pacote pede notificação da fusão);
      # numa leitura ela não tem sentido e o Ash recusa opção desconhecida.
      read_opts = opts |> Keyword.drop([:return_notifications?]) |> Keyword.put(:query, query)

      case in_clinic_or_tenant(opts, clinic_id, fn -> find_appointments!(read_opts) end) do
        [turma | _] -> turma
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  # "É turma, e de que tamanho?" — a pergunta que decide se esta sessão funde numa existente. Num
  # LOTE o tipo vem aquecido nas opções (`Api.Scheduling.Warm`), e era esta a última leitura de
  # `appointment_types` que sobrava por sessão na massa em turma (doc 43 §5a).
  defp capacidade_do_tipo(opts, clinic_id, type_id) do
    case Api.Scheduling.Warm.tipo(opts, clinic_id, type_id) do
      {:ok, %{grupo: true, capacidade: capacidade}} -> {:ok, capacidade}
      {:ok, _individual} -> :individual
      :miss -> Api.Directory.appointment_type_capacity(type_id, clinic_id)
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

  # A leitura precisa da GUC (ADR-018). `in_clinic/2` aceita as duas formas — `Api.Scope` ou o
  # `clinic_id` cru —, então o que muda entre os ramos é só de onde sai o tenant: do escopo, quando
  # há sessão; do `tenant:` cru, na chamada interna (seed, teste).
  #
  # O ramo de baixo já foi um `{:ok, result} = with_clinic(...); result` escrito à mão — a terceira
  # cópia do desembrulho que `in_clinic/2` faz, e a que o doc 96 conta em R-2/E-2.
  defp in_clinic_or_tenant(opts, clinic_id, fun) do
    case Keyword.get(opts, :scope) do
      %Api.Scope{} = scope -> in_clinic(scope, fun)
      _ -> in_clinic(clinic_id, fun)
    end
  end

  # `attrs` chega com chaves atom (testes, code interfaces) ou string (corpo HTTP).
  #
  # Delega, não copia: `Api.Params` nasceu do bate-volta da Onda 3 (doc 43 §5e) justamente para
  # acabar com as quatro versões divergentes deste padrão — e a cópia tinha voltado (doc 96, R-1).
  defp fetch(attrs, key), do: Api.Params.get(attrs, key)

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

  Conta só as presenças **vivas**: a cancelada não ocupa vaga. Contá-la fazia uma turma com lugar
  livre recusar paciente — medido no bate-volta da Onda 3 (cap 4, duas presenças vivas, entrada
  negada). É a mesma noção de "viva" que o rollup e a massa usam.
  """
  def count_participants(clinic_id, appointment_id)
      when is_binary(clinic_id) and is_binary(appointment_id) do
    {:ok, attendances} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_attendances!(
          tenant: clinic_id,
          authorize?: false,
          query: [filter: [appointment_id: appointment_id, viva?: true]]
        )
      end)

    length(attendances)
  end

  @doc """
  Ciclo de vida do bloco (Entrega 4): remarcar, cancelar, reabrir e excluir. **fetch-then-update**
  com o guard de locking otimista.

  **Concluir, faltar e justificar saíram daqui** (A2, doc 41): o desfecho é das PRESENÇAS, e o
  status do bloco é o rollup delas — ver `transition_participant/6`. Enquanto os dois eixos
  coexistiram, todo guard novo precisava ser escrito duas vezes e o fan-out da fila precisou de um
  tradutor entre os dois nomes de evento.

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
           get_appointment(id, scope: scope, load: bloco_load(), not_found_error?: false)
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
    do: in_clinic(scope, fn -> Ash.load!(updated, bloco_load(), scope: scope) end)

  defp version_ok?(_appt, nil), do: true
  defp version_ok?(%{version: version}, expected), do: version == expected

  defp dispatch_transition(:reschedule, appt, input, scope),
    do: reschedule_appointment_slot(appt, input, scope: scope)

  defp dispatch_transition(:cancel, appt, input, scope),
    do: cancel_appointment_slot(appt, input, scope: scope)

  defp dispatch_transition(:reopen, appt, _input, scope),
    do: reopen_appointment_slot(appt, %{}, scope: scope)

  defp dispatch_transition(:exclude, appt, _input, scope),
    do: exclude_appointment_slot(appt, %{}, scope: scope)

  @doc """
  Transição de presença de **um participante** (Frente 6/A2, doc 41): `:complete` | `:no_show` |
  `:reopen` | `:justify`. Espelha `transition_appointment/5` — fetch-then-update com o guard de
  `version` (409) no **bloco** —, mas escreve na `Attendance` do `patient_id`; o desfecho do bloco
  vira rollup (`Attendance.Changes.RollupBlockStatus`).

  `:complete`/`:no_show` só depois de a sessão começar (`SessionStarted` sobre o `starts_at` do
  bloco — a presença não o tem, e lê-lo dentro da ação cairia antes do `SetTenantGuc`). `:reopen`
  e `:justify` não passam por esse gate. `input` carrega `%{justificada: bool}` no `:justify`.

  Devolve `{:ok, appointment}` (o bloco com o status já rolado e as presenças frescas) ou
  `{:error, :not_found | :participant_not_found | :version_conflict | :session_not_started | _}`.
  """
  def transition_participant(
        scope,
        appointment_id,
        patient_id,
        kind,
        input \\ %{},
        expected_version \\ nil
      )

  def transition_participant(
        %Api.Scope{} = scope,
        appointment_id,
        patient_id,
        kind,
        input,
        expected_version
      )
      when is_binary(appointment_id) and is_binary(patient_id) and is_atom(kind) do
    with {:ok, appt} <- fetch_for_transition(scope, appointment_id, expected_version),
         :ok <- block_open_for_participant(appt),
         :ok <- session_started_ok(appt, kind, scope),
         {:ok, attendance} <- find_participant(appt, patient_id),
         {:ok, _updated} <- dispatch_participant(kind, attendance, input, scope) do
      # O rollup mudou o status/version do bloco: relê o bloco inteiro (não só a relação) para
      # a fronteira renderizar o desfecho novo com as presenças. Uma leitura a mais, no caminho
      # frio de uma transição.
      {:ok,
       in_clinic(scope, fn ->
         get_appointment!(appointment_id, scope: scope, load: bloco_load())
       end)}
    end
  end

  # Um bloco CANCELADO não recebe transição de presença (bate-volta 2026-07-24): sem este guard,
  # `cancel → add_participant → complete` ressuscitava o bloco `:cancelado` para `:concluido` pelo
  # rollup (as canceladas são filtradas), furando o F4 que as ações de bloco garantem. Excluído
  # nem chega aqui (o `HideExcluded` o esconde do fetch → `:not_found`).
  defp block_open_for_participant(%{status: :cancelado}), do: {:error, :block_not_open}
  defp block_open_for_participant(_appt), do: :ok

  # `:reopen`/`:justify` liberam a qualquer hora (desfazer clique errado); concluir/faltar só
  # depois de a sessão começar (RN-58, mesma fronteira do `SessionStarted` do bloco).
  defp session_started_ok(_appt, kind, _scope) when kind in [:reopen, :justify], do: :ok

  defp session_started_ok(%{starts_at: %DateTime{} = starts_at}, _kind, %{now: now}) do
    if DateTime.compare(starts_at, now) != :gt, do: :ok, else: {:error, :session_not_started}
  end

  defp find_participant(%{attendances: attendances}, patient_id) when is_list(attendances) do
    case Enum.find(attendances, &(&1.patient_id == patient_id)) do
      nil -> {:error, :participant_not_found}
      attendance -> {:ok, attendance}
    end
  end

  defp find_participant(_appt, _patient_id), do: {:error, :participant_not_found}

  defp dispatch_participant(:complete, attendance, _input, scope),
    do: mark_attendance_present(attendance, %{}, scope: scope)

  # `input` (e não `%{}`) porque a falta passou a carregar `motivo` (D-H3/D5) — é o único dos
  # quatro verbos de presença que recebe algo do corpo além do próprio verbo. O `justify` já
  # fazia igual, pelo mesmo motivo.
  defp dispatch_participant(:no_show, attendance, input, scope),
    do: mark_attendance_absent(attendance, input, scope: scope)

  defp dispatch_participant(:reopen, attendance, _input, scope),
    do: reopen_attendance_slot(attendance, %{}, scope: scope)

  defp dispatch_participant(:justify, attendance, input, scope),
    do: justify_attendance_absence(attendance, input, scope: scope)

  # ---- Agenda: leitura da tela ----

  # Quantas das próximas o cartão da ficha mostra. É um cartão de resposta ("quando ele volta?"),
  # não uma listagem: a agenda do paciente inteira já tem tela (`/agenda?paciente=`). Um pacote de
  # 20 sessões desenharia 20 linhas aqui e recriaria, do outro lado, o problema que o doc 56 veio
  # resolver.
  @proximas_na_ficha 5

  @doc """
  As **sessões de um paciente** para a ficha (C13, Frente 7): o histórico paginado e as próximas,
  numa transação só.

  É leitura de presença (`Attendance`), não de bloco: numa turma, o que a ficha do paciente conta
  é o que aconteceu **com ele** — o bloco pode estar `:concluido` com a presença dele `:faltou`
  (`attendance.ex:8`). Vem com `package_id` para a ficha distinguir sessão de pacote de sessão
  avulsa.

  **Duas listas, e não uma** (doc 56). Antes era um `sort: :desc` sem recorte de data, e o efeito
  medido ao vivo foi que uma sessão marcada para setembro encabeçava "Histórico de atendimentos"
  com o selo "Previsto" — o cartão afirmava como passado o que ainda não tinha acontecido. Pior
  que o rótulo: as futuras consumiam o teto, então paciente com pacote longo perdia o passado.
  A fronteira é `scope.now` (o relógio injetável, nunca `DateTime.utc_now/0`):

    * `sessions` — `session_starts_at <= now`, do mais recente para o mais antigo, com `:limit` e
      `:offset` (é o que o "ver histórico completo" da ficha pagina);
    * `upcoming` — `session_starts_at > now`, da mais próxima para a mais distante, no teto de
      `#{@proximas_na_ficha}`. Só na primeira página (`offset == 0`): recalcular as próximas para
      desenhar a segunda página do histórico é trabalho de banco para um cartão que não mudou.

  O recorte A7 vale de graça: a preparation `OwnAgendaOnly, via: :appointment` da `Attendance` já
  esconde do papel `profissional` a sessão que não é da coluna dele.

  **Limitado no SQL** (default 50, teto 200): `sort`, `limit` e `offset` descem para o banco, e o
  `limit + 1` responde `more?` sem varrer o resto. A primeira versão aplicava `Enum.sort_by`/
  `Enum.take` **depois** de ler tudo — medido no bate-volta da Onda 3: 4.003 linhas trafegadas
  para desenhar 50 cartões num paciente de 2.000 sessões, e o plano do papel `profissional`
  virava nested loop dirigido pela agenda inteira dele (1.595 buffers contra 57). O índice
  `(clinic_id, patient_id, session_starts_at)` atende os dois recortes: o filtro de data e a
  ordem são a mesma terceira coluna, nas duas direções.

  `patient_id` que não é UUID devolve vazio em vez de estourar: o read do Ash sobe `{:error, _}` no
  cast e o `MatchError` virava **500** na ficha (a mesma armadilha que a tela de auditoria pegou no
  doc 32, e que o `Bulk` já guardava).
  """
  def list_patient_sessions(scope, patient_id, opts \\ [])

  def list_patient_sessions(%Api.Scope{} = scope, patient_id, opts) when is_binary(patient_id) do
    limit = Api.Pagination.limit(Keyword.get(opts, :limit), default: 50, max: 200)
    offset = Api.Pagination.offset(Keyword.get(opts, :offset))

    if uuid?(patient_id) do
      in_clinic(scope, fn ->
        {sessions, more?} = read_patient_sessions(scope, patient_id, :passadas, limit, offset)

        {upcoming, upcoming_more?} =
          if offset == 0 do
            read_patient_sessions(scope, patient_id, :proximas, @proximas_na_ficha, 0)
          else
            {[], false}
          end

        %{sessions: sessions, more?: more?, upcoming: upcoming, upcoming_more?: upcoming_more?}
      end)
    else
      vazio()
    end
  end

  def list_patient_sessions(%Api.Scope{}, _patient_id, _opts), do: vazio()

  defp vazio, do: %{sessions: [], more?: false, upcoming: [], upcoming_more?: false}

  # Um recorte, já cortado em `{página, tem_mais?}`. Ordena pela **coluna** `session_starts_at`
  # (cópia do `starts_at` do bloco, mantida por `ManageParticipants`/`SyncSessionStartsAt`). Era
  # um aggregate: o `ORDER BY … LIMIT` descia igual, mas a subquery não-correlacionada varria a
  # agenda da clínica inteira no hash join (doc 43 §4).
  defp read_patient_sessions(scope, patient_id, recorte, limit, offset) do
    {corte, ordem} = recorte(recorte, scope.now)

    lidas =
      list_attendances!(
        scope: scope,
        query: [
          filter: [patient_id: patient_id, session_starts_at: corte],
          sort: [session_starts_at: ordem],
          # +1 é o que separa "tem mais" de "acabou" sem uma segunda query nem um `COUNT`.
          limit: limit + 1,
          offset: offset
        ],
        load: [appointment: [:appointment_type, :professional]]
      )

    # Sessão segurada (`pkg_hold`) volta com `.appointment` nulo (RN-05) e não é sessão do
    # paciente para efeito de ficha.
    visiveis = Enum.reject(lidas, &is_nil(&1.appointment))

    # **`more?` sai da lista CRUA, não da filtrada** (doc 101, M3). O `+1` é uma pergunta ao banco
    # — "existe uma linha além das que você pediu?" — e só a resposta do banco pode respondê-la.
    # Contando depois do `reject`, uma única segurada entre as `limit + 1` derrubava o `more?` para
    # `false` com mais linhas esperando, e o "ver histórico completo" parava de paginar. Medido:
    # paciente com 8 futuras, 2 seguradas → 4 na tela e o cartão dizendo que acabou.
    #
    # O preço é uma página curta (menos de `limit` itens com o `more?` ligado), e é o preço certo:
    # a alternativa seria repetir o predicado do `HideHeld` no filtro SQL, criando uma segunda
    # fonte da mesma regra — que é a origem da família de bugs das seguradas.
    {Enum.take(visiveis, limit), length(lidas) > limit}
  end

  # A sessão que já começou é passado, mesmo que a presença ainda esteja `:prevista` — quem marca
  # presença o faz depois da hora, e a linha não pode saltar de cartão a cada F5 durante o
  # atendimento. Por isso o `<=` fica com o histórico e o futuro é estritamente `>`.
  defp recorte(:passadas, now), do: {[less_than_or_equal: now], :desc}
  defp recorte(:proximas, now), do: {[greater_than: now], :asc}

  defp uuid?(value), do: Api.Params.uuid?(value)

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
          load: bloco_load()
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
      case get_appointment(appointment_id, scope: scope, load: bloco_load()) do
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
  @doc """
  Os minutos de expediente de um profissional num dia — o **denominador canônico** da ocupação.

  Público porque é compartilhado por dois consumidores em módulos diferentes: a barra da agenda
  (`load_counts/2`, aqui) e o snapshot de Relatórios (`Api.Scheduling.Reports`). Duas contas de
  "quanto cabe no dia" divergiriam no primeiro feriado tratado de forma diferente — e a tela
  passaria a discordar do relatório sobre a mesma clínica.
  """
  def capacity_minutes(professional, date, sources) do
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

  # ---- Relatórios ----

  @doc """
  O snapshot de métricas da tela de Relatórios. Delega para `Api.Scheduling.Reports`.

  Fica aqui como fachada porque `Api.Scheduling` é a porta do domínio: a fronteira não deve
  precisar saber em qual módulo interno a conta mora. O que saiu foi a *implementação* — ~245
  linhas que não tinham acoplamento nenhum com o resto do agendamento além de
  `list_appointments!` e `capacity_minutes/3` (doc 96, E-1).
  """
  defdelegate load_summary(scope, from, to, professional_id, timezone), to: Api.Scheduling.Reports

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
  @doc """
  As quatro fontes de disponibilidade (expediente da clínica e do profissional, exceções de
  ambos) de N profissionais numa janela de datas, numa leitura só por fonte.

  Público pelo mesmo motivo de `capacity_minutes/3`: `Api.Scheduling.Reports` precisa do MESMO
  conjunto de fontes para calcular o denominador de ocupação. Recompor isso lá seria a quinta
  cópia da regra que este próprio comentário explica não poder ter duas.
  """
  def gather_sources(ids, dates, opts) do
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

  # ---- A3 / futureConflicts (D12) ----

  # Quantos conflitos a resposta **detalha**. O `total` é sempre o número real — o teto é da
  # LISTA, não da contagem. Uma tela com 80 linhas não ajuda ninguém a decidir; 10 linhas mais
  # "e outros 70" dizem a mesma coisa e cabem na cabeça de quem vai remarcar um por um.
  @conflitos_detalhados 10

  @doc """
  **A3 (D12)** — os agendamentos futuros que uma mudança de horário quebraria.

  A pergunta é feita **na hora de gravar**, dentro da transação que escreve (ver
  `update_clinic_hours/2` e `Api.Scheduling.ScheduleException.Changes.CheckFutureConflicts`):
  mexer no expediente é a única operação que muda o futuro de agendamentos que ninguém tocou, e
  entre analisar e escrever cabe um agendamento novo.

  `change` é uma das quatro formas de `Api.Scheduling.ImpactAnalysis.change/0` — a semana da
  clínica, a grade de um profissional, uma exceção da clínica ou uma exceção de um profissional.

  Devolve `%{conflicts: [...], total: n}`:

    * `total` é o número **real** de agendamentos afetados, sem teto;
    * `conflicts` detalha os `#{@conflitos_detalhados}` primeiros (por data e horário), com nome
      do profissional e dos pacientes — quem vai remarcar precisa de nome, não de uuid.

  Detalhar só os primeiros é o que permite a contagem ser exata sem custo: a leitura das
  presenças e dos pacientes (o único N do processo) acontece **depois** de saber quem conflita, e
  só para os que a tela vai mostrar.

  ## O recorte da leitura

  "Futuro" é a partir de **agora** (`scope.now`), não do começo do dia: uma mudança de horário não
  desfaz o que já foi atendido hoje de manhã. Só status **abertos** entram — cancelado, concluído
  e falta já aconteceram (ou não vão acontecer), e mudar o expediente não os move.
  """
  def future_conflicts(%Api.Scope{} = scope, change) do
    %{timezone: tz} = clinic_now(scope)

    in_clinic(scope, fn ->
      opts = [tenant: scope.clinic_id, authorize?: false]

      case agendamentos_futuros(scope, opts, tz) do
        [] ->
          %{conflicts: [], total: 0}

        appts ->
          prof_ids = appts |> Enum.map(& &1.professional_id) |> Enum.uniq()
          dates = appts |> Enum.map(& &1.date) |> Enum.uniq()

          professionals = professionals_by_id(prof_ids, opts)
          sources = gather_sources(prof_ids, dates, opts)

          por_prof =
            Map.new(prof_ids, fn id ->
              {id, {Map.get(professionals, id, %{}), Map.fetch!(sources, id)}}
            end)

          conflitos = Api.Scheduling.ImpactAnalysis.conflicts(appts, por_prof, change, tz)

          %{
            conflicts:
              detalhar(Enum.take(conflitos, @conflitos_detalhados), professionals, tz, opts),
            total: length(conflitos)
          }
      end
    end)
  end

  # A agenda futura, **sem sidecar**: só o que o motor precisa para decidir (data e horário
  # locais, profissional). O `stream?` tira o teto da leitura — é ele que permite o `total` ser
  # o número real, e não "500 ou mais". A ordem é a da tela (data, horário).
  defp agendamentos_futuros(scope, opts, tz) do
    query =
      Api.Scheduling.Appointment
      |> Ash.Query.filter(
        starts_at >= ^scope.now and status in ^Api.Scheduling.AppointmentStatus.abertos()
      )
      |> Ash.Query.select([:id, :starts_at, :ends_at, :professional_id])
      |> Ash.Query.sort(starts_at: :asc, id: :asc)

    [query: query, stream?: true]
    |> Kernel.++(opts)
    |> find_appointments!()
    |> Enum.map(&local_shape(&1, tz))
  end

  # A forma que o motor puro consome: data e minutos LOCAIS, porque expediente é sempre local.
  defp local_shape(appt, tz) do
    %{
      id: appt.id,
      date: Api.Scheduling.LocalTime.to_local_date(appt.starts_at, tz),
      starts_at: appt.starts_at,
      ends_at: appt.ends_at,
      professional_id: appt.professional_id
    }
  end

  # Os nomes entram **depois** de saber quem conflita, e só para os que a tela mostra: é uma
  # leitura de N linhas onde N ≤ 10, em vez de carregar presença e paciente de toda a agenda
  # futura só para nomear uns poucos.
  defp detalhar([], _professionals, _tz, _opts), do: []

  defp detalhar(conflitos, professionals, tz, opts) do
    ids = Enum.map(conflitos, & &1.appointment_id)

    pacientes_por_appt =
      [
        query: Ash.Query.filter(Api.Scheduling.Attendance, appointment_id in ^ids),
        load: [:patient]
      ]
      |> Kernel.++(opts)
      |> list_attendances!()
      |> Enum.group_by(& &1.appointment_id, &(&1.patient && &1.patient.nome))

    Enum.map(conflitos, fn conflito ->
      minutos = Api.Scheduling.LocalTime.to_local_minutes(conflito.starts_at, tz)

      conflito
      |> Map.put(:hora, Api.Scheduling.LocalTime.from_minutes(minutos))
      |> Map.put(
        :professional_nome,
        nome_do_profissional(professionals, conflito.professional_id)
      )
      |> Map.put(
        :patients,
        pacientes_por_appt |> Map.get(conflito.appointment_id, []) |> Enum.reject(&is_nil/1)
      )
    end)
  end

  defp nome_do_profissional(professionals, id) do
    case Map.get(professionals, id) do
      %{nome: nome} -> nome
      _ -> nil
    end
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
  As presenças de um pacote **incluindo as seguradas** (`pkg_hold` da presença, doc 43 §5c), para as
  **operações do pacote** — sem o recorte A7.

  Ponto único: a massa (`Api.Packages.Bulk`) e o ciclo de vida (`Api.Packages`) liam isto cada um
  por si, e a partir do momento em que a presença pode estar segurada as duas cópias teriam de
  abrir a mesma porta — a que a preparation `HideHeldAttendances` fecha para todo mundo. Uma
  esquecer é o pacote se esconder de si mesmo, que é exatamente o bug das órfãs (bate-volta
  2026-07-24) numa roupa nova.

  ## Por que `authorize?: false`, como as irmãs `list_held_sessions/2` e `list_sessions_including_held/3`

  Esta leitura resolve **o conjunto de sessões de um pacote**, não "o que este ator enxerga da
  agenda". Ela lia com `scope:` — `authorize?` ligado — e a preparation `OwnAgendaOnly` recortava
  as presenças pela coluna do ator. Como `future_sessions/3` e `held_targets/2` derivam os blocos a
  partir das presenças (`Map.keys(por_bloco)`), o conjunto inteiro herdava o recorte.

  Medido (doc 101, A3), com um pacote cujas sessões estão em colunas de dois profissionais e um
  ator `:profissional` vinculado a uma delas:

    * `cancel_package/2` marcava o pacote `:cancelado` e cancelava **4 de 5** sessões — a da coluna
      do colega ficava `:agendado`, viva, apontando para um pacote morto;
    * `archive_package/2` via `futuras == []` e **arquivava** um pacote com sessão viva na agenda —
      exatamente o estado que a recusa `:sessoes_futuras` existe para impedir.

  Não é vazamento (o recorte fecha, não abre): é corrupção silenciosa de estado. Quem autoriza a
  operação é a policy de `Package`, que é por **papel** e não recorta coluna nenhuma; o conjunto de
  sessões é consequência do pacote, não do clique.

  ## A trilha da ficha também lê por aqui

  O cartão do pacote desenha as bolinhas com esta mesma leitura, e portanto **sem** o recorte —
  decisão de 2026-08-03 (doc 101 §4.1). O contador `usadas` ao lado é um agregado do `Package`, e
  agregado não roda preparation: ele sempre contou o pacote inteiro. Com a trilha recortada, um
  pacote espalhado por duas colunas desenhava quatro bolinhas ao lado de um contador que dizia
  cinco — o cartão discordando de si mesmo, que é exatamente o defeito que o filtro de canceladas
  de `Api.Packages.list_sessions/2` já existia para evitar.
  """
  def list_package_attendances(%Api.Scope{} = scope, package_id, opts \\ []) do
    query =
      Api.Scheduling.Attendance
      |> Ash.Query.set_context(%{include_held: true})
      |> Ash.Query.filter(package_id == ^package_id)

    in_clinic(scope, fn ->
      list_attendances!(
        [query: query, tenant: scope.clinic_id, authorize?: false] ++
          Keyword.take(opts, [:load])
      )
    end)
  end

  @doc """
  As sessões de um pacote pelos ids **incluindo as seguradas** (`pkg_hold`), que o `HideHeld`
  esconde de toda leitura normal. Diferente de `list_held_sessions/2` (que traz **só** as
  seguradas), esta traz **todas** — o cancelar/pausar do pacote precisa das visíveis E das
  seguradas por uma pausa anterior (RN-25). Sem isto, carregar `.appointment` numa presença
  segurada devolve `nil` (bate-volta 2026-07-24): `future_sessions` estourava e as seguradas
  ficavam órfãs. Roda sob a GUC (`in_clinic`), `authorize?: false` (operação interna do pacote).
  """
  def list_sessions_including_held(clinic_id, appointment_ids, opts \\ [])
      when is_binary(clinic_id) and is_list(appointment_ids) do
    query =
      Api.Scheduling.Appointment
      |> Ash.Query.set_context(%{include_held: true})
      |> Ash.Query.filter(id in ^appointment_ids)

    in_clinic(clinic_id, fn ->
      find_appointments!(
        query: query,
        tenant: clinic_id,
        authorize?: false,
        load: Keyword.get(opts, :load, [])
      )
    end)
  end

  # ---- Expediente e exceções: a fachada de `Api.Scheduling.Hours` ----
  #
  # O bloco inteiro (expediente da clínica, grade do profissional e as exceções dos dois — 314
  # linhas) saiu para `Api.Scheduling.Hours` na segunda fatia de E-1 (doc 96). Ficou aqui só a
  # fachada, pelo mesmo motivo de `load_summary/5`: a fronteira não precisa saber em qual módulo
  # interno a regra mora, e é isso que permitiu a mudança sem tocar em controller nem em teste.
  #
  # Por que este bloco demorou mais que o dos relatórios: ele tem quatro dependências cruzadas com
  # o que sobra aqui (`in_clinic/2`, `future_conflicts/2`, `clinic_now/1` e as code interfaces do
  # domínio), contra as três funções que os relatórios tocavam. Elas continuam sendo chamadas de
  # lá — via `import` explícito, que é o que torna a dependência visível em vez de difusa.
  defdelegate list_clinic_hours(scope), to: Api.Scheduling.Hours
  defdelegate update_clinic_hours(scope, week), to: Api.Scheduling.Hours
  defdelegate seed_clinic_hours(clinic_id, week), to: Api.Scheduling.Hours
  defdelegate clinic_holidays(clinic_id), to: Api.Scheduling.Hours
  defdelegate list_clinic_exceptions(scope), to: Api.Scheduling.Hours
  defdelegate fetch_clinic_exception(scope, id), to: Api.Scheduling.Hours
  defdelegate create_clinic_exception(scope, attrs), to: Api.Scheduling.Hours
  defdelegate destroy_clinic_exception(scope, exception), to: Api.Scheduling.Hours
  defdelegate list_professional_hours(scope, professional_id), to: Api.Scheduling.Hours
  defdelegate update_professional_hours(scope, professional_id, days), to: Api.Scheduling.Hours

  defdelegate create_professional_exception(scope, professional_id, attrs),
    to: Api.Scheduling.Hours

  defdelegate fetch_professional_exception(scope, id), to: Api.Scheduling.Hours
  defdelegate destroy_professional_exception(scope, exception), to: Api.Scheduling.Hours
end
