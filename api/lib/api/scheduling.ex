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
    end

    resource Api.Scheduling.Attendance do
      define :list_attendances, action: :read
    end

    # Os recursos `*.Version` acima nasciam registrados (`include_versions?`) mas **sem code
    # interface** — então ler a trilha exigia `Ash.read!` cru, que é justamente o que
    # `.claude/rules/ash.md` manda evitar (e o teste da trilha fazia). Com o `define`, a
    # trilha se lê como qualquer outra coleção do domínio.
    resource Api.Scheduling.Appointment.Version do
      define :list_appointment_versions, action: :read
    end

    resource Api.Scheduling.Attendance.Version do
      define :list_attendance_versions, action: :read
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
  funde — cairia em conflito; o `slot_held` (409) que trataria isso é da Entrega 4.

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

  defp patients_for(scope, appointments) do
    ids =
      appointments
      |> Enum.flat_map(fn appt -> Enum.map(appt.attendances || [], & &1.patient_id) end)
      |> Enum.uniq()

    case ids do
      [] -> []
      ids -> Api.Records.list_patients!(scope: scope, query: [filter: [id: [in: ids]]])
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
