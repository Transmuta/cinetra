defmodule ApiWeb.AppointmentsController do
  @moduledoc """
  A agenda (doc 25 §5). JSON simples, como todos os controllers do projeto — o `AshJsonApi`
  está montado mas vazio, e a API real é Phoenix à mão.

  `GET` devolve, além dos agendamentos, os **profissionais e tipos inteiros**. Não é
  desperdício: a tela já precisa dos dois para a sidebar e a legenda, e mandá-los uma vez
  resolve o N+1 dos blocos por lookup no cliente (doc 25 §10) — mesmo precedente de
  `professionals_controller.ex:29`.

  O `clinic_id` nunca vem do corpo; `ends_at` também não, porque é derivado (A3/A-D8).
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Scheduling
  alias Api.Scheduling.LocalTime

  # GET /api/appointments?from=YYYY-MM-DD&to=YYYY-MM-DD&professional_id=
  # A leitura da janela (e o teto de 31 dias) mora em `TenantScope.parse_window/4`.
  def index(conn, params) do
    with_member_scope(conn, fn scope ->
      tz = Scheduling.clinic_timezone(scope.clinic_id)

      case parse_window(params, "from", "to") do
        {:ok, from_date, to_date} ->
          render_range(conn, scope, tz, from_date, to_date, params)

        {:error, message} ->
          invalid(conn, message)
      end
    end)
  end

  # GET /api/appointments/:id
  #
  # UM bloco, para resolver o link do drawer (`/agenda?agendamento=<id>`): quem recebe o link
  # não sabe em que dia o bloco está, e é o `timezone` da resposta que permite ao cliente
  # descobrir — o dia local do `starts_at` é a agenda que ele precisa carregar.
  #
  # A visibilidade é a de `load_visible_appointment/2`, a MESMA leitura que o push do canal usa
  # (`Api.Scheduling`): `HideExcluded` e `OwnAgendaOnly` já somem com o bloco excluído e com o
  # bloco do colega quando o papel é `profissional`. Reimplementar o recorte aqui seria a
  # segunda cópia da regra — e um permalink que vaza é pior que um permalink que não abre.
  # `nil` cobre tudo o que não é legível, inclusive id malformado (404, não 500).
  def show(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      case Scheduling.load_visible_appointment(scope, id) do
        %{appointment: appointment, patients: patients} ->
          json(conn, %{
            appointment: render_appointment(appointment),
            # O sidecar de nomes, como no GET da janela: quem chega pelo link não baixou dia
            # nenhum, e o bloco carrega `patient_ids`, não nomes.
            patients: Enum.map(patients, &render_patient/1),
            timezone: Scheduling.clinic_timezone(scope.clinic_id)
          })

        nil ->
          not_found(conn)
      end
    end)
  end

  # POST /api/appointments
  def create(conn, params) do
    with_member_scope(conn, fn scope ->
      attrs =
        whitelist(params, [
          :starts_at,
          :professional_id,
          :appointment_type_id,
          :obs,
          :duration_minutos,
          :encaixe
        ])

      attrs = Map.put(attrs, :patient_ids, List.wrap(params["patient_ids"]))

      case Scheduling.schedule_appointment(attrs, scope: scope) do
        {:ok, appointment} ->
          conn
          |> put_status(:created)
          |> json(%{appointment: render_appointment(appointment)})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # ---- ciclo de vida (Entrega 4, doc 25 §5/§8d) ----
  #
  # Ações **nomeadas**, uma rota por transição — nunca um `PATCH /status` genérico (doc 25 §3).
  # Todas passam por `with_member_scope` (é membro de clínica ativa?); **qual** papel pode o quê
  # é da policy do recurso, e o recorte A7 (profissional só a própria agenda) vem do fetch, que
  # devolve 404 para o bloco do colega. O `expected_version` do corpo vira o guard de 409.

  # PATCH /api/appointments/:id/reschedule — arraste e modal (GAP-03 corrigido no recurso).
  def reschedule(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      transition(
        conn,
        scope,
        id,
        :reschedule,
        whitelist(params, [
          :starts_at,
          :professional_id,
          :encaixe,
          :reschedule_reason,
          :avisar_paciente
        ]),
        params
      )
    end)
  end

  # POST /api/appointments/:id/cancel — motivo opcional (D4).
  def cancel(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      transition(
        conn,
        scope,
        id,
        :cancel,
        whitelist(params, [:cancel_reason, :avisar_paciente]),
        params
      )
    end)
  end

  # POST /api/appointments/:id/reopen — desfaz um clique errado (D-E4.2).
  def reopen(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope -> transition(conn, scope, id, :reopen, %{}, params) end)
  end

  # POST /api/appointments/:id/exclude — soft-delete de lançamento feito por engano (doc 40).
  def exclude(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope -> transition(conn, scope, id, :exclude, %{}, params) end)
  end

  defp transition(conn, scope, id, kind, input, params) do
    handle_transition(
      conn,
      Scheduling.transition_appointment(scope, id, kind, input, expected_version(params))
    )
  end

  # ---- presença por participante (Frente 6/A2, doc 41) ----
  #
  # Sub-rotas do bloco: `POST /appointments/:id/participants/:patient_id/{complete,no_show,reopen,
  # justify}` (docs/09 §3.1.1). Marca UMA presença; o desfecho do bloco vira rollup. O guard de
  # versão (409) e o `SessionStarted` são do `transition_participant/6`; o débito é automático,
  # pela `Attendance.package_id` do dono (Frente 5).

  # POST /api/appointments/:id/participants/:patient_id/complete
  def participant_complete(conn, %{"id" => id, "patient_id" => pid} = params),
    do: participant(conn, id, pid, :complete, %{}, params)

  # POST /api/appointments/:id/participants/:patient_id/no_show
  def participant_no_show(conn, %{"id" => id, "patient_id" => pid} = params),
    do: participant(conn, id, pid, :no_show, whitelist(params, [:motivo]), params)

  # POST /api/appointments/:id/participants/:patient_id/reopen
  def participant_reopen(conn, %{"id" => id, "patient_id" => pid} = params),
    do: participant(conn, id, pid, :reopen, %{}, params)

  # POST /api/appointments/:id/participants/:patient_id/justify
  def participant_justify(conn, %{"id" => id, "patient_id" => pid} = params),
    do:
      participant(
        conn,
        id,
        pid,
        :justify,
        %{justificada: Api.Params.truthy?(params["justificada"])},
        params
      )

  defp participant(conn, id, patient_id, kind, input, params) do
    with_member_scope(conn, fn scope ->
      handle_transition(
        conn,
        Scheduling.transition_participant(
          scope,
          id,
          patient_id,
          kind,
          input,
          expected_version(params)
        )
      )
    end)
  end

  # A escada de resposta é a mesma do bloco; `:participant_not_found` e `:session_not_started`
  # entram no vocabulário das sub-rotas.
  defp handle_transition(conn, result) do
    case result do
      {:ok, appointment} ->
        json(conn, %{appointment: render_appointment(appointment)})

      {:error, kind} when kind in [:not_found, :participant_not_found] ->
        not_found(conn)

      {:error, :version_conflict} ->
        conflict(
          conn,
          "version_conflict",
          "Este agendamento mudou desde que você o abriu. Recarregue e tente de novo."
        )

      {:error, :session_not_started} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "session_not_started", message: "Disponível após o horário da sessão."})

      {:error, :block_not_open} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "block_not_open",
          message: "Este agendamento não está aberto para presença."
        })

      {:error, error} ->
        error_response(conn, error)
    end
  end

  # `expected_version` chega como string do corpo HTTP; ausente pula o guard (mas o cliente
  # sempre manda o que leu, ver `agenda-live.ts`).
  defp expected_version(%{"expected_version" => v}) when is_integer(v), do: v

  defp expected_version(%{"expected_version" => v}) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp expected_version(_params), do: nil

  # GET /api/appointments/counts?from=YYYY-MM-DD&to=YYYY-MM-DD
  #
  # As visões Semana e Mês (Entrega 2). Não devolve blocos: devolve, por dia e por
  # profissional, quantos agendamentos ocupam a grade, quantos minutos eles ocupam e quanto
  # expediente existe — o numerador e o denominador da fórmula única de ocupação (A-D12).
  #
  # Mês carrega contagem, nunca blocos (doc 25 §10): 31 dias de blocos com pacientes e
  # attendances é payload de outra ordem de grandeza para desenhar uma barrinha.
  def counts(conn, params) do
    with_member_scope(conn, fn scope ->
      tz = Scheduling.clinic_timezone(scope.clinic_id)

      case parse_window(params, "from", "to") do
        {:ok, from_date, to_date} ->
          counts = Scheduling.load_counts(scope, from_date, to_date, tz)

          json(conn, %{
            days: Enum.map(counts.days, &render_day_count/1),
            professionals: Enum.map(counts.professionals, &render_professional/1),
            agora: DateTime.to_iso8601(scope.now),
            timezone: tz
          })

        {:error, message} ->
          invalid(conn, message)
      end
    end)
  end

  # A fronteira nomeia o wire, como `render_professional/1` e `render_type/1` — e não o domínio.
  # As linhas de contagem passavam direto de `Api.Scheduling` para o JSON, o que deixava metade
  # do contrato HTTP morando no domínio: renomear `ocupado_minutos` na resposta exigiria editar
  # `Api.Scheduling`, e quem procurasse o nome do campo começaria (e pararia) aqui.
  defp render_day_count(%{date: date, professionals: professionals}) do
    %{
      date: Date.to_iso8601(date),
      professionals: Enum.map(professionals, &render_professional_count/1)
    }
  end

  defp render_professional_count(linha) do
    %{
      professional_id: linha.professional_id,
      total: linha.total,
      ocupado_minutos: linha.ocupado_minutos,
      capacidade_minutos: linha.capacidade_minutos
    }
  end

  # ---- leitura ----

  defp render_range(conn, scope, tz, from_date, to_date, params) do
    # A janela é local: "o dia 20" começa 00:00 em São Paulo, não em UTC. É o que impede o
    # agendamento das 23h de cair no dia seguinte (LocalTime.to_local_date/2). A conversão mora
    # em `LocalTime.window!/3` — ela e a leitura das contagens precisam concordar sobre quais
    # blocos pertencem ao dia, e concordar por construção, não por coincidência.
    {from, to} = LocalTime.window!(from_date, to_date, tz)

    # Uma leitura só, sob a GUC de tenant. Ver `Api.Scheduling.load_agenda/4`: chamar as code
    # interfaces cruas daqui passa no `mix test` e devolve vazio no servidor real.
    agenda = Scheduling.load_agenda(scope, from, to, filter: professional_filter(params))

    json(conn, %{
      appointments: Enum.map(agenda.appointments, &render_appointment/1),
      professionals: Enum.map(agenda.professionals, &render_professional/1),
      appointment_types: Enum.map(agenda.appointment_types, &render_type/1),
      # Só os pacientes citados na janela — e não o cadastro inteiro, que cresce sem limite
      # (foi a dívida da lista de pacientes). É o mesmo lookup-no-cliente de profissionais e
      # tipos, resolvendo o N+1 dos blocos (doc 25 §10) sem carregar o que a tela não usa.
      patients: Enum.map(agenda.patients, &render_patient/1),
      # O "agora" do servidor: a linha do agora e o `needsAction` não podem depender do
      # relógio do browser (doc 25 §6 / ADR-009).
      agora: DateTime.to_iso8601(scope.now),
      timezone: tz
    })
  end

  defp professional_filter(%{"professional_id" => id}) when is_binary(id) and id != "",
    do: [professional_id: id]

  defp professional_filter(_), do: []

  # ---- serialização ----
  #
  # Mora em `ApiWeb.AgendaJSON` desde a Entrega 3, porque deixou de ser exclusiva deste
  # controller: o push do canal serializa o **mesmo** bloco, e o cliente aplica um sobre o
  # outro como patch. Duas cópias divergiriam sem quebrar teste nenhum daqui.

  defp render_appointment(appt), do: ApiWeb.AgendaJSON.appointment(appt)
  defp render_professional(prof), do: ApiWeb.AgendaJSON.professional(prof)
  defp render_patient(paciente), do: ApiWeb.AgendaJSON.patient(paciente)
  defp render_type(tipo), do: ApiWeb.AgendaJSON.appointment_type(tipo)
end
