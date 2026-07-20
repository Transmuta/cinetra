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
      clinic = Scheduling.load_clinic(scope.clinic_id)

      case parse_window(params, "from", "to") do
        {:ok, from_date, to_date} ->
          render_range(conn, scope, clinic, from_date, to_date, params)

        {:error, message} ->
          invalid(conn, message)
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
          |> json(%{appointment: render_appointment(appointment, scope)})

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

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
      clinic = Scheduling.load_clinic(scope.clinic_id)

      case parse_window(params, "from", "to") do
        {:ok, from_date, to_date} ->
          counts = Scheduling.load_counts(scope, from_date, to_date, clinic.timezone)

          json(conn, %{
            days: Enum.map(counts.days, &render_day_count/1),
            professionals: Enum.map(counts.professionals, &render_professional/1),
            agora: DateTime.to_iso8601(scope.now),
            timezone: clinic.timezone
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

  defp render_range(conn, scope, clinic, from_date, to_date, params) do
    tz = clinic.timezone

    # A janela é local: "o dia 20" começa 00:00 em São Paulo, não em UTC. É o que impede o
    # agendamento das 23h de cair no dia seguinte (LocalTime.to_local_date/2). A conversão mora
    # em `LocalTime.window!/3` — ela e a leitura das contagens precisam concordar sobre quais
    # blocos pertencem ao dia, e concordar por construção, não por coincidência.
    {from, to} = LocalTime.window!(from_date, to_date, tz)

    # Uma leitura só, sob a GUC de tenant. Ver `Api.Scheduling.load_agenda/4`: chamar as code
    # interfaces cruas daqui passa no `mix test` e devolve vazio no servidor real.
    agenda = Scheduling.load_agenda(scope, from, to, filter: professional_filter(params))

    json(conn, %{
      appointments: Enum.map(agenda.appointments, &render_appointment(&1, scope)),
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

  # ---- serialização (à mão, omitindo clinic_id — convenção do projeto) ----

  defp render_appointment(appt, _scope) do
    %{
      id: appt.id,
      starts_at: DateTime.to_iso8601(appt.starts_at),
      ends_at: DateTime.to_iso8601(appt.ends_at),
      status: appt.status,
      encaixe: appt.encaixe,
      obs: appt.obs,
      professional_id: appt.professional_id,
      appointment_type_id: appt.appointment_type_id,
      package_id: appt.package_id,
      version: appt.version,
      created_by_id: appt.created_by_id,
      patient_ids: patient_ids(appt)
    }
  end

  defp patient_ids(%{attendances: attendances}) when is_list(attendances),
    do: Enum.map(attendances, & &1.patient_id)

  defp patient_ids(_), do: []

  defp render_professional(prof) do
    %{
      id: prof.id,
      nome: prof.nome,
      nome_exibicao: prof.nome_exibicao,
      crefito: prof.crefito,
      cor_indice: prof.cor_indice,
      segue_horario_clinica: prof.segue_horario_clinica
    }
  end

  # Mínimo para o bloco e o cartão do drawer — nada de ficha clínica aqui (ADR-013/D16).
  defp render_patient(paciente) do
    %{
      id: paciente.id,
      nome: paciente.nome,
      tel: paciente.tel,
      ativo: paciente.ativo
    }
  end

  defp render_type(tipo) do
    %{
      id: tipo.id,
      nome: tipo.nome,
      duracao_minutos: tipo.duracao_minutos,
      cor: tipo.cor,
      icon: tipo.icon,
      grupo: tipo.grupo,
      capacidade: tipo.capacidade
    }
  end
end
