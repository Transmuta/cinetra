defmodule ApiWeb.AgendaChannelTest do
  @moduledoc """
  O canal da agenda (Entrega 3, doc 25 §9 / contrato 09 §7).

  O que este arquivo protege, em ordem de gravidade:

    * **o `clinic_id` do tópico é validado no `join`** — o WebSocket não passa pelo plug de
      sessão nem pela RLS do Postgres, então pedir o tópico de outra clínica seria vazamento
      por fora de tudo que protege o REST;
    * **A7 no push** — o papel `profissional` não pode receber o bloco do colega por evento,
      já que a leitura HTTP dele é recortada por `OwnAgendaOnly`. O tópico é da clínica
      inteira, então o recorte tem de acontecer **por assinante**, não por tópico;
    * o vínculo revogado depois do token emitido não entra (o token vive 15 min);
    * o sinal do mês é leve — nunca carrega bloco.
  """
  use ApiWeb.ChannelCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling

  @dia "2026-07-20"

  defp email, do: "chan-#{System.unique_integer([:positive])}@example.com"

  defp sign_in(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  defp member(owner, clinic, papel, professional_id \\ nil) do
    addr = email()
    attrs = %{papel: papel, clinic_id: clinic.id, professional_id: professional_id}
    {:ok, pending} = Accounts.invite_member_by_email(addr, attrs, actor: owner)
    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, membership} = Accounts.accept_invite(pending, actor: user)
    {sign_in(addr), membership}
  end

  defp fixture do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)
    outra = Directory.create_professional!("Dr. Y", %{}, tenant: clinic.id, actor: owner)

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

    paciente = Records.create_patient!("Paciente Fulano", %{}, tenant: clinic.id, actor: owner)

    %{owner: owner, clinic: clinic, prof: prof, outra: outra, tipo: tipo, paciente: paciente}
  end

  defp socket_for(user, clinic) do
    Phoenix.ChannelTest.socket(ApiWeb.UserSocket, "user_socket:#{user.id}", %{
      user_id: user.id,
      clinic_id: clinic.id
    })
  end

  defp dia_topic(clinic, dia \\ @dia), do: "clinic:#{clinic.id}:agenda:#{dia}"
  defp mes_topic(clinic, mes \\ "2026-07"), do: "clinic:#{clinic.id}:agenda:month:#{mes}"

  # 08:00 em São Paulo na segunda de referência.
  defp agenda(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        starts_at: "2026-07-20T11:00:00Z",
        professional_id: ctx.prof.id,
        appointment_type_id: ctx.tipo.id,
        patient_ids: [ctx.paciente.id]
      },
      overrides
    )
  end

  describe "join" do
    test "membro da clínica entra no tópico do próprio dia" do
      ctx = fixture()

      assert {:ok, _reply, _socket} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(ctx.clinic))
    end

    test "tópico de OUTRA clínica é recusado — o vazamento que não passa por RLS" do
      ctx = fixture()
      intruso = fixture()

      assert {:error, %{reason: "unauthorized"}} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(intruso.clinic))
    end

    test "tópico malformado é recusado" do
      ctx = fixture()
      sock = socket_for(ctx.owner, ctx.clinic)

      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(sock, ApiWeb.AgendaChannel, "clinic:#{ctx.clinic.id}:agenda:xx")

      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(sock, ApiWeb.AgendaChannel, "clinic:#{ctx.clinic.id}:lixo")
    end

    test "vínculo revogado depois do token emitido não entra" do
      ctx = fixture()
      {user, membership} = member(ctx.owner, ctx.clinic, :recepcao)

      # O token continua válido (15 min) — quem barra é a releitura do vínculo no join.
      :ok = Accounts.revoke_access(membership, actor: ctx.owner)

      assert {:error, %{reason: "unauthorized"}} =
               user
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(ctx.clinic))
    end

    test "tópico de mês entra" do
      ctx = fixture()

      assert {:ok, _reply, _socket} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.AgendaChannel, mes_topic(ctx.clinic))
    end
  end

  describe "evento do dia" do
    test "criar agendamento empurra o bloco cheio, com o paciente junto" do
      ctx = fixture()

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(ctx.clinic))

      scope = scope_for(ctx.owner, ctx.clinic)
      {:ok, appt} = Scheduling.schedule_appointment(agenda(ctx), scope: scope)

      assert_push "appointment_scheduled", payload
      assert payload.appointment.id == appt.id
      assert payload.appointment.professional_id == ctx.prof.id
      assert payload.appointment.patient_ids == [ctx.paciente.id]
      assert payload.appointment.version == 1

      # O sidecar existe porque o cliente pode não ter esse paciente na janela carregada —
      # sem ele o bloco novo apareceria com "Paciente" genérico no lugar do nome.
      assert [%{id: pid, nome: "Paciente Fulano"}] = payload.patients
      assert pid == ctx.paciente.id

      assert payload.actor.id == ctx.owner.id
    end

    test "A7: o profissional NÃO recebe o bloco do colega" do
      ctx = fixture()
      {prof_user, _} = member(ctx.owner, ctx.clinic, :profissional, ctx.outra.id)

      {:ok, _, _socket} =
        prof_user
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(ctx.clinic))

      # O bloco é da `ctx.prof`; quem escuta está vinculado à `ctx.outra`.
      scope = scope_for(ctx.owner, ctx.clinic)
      {:ok, _appt} = Scheduling.schedule_appointment(agenda(ctx), scope: scope)

      refute_push "appointment_scheduled", _payload, 300
    end

    test "A7: o profissional recebe o próprio bloco" do
      ctx = fixture()
      {prof_user, _} = member(ctx.owner, ctx.clinic, :profissional, ctx.prof.id)

      {:ok, _, _socket} =
        prof_user
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(ctx.clinic))

      scope = scope_for(ctx.owner, ctx.clinic)
      {:ok, appt} = Scheduling.schedule_appointment(agenda(ctx), scope: scope)

      assert_push "appointment_scheduled", payload
      assert payload.appointment.id == appt.id
    end

    test "o dia do tópico é o dia LOCAL da clínica, não o UTC" do
      ctx = fixture()
      scope = scope_for(ctx.owner, ctx.clinic)

      # Segunda até tarde, para o bloco das 21h ser legal (o encaixe isenta a constraint de
      # sobreposição, não o expediente).
      {:ok, _} = Scheduling.update_clinic_hours(scope, %{1 => [["08:00", "23:00"]]})

      # 21:00 em São Paulo (UTC-3) = 00:00Z do dia **seguinte**. Quem escuta o dia 20 local
      # tem de receber: publicar no dia UTC faria o bloco sumir da tela de quem está no dia
      # certo, e só depois das 21h — o defeito que aparece à noite e some de manhã.
      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(ctx.clinic, "2026-07-20"))

      {:ok, _appt} =
        Scheduling.schedule_appointment(
          agenda(ctx, %{starts_at: "2026-07-21T00:00:00Z"}),
          scope: scope
        )

      assert_push "appointment_scheduled", _payload
    end
  end

  describe "evento do mês" do
    test "o mês recebe sinal leve — dia e tipo de mudança, nunca o bloco" do
      ctx = fixture()

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.AgendaChannel, mes_topic(ctx.clinic))

      scope = scope_for(ctx.owner, ctx.clinic)
      {:ok, _appt} = Scheduling.schedule_appointment(agenda(ctx), scope: scope)

      assert_push "agenda_changed", payload
      assert payload == %{day: "2026-07-20", change: "count"}
    end

    test "A7 vale também para o sinal do mês" do
      ctx = fixture()
      {prof_user, _} = member(ctx.owner, ctx.clinic, :profissional, ctx.outra.id)

      {:ok, _, _socket} =
        prof_user
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.AgendaChannel, mes_topic(ctx.clinic))

      scope = scope_for(ctx.owner, ctx.clinic)
      {:ok, _appt} = Scheduling.schedule_appointment(agenda(ctx), scope: scope)

      refute_push "agenda_changed", _payload, 300
    end
  end

  describe "turma" do
    test "entrar numa turma existente empurra participant_added com a lista nova" do
      ctx = fixture()

      grupo =
        Directory.create_appointment_type!(
          %{
            nome: "Pilates #{System.unique_integer([:positive])}",
            duracao_minutos: 50,
            cor: "#0FB5A6",
            icon: "Activity",
            grupo: true,
            capacidade: 4
          },
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      outro = Records.create_patient!("Segundo", %{}, tenant: ctx.clinic.id, actor: ctx.owner)
      scope = scope_for(ctx.owner, ctx.clinic)

      {:ok, turma} =
        Scheduling.schedule_appointment(agenda(ctx, %{appointment_type_id: grupo.id}),
          scope: scope
        )

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(ctx.clinic))

      {:ok, _} =
        Scheduling.schedule_appointment(
          agenda(ctx, %{appointment_type_id: grupo.id, patient_ids: [outro.id]}),
          scope: scope
        )

      assert_push "participant_added", payload
      assert payload.appointment.id == turma.id
      assert Enum.sort(payload.appointment.patient_ids) == Enum.sort([ctx.paciente.id, outro.id])
      assert length(payload.patients) == 2
    end
  end

  defp scope_for(user, clinic) do
    {:ok, membership} = Accounts.get_active_membership(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end
end
