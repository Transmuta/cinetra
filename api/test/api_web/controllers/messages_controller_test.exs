defmodule ApiWeb.MessagesControllerTest do
  @moduledoc """
  A timeline e o disparo manual na fronteira (doc 52 §6).

  O teste que mais importa é o do **silêncio explicado**: a linha "nada enviado, e por quê" é o
  que separa esta tela de uma que parece funcionar. Sem ela a recepção supõe que a mensagem saiu.
  """
  use ApiWeb.ConnCase, async: true

  setup do
    ctx = clinica()

    # A recepção é quem opera a comunicação no balcão — é o papel certo para exercer a fronteira.
    sessao = as(sessao_de_membro!(ctx.owner, ctx.clinic, :recepcao))
    %{ctx: ctx, sessao: sessao}
  end

  describe "GET /api/appointments/:id/messages" do
    test "traz a mensagem automática do participante", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["paciente"] == paciente.nome
      assert linha["semEnvio"] == nil

      assert [%{"kind" => "confirmacao", "automatico" => true, "status" => "pendente"}] =
               linha["mensagens"]
    end

    test "explica o silêncio de quem não tem contato", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: true, email: nil, tel: nil)
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["mensagens"] == []
      assert linha["semEnvio"] == "sem_contato"
    end

    test "explica o silêncio de quem não autorizou", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: false, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["semEnvio"] == "sem_consentimento"
    end

    test "explica o silêncio de quem pediu para parar", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: true, email: "parou@example.com")
      Api.Messaging.opt_out(:email, "parou@example.com", "link")
      appt = agendamento!(ctx, paciente: paciente)

      %{"participantes" => [linha]} = get_json(sessao, appt)

      assert linha["semEnvio"] == "opt_out"
    end

    test "uma linha por participante da turma", %{ctx: ctx, sessao: sessao} do
      turma = clinica_turma(ctx)
      um = paciente_com(ctx, comunicacao: true, email: "um@example.com")
      dois = paciente_com(ctx, comunicacao: true, email: nil, tel: nil)
      quando = Api.Generators.amanha_as(ctx, 15)

      appt = agendamento!(ctx, paciente: um, tipo: turma, quando: quando)
      _ = agendamento!(ctx, paciente: dois, tipo: turma, quando: quando)

      %{"participantes" => linhas} = get_json(sessao, appt)

      assert length(linhas) == 2
      # Numa turma, "confirmação enviada" no bloco mentiria para quem não recebeu (§3).
      assert Enum.any?(linhas, &(&1["semEnvio"] == "sem_contato"))
      assert Enum.any?(linhas, &(&1["mensagens"] != []))
    end

    test "agendamento de outra clínica responde 404", %{sessao: sessao} do
      outra = clinica()
      appt = agendamento!(outra)

      conn = get(sessao, ~p"/api/appointments/#{appt.id}/messages")

      assert json_response(conn, 404)
    end

    test "sem sessão, 401" do
      conn = get(build_conn(), ~p"/api/appointments/#{Ash.UUID.generate()}/messages")

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/appointments/:id/messages" do
    test "reenvia e registra QUEM disparou", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com")
      appt = agendamento!(ctx, paciente: paciente)

      conn = post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{})

      assert %{"resultados" => [%{"enviado" => true}]} = json_response(conn, 201)

      %{"participantes" => [linha]} = get_json(sessao, appt)
      manual = Enum.find(linha["mensagens"], &(&1["automatico"] == false))
      assert manual
    end

    test "devolve o motivo quando não dá para enviar", %{ctx: ctx, sessao: sessao} do
      paciente = paciente_com(ctx, comunicacao: false)
      appt = agendamento!(ctx, paciente: paciente)

      conn = post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{})

      assert %{"resultados" => [%{"enviado" => false, "motivo" => "sem_consentimento"}]} =
               json_response(conn, 201)
    end

    test "com patient_id, não dispara para os outros da turma", %{ctx: ctx, sessao: sessao} do
      # Reenviar para quem falhou não pode mandar de novo para os outros três.
      turma = clinica_turma(ctx)
      um = paciente_com(ctx, comunicacao: true, email: "um@example.com")
      dois = paciente_com(ctx, comunicacao: true, email: "dois@example.com")
      quando = Api.Generators.amanha_as(ctx, 16)

      appt = agendamento!(ctx, paciente: um, tipo: turma, quando: quando)
      _ = agendamento!(ctx, paciente: dois, tipo: turma, quando: quando)

      conn =
        post(sessao, ~p"/api/appointments/#{appt.id}/messages", %{"patient_id" => um.id})

      assert %{"resultados" => [%{"patientId" => id}]} = json_response(conn, 201)
      assert id == um.id
    end
  end

  # ---- helpers ----

  defp get_json(sessao, appt) do
    sessao
    |> get(~p"/api/appointments/#{appt.id}/messages")
    |> json_response(200)
  end

  defp clinica_turma(ctx), do: Api.Generators.tipo!(ctx, grupo: true, capacidade: 4)
end
