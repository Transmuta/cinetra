defmodule ApiWeb.PatientReplyControllerTest do
  @moduledoc """
  A resposta do paciente pelo link assinado (doc 52 §5).

  É a única rota do projeto que fala com quem não tem sessão e não é autenticação, então o que
  precisa estar provado aqui é **o que o token não dá**: ele responde por uma mensagem e não abre
  acesso a mais nada.
  """

  use ApiWeb.ConnCase, async: true

  alias Api.Messaging.ReplyToken

  setup do
    ctx = clinica()
    paciente = paciente_com(ctx, comunicacao: true, email: "ana@example.com", nome: "Ana Beatriz")
    appt = agendamento!(ctx, paciente: paciente)
    # Disparada à mão: criar o bloco não fala mais com o paciente (doc 98).
    message = confirmacao!(ctx, appt, paciente)

    %{ctx: ctx, message: message, token: ReplyToken.sign(message.id)}
  end

  describe "GET /api/reply/:token" do
    test "mostra a sessão, e só o necessário", %{conn: conn, token: token, ctx: ctx} do
      body = conn |> get(~p"/api/reply/#{token}") |> json_response(200)

      assert body["clinica"] == ctx.clinic.nome
      # Primeiro nome, não o nome completo: quem abre é quem tem o link, e link se encaminha.
      assert body["paciente"] == "Ana"
      assert body["data"]
      assert body["hora"]
      # Nada de ficha, telefone, e-mail ou outros participantes. `telefone` cru é o do PACIENTE e
      # continua fora; o da clínica viaja sob `clinica_telefone`, que é outro dado — ver o
      # describe abaixo.
      refute Map.has_key?(body, "email")
      refute Map.has_key?(body, "telefone")
      refute Map.has_key?(body, "participantes")
    end

    test "token inválido responde 404, sem dizer se a mensagem existe", %{conn: conn} do
      conn = get(conn, ~p"/api/reply/nao-e-um-token")

      assert json_response(conn, 404)["error"] == "link_invalido"
    end

    test "token vencido responde 410 com motivo acionável", %{conn: conn, message: message} do
      # 410 e não 404: a página precisa dizer "este link expirou", que é acionável.
      velho =
        ReplyToken.sign(message.id, signed_at: System.system_time(:second) - 60 * 60 * 24 * 40)

      conn = get(conn, ~p"/api/reply/#{velho}")

      assert json_response(conn, 410)["error"] == "link_expirado"
    end
  end

  describe "GET /api/reply/:token — o que a tela precisa para falar com um paciente" do
    # A régua desta seção, e ela é de exposição, não de gosto: **a página não conta nada que a
    # mensagem já não tenha contado**. O link se encaminha, então o que ele revela tem de ser o
    # mesmo que o e-mail/WhatsApp encaminhado revelaria — nem mais. O telefone da clínica está no
    # corpo de todo template ("Ligue para {{5}}"); profissional e endereço não estão, e por isso
    # continuam fora.
    test "traz o telefone da clínica — a mesma linha que a mensagem já anunciou", %{conn: conn} do
      ctx = clinica(whatsapp: true)
      paciente = paciente_com(ctx, comunicacao: true, email: "bia@example.com", nome: "Bia Reis")
      appt = agendamento!(ctx, paciente: paciente)
      message = confirmacao!(ctx, appt, paciente)

      body = conn |> get(~p"/api/reply/#{ReplyToken.sign(message.id)}") |> json_response(200)

      assert body["clinica_telefone"] == "(11) 3456-7890"
      # O do paciente continua fora: é dado da ficha, e o token não dá ficha.
      refute Map.has_key?(body, "telefone")
    end

    test "traz o instante e o fuso da sessão, e não só a data já formatada", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      # `data`/`hora` são strings congeladas no envio (histórico da timeline). Elas não dizem o dia
      # da semana nem servem para montar um `.ics`, e a tela precisa dos dois.
      body = conn |> get(~p"/api/reply/#{token}") |> json_response(200)

      presenca = presenca_da(ctx, message)

      assert {:ok, inicio, 0} = DateTime.from_iso8601(body["inicio"])
      assert DateTime.compare(inicio, presenca.session_starts_at) == :eq
      assert body["timezone"] == ctx.clinic.timezone
    end

    test "traz o fim da sessão — sem ele não há evento de agenda para adicionar", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      # A duração é a do bloco (`ends_at - starts_at`), aplicada ao começo DESTA presença: numa
      # série, cada sessão tem o seu `session_starts_at`, mas todas duram o que o bloco dura.
      body = conn |> get(~p"/api/reply/#{token}") |> json_response(200)

      appt =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Scheduling.get_appointment!(message.appointment_id,
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)

      minutos = DateTime.diff(appt.ends_at, appt.starts_at, :minute)
      presenca = presenca_da(ctx, message)

      assert {:ok, fim, 0} = DateTime.from_iso8601(body["fim"])
      assert DateTime.diff(fim, presenca.session_starts_at, :minute) == minutos
    end

    test "sessão viva responde ativa: true", %{conn: conn, token: token} do
      assert conn |> get(~p"/api/reply/#{token}") |> json_response(200) |> Map.fetch!("ativa")
    end

    test "sessão cancelada responde ativa: false — o link vale 30 dias, a sessão não", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      # O buraco que isto fecha: o resumo saía do `vars` congelado, então uma sessão cancelada
      # depois do envio continuava anunciada como "está marcada" — e a tela oferecia confirmar
      # presença em algo que não existe mais.
      appt =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Scheduling.get_appointment!(message.appointment_id,
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)

      {:ok, _} =
        Api.Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      body = conn |> get(~p"/api/reply/#{token}") |> json_response(200)

      refute body["ativa"]
    end

    test "sessão remarcada responde o horário NOVO, não o congelado na mensagem", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      appt =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Scheduling.get_appointment!(message.appointment_id,
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)

      novo = Api.Generators.proximo_dia_util_as(ctx, 16)

      {:ok, _} =
        Api.Scheduling.transition_appointment(
          ctx.scope,
          appt.id,
          :reschedule,
          %{starts_at: novo},
          appt.version
        )

      body = conn |> get(~p"/api/reply/#{token}") |> json_response(200)

      assert {:ok, inicio, 0} = DateTime.from_iso8601(body["inicio"])
      assert DateTime.compare(inicio, novo) == :eq
      # E o congelado continua congelado: ele é o histórico do que a mensagem disse.
      assert body["hora"] == message.vars["hora"]
    end
  end

  describe "POST /api/reply/:token" do
    test "confirmar grava a resposta", %{conn: conn, token: token, ctx: ctx, message: message} do
      body =
        conn
        |> post(~p"/api/reply/#{token}", %{"resposta" => "confirmou"})
        |> json_response(200)

      assert body["resposta"] == "confirmou"
      assert recarregar_mensagem(ctx, message).resposta == :confirmou
    end

    test "pedir remarcação NÃO remarca — só registra", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})

      assert recarregar_mensagem(ctx, message).resposta == :quer_remarcar

      # O bloco continua onde estava: escolher horário pela pessoa exigiria conhecer regras
      # (expediente, conflito, encaixe) que um clique de fora não conhece.
      appt =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Scheduling.get_appointment!(message.appointment_id,
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)

      assert appt.status == :agendado
    end

    test "pedir remarcação cai na caixa do operacional (doc 65 §5)", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # É a lacuna que esta fatia fechou: até aqui, um paciente que pedia remarcação só era
      # descoberto por quem abrisse o drawer daquela sessão. E é a única notificação do sistema
      # cujo autor não tem login — por isso o teste tem de atravessar a rota pública, não chamar
      # o fan-out direto (a lição do doc 49: regra que atravessa a fronteira precisa de teste que
      # atravesse a fronteira).
      recepcao = escopo_de_membro!(ctx, :recepcao)

      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})

      assert [notificacao] = caixa(ctx, recepcao)
      assert notificacao.kind == :patient_wants_reschedule
      assert notificacao.title == "Paciente pediu remarcação"
      assert notificacao.body =~ "Ana Beatriz"
    end

    test "responder DUAS vezes não duplica a caixa (a rota é pública)", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # Medido no bate-volta: 5 POSTs do mesmo token criavam 10 notificações (2 destinatários ×
      # 5). A resposta em si já era idempotente — o instante da primeira é preservado —, e o
      # fan-out entrou por cima dela sem essa propriedade. Numa rota **pública e sem rate limit**,
      # isso é um amplificador: quem tem o link enche a caixa da clínica.
      recepcao = escopo_de_membro!(ctx, :recepcao)

      for _ <- 1..3 do
        build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})
      end

      assert [_uma] = caixa(ctx, recepcao)
      _ = conn
    end

    test "mudar de ideia avisa de novo — não é o replay que se está barrando", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # A guarda é sobre **transição**, não sobre "já avisou uma vez": quem confirmou e depois
      # pediu remarcação mudou de ideia, e a recepção precisa saber das duas vezes.
      recepcao = escopo_de_membro!(ctx, :recepcao)

      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})
      build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "confirmou"})
      build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})

      assert length(caixa(ctx, recepcao)) == 2
    end

    test "confirmar NÃO cai na caixa — seria ruído por sessão", %{
      conn: conn,
      token: token,
      ctx: ctx
    } do
      # Numa clínica com ~2.200 presenças/mês, uma linha por confirmação afogaria a caixa da
      # recepção. A confirmação já aparece no status do bloco e na timeline (doc 31 §4).
      recepcao = escopo_de_membro!(ctx, :recepcao)

      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "confirmou"})

      assert caixa(ctx, recepcao) == []
    end

    test "responder duas vezes mantém o primeiro instante e vale a última resposta", %{
      conn: conn,
      token: token,
      ctx: ctx,
      message: message
    } do
      post(conn, ~p"/api/reply/#{token}", %{"resposta" => "confirmou"})
      primeira = recarregar_mensagem(ctx, message)

      build_conn() |> post(~p"/api/reply/#{token}", %{"resposta" => "quer_remarcar"})
      segunda = recarregar_mensagem(ctx, message)

      assert segunda.respondido_em == primeira.respondido_em
      # Mudou de ideia; é a segunda que a recepção precisa ver.
      assert segunda.resposta == :quer_remarcar
    end

    test "resposta fora das duas opções é recusada", %{conn: conn, token: token} do
      conn = post(conn, ~p"/api/reply/#{token}", %{"resposta" => "talvez"})

      assert json_response(conn, 422)["error"] == "resposta_invalida"
    end
  end

  # ---- helpers ----

  defp caixa(_ctx, scope), do: Api.Notifications.list_inbox(scope).results

  # A presença a que a mensagem se refere, lida sob a GUC — `attendances` tem RLS por
  # `cinetra.clinic_id`, e sem ela a leitura volta VAZIA em vez de levantar.
  defp presenca_da(ctx, message) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Scheduling.get_attendance!(message.attendance_id,
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end
end
