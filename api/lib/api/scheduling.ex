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
  use Ash.Domain, otp_app: :api

  # Leitura sob RLS (o corte de tenancy é compartilhado — ver `Api.Tenancy`).
  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query

  resources do
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

  # Roda `fun` com a GUC de tenant setada (leitura, que não abre transação sozinha).

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
