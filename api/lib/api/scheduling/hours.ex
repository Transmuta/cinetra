defmodule Api.Scheduling.Hours do
  @moduledoc """
  **Expediente e exceções** — a quarta das cinco responsabilidades que conviviam em
  `Api.Scheduling` (doc 96, E-1), agora num módulo só.

  O que mora aqui: o expediente semanal da clínica (`ClinicHours`), a grade semanal do
  profissional (`ProfessionalHours`) e as exceções dos dois (`ScheduleException` — feriado, folga,
  horário pontual). Tudo o que **configura quando se pode marcar**.

  O que **não** mora: a agenda em si (o que já está marcado), a leitura de tela, os relatórios
  (`Api.Scheduling.Reports`) e a ponte com pacotes. Esses continuam em `Api.Scheduling`.

  ## Por que sair valeu a pena, e por que só agora

  Este bloco é o segundo maior da fatia e o mais entrelaçado: ao contrário dos relatórios — que
  saíram inteiros porque tocavam o resto em três funções —, o expediente tem quatro dependências
  cruzadas, e é por isso que ficou para uma fatia própria. Elas são explícitas no `import` abaixo,
  e cada uma tem uma razão para não ser duplicada:

    * `in_clinic/2` — a GUC de tenant de toda leitura por-tenant;
    * `future_conflicts/2` — o gate do A3/D12, que roda **dentro** da transação de escrita. Ele é
      do domínio da agenda (lê agendamentos futuros), não do expediente; quem o chama é o
      expediente;
    * `clinic_now/1` — o relógio da clínica (ADR-009);
    * as code interfaces do domínio (`set_clinic_hours_day`, `list_schedule_exceptions!`…), que
      pertencem a `Api.Scheduling` porque é lá que os recursos estão declarados.

  ## A fachada continua sendo `Api.Scheduling`

  Como em `Api.Scheduling.Reports`, todas as funções públicas daqui têm `defdelegate` lá. A
  fronteira (controllers) e os testes não sabem — nem devem saber — em qual módulo interno a regra
  mora. Foi assim que este arquivo nasceu sem mudar uma linha de `ScheduleController`,
  `ProfessionalsController` nem dos testes.
  """
  import Api.Tenancy, only: [in_clinic: 2]

  import Api.Scheduling,
    only: [
      future_conflicts: 2,
      list_clinic_hours_rows!: 1,
      set_clinic_hours_day: 2,
      set_clinic_hours_day!: 2,
      list_schedule_exceptions!: 1,
      get_schedule_exception: 2,
      create_schedule_exception: 2,
      destroy_schedule_exception: 2,
      list_professional_hours_rows!: 1,
      set_professional_hours_day: 2
    ]

  require Ash.Query

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

  **O gate do A3/D12 é absoluto** e roda **dentro da transação que escreve**: se a semana nova
  deixasse algum agendamento futuro fora do expediente, a transação é revertida e volta
  `{:error, {:future_conflicts, %{conflicts: [...], total: n}}}`. Não há como forçar — mudar
  horário por cima de agenda marcada não é uma opção do produto; a lista existe para a recepção
  remarcar um a um e tentar de novo.

  Retornos: `{:ok, rows}` · `{:error, {:invalid, details}}` (períodos malformados) ·
  `{:error, {:future_conflicts, analise}}`.
  """
  def update_clinic_hours(%Api.Scope{} = scope, week) when is_map(week) do
    case validate_week(week) do
      :ok -> escrever_semana_da_clinica(scope, week)
      {:error, details} -> {:error, {:invalid, details}}
    end
  end

  # O **recheck** do A3/D12: a análise roda dentro da mesma transação dos upserts, e não antes
  # dela. Entre "analisei e não achou conflito" e "gravei" cabe um agendamento novo — é a mesma
  # razão de o `CheckAvailability` conferir o expediente dentro da ação de agendar, e não na
  # fronteira. Conflito vira `Repo.rollback`, que é saída controlada: nada foi escrito.
  #
  # Os upserts **não** falham aqui (a semana foi validada antes), então não há erro do Ash
  # arrebentando a transação de fora — a armadilha que `Api.Tenancy` documenta.
  defp escrever_semana_da_clinica(scope, week) do
    resultado =
      Api.Repo.transaction(fn ->
        case future_conflicts(scope, {:clinic_hours, week}) do
          %{total: 0} ->
            Enum.flat_map(week, fn {dow, periods} ->
              {:ok, _row, notifications} =
                set_clinic_hours_day(%{dow: dow, periods: periods},
                  scope: scope,
                  return_notifications?: true
                )

              notifications
            end)

          analise ->
            Api.Repo.rollback({:future_conflicts, analise})
        end
      end)

    case resultado do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, list_clinic_hours(scope)}

      {:error, motivo} ->
        {:error, motivo}
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

  `audit_cascade` cala a trilha destes sete upserts (ver `Api.Audit.Capture`): a semana padrão
  não é decisão de ninguém, e sete "Mudou o expediente" no minuto zero da clínica afogavam a
  única linha que conta o fato — "Criou a clínica". Mudar um dia depois tem linha própria.
  """
  def seed_clinic_hours(clinic_id, week) when is_binary(clinic_id) and is_list(week) do
    Enum.map(
      week,
      &set_clinic_hours_day!(&1,
        tenant: clinic_id,
        authorize?: false,
        context: %{audit_cascade: true}
      )
    )
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

  @doc """
  Cria uma exceção **da clínica** (professional_id nulo — não é aceito no corpo nesta fatia).

  O gate do A3/D12 roda **dentro da ação** (`CheckFutureConflicts`, um `before_action`): um
  feriado sobre um dia com agenda marcada é recusado, e o erro carrega a lista.
  """
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

  Passa pelo mesmo recheck do `update_clinic_hours/2`, **dentro da transação de escrita**:
  estreitar a grade sobre uma sessão já marcada é recusado, e a lista sobe no erro.

  Retornos: `{:ok, rows}` · `{:error, :professional_not_in_clinic}` ·
  `{:error, {:invalid, details}}` · `{:error, {:future_conflicts, analise}}`.
  """
  def update_professional_hours(%Api.Scope{} = scope, professional_id, days)
      when is_binary(professional_id) and is_list(days) do
    with :ok <- ensure_professional_in_clinic(scope, professional_id),
         :ok <- validate_professional_week(scope, days) do
      escrever_grade(scope, professional_id, days)
    end
  end

  # Mesmo desenho de `escrever_semana_da_clinica/2`: o recheck acontece **dentro** da transação
  # que grava, e conflito sai por `Repo.rollback` — controlado, sem nada escrito.
  defp escrever_grade(scope, professional_id, days) do
    resultado =
      Api.Repo.transaction(fn ->
        case future_conflicts(scope, {:professional_hours, professional_id, days}) do
          %{total: 0} ->
            Enum.flat_map(days, fn day ->
              {:ok, _row, notifications} =
                day
                |> Map.put(:professional_id, professional_id)
                |> set_professional_hours_day(scope: scope, return_notifications?: true)

              notifications
            end)

          analise ->
            Api.Repo.rollback({:future_conflicts, analise})
        end
      end)

    case resultado do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, list_professional_hours(scope, professional_id)}

      {:error, motivo} ->
        {:error, motivo}
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

  @modos_validos Api.Scheduling.WeekdayMode.values()

  defp validate_professional_day(day, clinic_periods) do
    modo = day[:modo] || day["modo"]
    periods = day[:periods] || day["periods"] || []

    cond do
      # `modo` é escolha do cliente e não estava validado aqui: um valor inventado atravessava e
      # só morria no `{:ok, _} = set_professional_hours_day(...)` lá embaixo, dentro da
      # transação — `MatchError`, ou seja **500** para entrada malformada (bate-volta doc 49).
      # A escada deste endpoint é 422, como em todo o resto da fronteira.
      not modo_valido?(modo) ->
        {:error, "modo inválido"}

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

  defp modo_valido?(modo) when is_atom(modo) and not is_nil(modo), do: modo in @modos_validos

  defp modo_valido?(modo) when is_binary(modo),
    do: Enum.any?(@modos_validos, &(Atom.to_string(&1) == modo))

  defp modo_valido?(_modo), do: false

  # `%{dow => periods}` do expediente da clínica ativa, para o invariante prof ⊆ clínica.
  defp clinic_week_map(scope) do
    scope
    |> list_clinic_hours()
    |> Map.new(fn row -> {row.dow, row.periods} end)
  end

  # ---- ScheduleException do profissional (folgas/horários pontuais) ----

  @doc """
  Cria uma exceção **de um profissional** (folga ou horário pontual). O `professional_id` é
  amarrado aqui (não vem do corpo livre) e precisa ser da clínica ativa.

  O gate do A3/D12 roda **dentro da ação** e é recortado por profissional: a folga só é barrada
  pelas sessões **daquele** profissional; a agenda dos colegas não entra.

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
