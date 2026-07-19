defmodule Api.Scheduling do
  @moduledoc """
  Domínio da disponibilidade da clínica (doc 22) — recursos **por-tenant** por atributo
  (`strategy :attribute` sobre `clinic_id`, ADR-017). Por ora `ClinicHours` (o expediente
  semanal) e `ScheduleException` (feriados e exceções de data). `ProfessionalHours` e a
  exceção por profissional entram com a seção Profissionais (doc 22 §5).

  Os wrappers `*_clinic_*` centralizam aqui o `Api.Repo.with_clinic/2` (GUC de tenant para a
  RLS) na leitura, como em `Api.Directory` — controllers e changes não falam com o Repo. A
  escrita seta a GUC dentro da própria ação, via `Api.Tenancy.SetTenantGuc`.
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
      define :get_appointment, action: :read, get_by: [:id]
      define :schedule_appointment, action: :schedule
    end

    resource Api.Scheduling.Attendance do
      define :list_attendances, action: :read
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
    {:ok, result} =
      Api.Repo.with_clinic(clinic_id, fn ->
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

    result
  end

  defp sources_for(clinic_id, professional_id, date) do
    opts = [tenant: clinic_id, authorize?: false]

    %{
      clinic_hours: list_clinic_hours_rows!(opts),
      professional_hours:
        list_professional_hours_rows!(
          [
            query:
              Ash.Query.filter(
                Api.Scheduling.ProfessionalHours,
                professional_id == ^professional_id
              )
          ] ++ opts
        ),
      clinic_exceptions:
        list_schedule_exceptions!(
          [
            query:
              Ash.Query.filter(
                Api.Scheduling.ScheduleException,
                is_nil(professional_id) and data == ^date
              )
          ] ++ opts
        ),
      professional_exceptions:
        list_schedule_exceptions!(
          [
            query:
              Ash.Query.filter(
                Api.Scheduling.ScheduleException,
                professional_id == ^professional_id and data == ^date
              )
          ] ++ opts
        )
    }
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
