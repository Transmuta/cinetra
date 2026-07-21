defmodule Api.Scheduling.AgendaNotifierTest do
  @moduledoc """
  O publicador (RN-56). O canal é o único consumidor hoje, e o teste dele já prova a ponta a
  ponta — este aqui fixa o **contrato interno** que a Entrega 4 vai reusar: dois broadcasts
  por escrita, mensagem idêntica nos dois, e o id em vez do registro.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling
  alias Api.Scheduling.AgendaNotifier

  defp email, do: "notif-#{System.unique_integer([:positive])}@example.com"

  defp sign_in(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  defp fixture do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)

    tipo =
      Directory.create_appointment_type!(
        %{
          nome: "Sessão #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Activity"
        },
        tenant: clinic.id,
        actor: owner
      )

    paciente = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)
    {:ok, membership} = Accounts.get_active_membership(owner.id, clinic.id, authorize?: false)

    %{
      owner: owner,
      clinic: clinic,
      prof: prof,
      tipo: tipo,
      paciente: paciente,
      scope: Api.Scope.with_membership(owner, membership)
    }
  end

  test "uma escrita publica no tópico do dia E no do mês" do
    ctx = fixture()
    dia = ~D[2026-07-20]

    :ok = AgendaNotifier.subscribe(AgendaNotifier.day_topic(ctx.clinic.id, dia))
    :ok = AgendaNotifier.subscribe(AgendaNotifier.month_topic(ctx.clinic.id, dia))

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: "2026-07-20T11:00:00Z",
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: ctx.scope
      )

    # Duas mensagens, uma por tópico, e idênticas — o que muda é o que o canal faz com cada
    # uma, não o que o publicador diz.
    assert_receive {:agenda_event, primeira}
    assert_receive {:agenda_event, segunda}
    assert primeira == segunda

    assert primeira.event == "appointment_scheduled"
    assert primeira.appointment_id == appt.id
    assert primeira.clinic_id == ctx.clinic.id
    assert primeira.date == dia
    assert primeira.actor == %{id: ctx.owner.id, nome: ctx.owner.nome}

    # O registro NÃO viaja: quem o resolve é o canal, com o escopo de cada assinante (A7).
    refute Map.has_key?(primeira, :appointment)
  end

  test "não publica quando a escrita falha" do
    ctx = fixture()
    dia = ~D[2026-07-20]

    :ok = AgendaNotifier.subscribe(AgendaNotifier.day_topic(ctx.clinic.id, dia))

    # 05:00 local: fora do expediente.
    {:error, _} =
      Scheduling.schedule_appointment(
        %{
          starts_at: "2026-07-20T08:00:00Z",
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: ctx.scope
      )

    refute_receive {:agenda_event, _}, 200
  end

  test "o tópico do mês usa o mês local, com dois dígitos" do
    assert AgendaNotifier.month_topic("c1", ~D[2026-07-20]) == "agenda_events:c1:month:2026-07"
    assert AgendaNotifier.day_topic("c1", ~D[2026-07-20]) == "agenda_events:c1:2026-07-20"
  end

  test "remarcar ENTRE dias publica no dia de origem E no de destino (Entrega 4)" do
    ctx = fixture()
    origem = ~D[2026-07-20]
    destino = ~D[2026-07-21]

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: "2026-07-20T12:00:00Z",
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: ctx.scope
      )

    :ok = AgendaNotifier.subscribe(AgendaNotifier.day_topic(ctx.clinic.id, origem))
    :ok = AgendaNotifier.subscribe(AgendaNotifier.day_topic(ctx.clinic.id, destino))

    {:ok, _} =
      Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
        starts_at: "2026-07-21T12:00:00Z"
      })

    # O de origem some (o cliente remove o bloco fantasma), o de destino recebe — os dois
    # eventos saem, cada um com a sua data. Esquecer o de origem é o risco que o doc 25 §9 nomeia.
    assert_receive {:agenda_event, %{event: "appointment_rescheduled", date: ^origem}}
    assert_receive {:agenda_event, %{event: "appointment_rescheduled", date: ^destino}}
  end

  test "cancelar publica appointment_canceled; concluir/faltar publicam status_changed" do
    ctx = fixture()
    dia = ~D[2026-07-20]

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: "2026-07-20T12:00:00Z",
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: ctx.scope
      )

    :ok = AgendaNotifier.subscribe(AgendaNotifier.day_topic(ctx.clinic.id, dia))

    {:ok, _} = Scheduling.transition_appointment(ctx.scope, appt.id, :cancel)
    assert_receive {:agenda_event, %{event: "appointment_canceled"}}
  end
end
