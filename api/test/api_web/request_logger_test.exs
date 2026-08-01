defmodule ApiWeb.RequestLoggerTest do
  @moduledoc """
  O evento único por requisição (doc 62 §7.1) e, principalmente, a **barreira de path**.

  `rota/1` é o que impede o `patient_id` de sair do processo. Um path como
  `/api/json/patients/019f7c5b-...` levaria para a agregação de log o único identificador que o
  doc 05 §1.3 proíbe exportar — ele liga o registro a um titular de dado de saúde. A barreira
  também é o que mantém a cardinalidade baixa: agrupar por `/api/json/patients/:id` só funciona
  se todo id virar o mesmo símbolo.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ApiWeb.RequestLogger

  describe "rota/1 — barreira de identificador" do
    test "UUID vira :id" do
      assert RequestLogger.rota("/api/json/patients/019f7c5b-1bee-7a32-9fad-c3d6f0a83177") ==
               "/api/json/patients/:id"
    end

    test "UUID sem hífen também" do
      assert RequestLogger.rota("/api/json/patients/019f7c5b1bee7a329fadc3d6f0a83177") ==
               "/api/json/patients/:id"
    end

    test "id numérico também" do
      assert RequestLogger.rota("/api/relatorios/2026/7") == "/api/relatorios/:id/:id"
    end

    test "vários identificadores no mesmo path" do
      rota =
        RequestLogger.rota(
          "/api/json/clinics/019f7c5b-1bee-7a32-9fad-c3d6f0a83177/patients/019fa690-a227-7673-a324-80279a9d52d4"
        )

      assert rota == "/api/json/clinics/:id/patients/:id"
      refute rota =~ "019f"
    end

    test "nenhum UUID sobrevive, qualquer que seja a posição" do
      uuids = [
        "019f7c5b-1bee-7a32-9fad-c3d6f0a83177",
        "550e8400-e29b-41d4-a716-446655440000",
        "00000000-0000-0000-0000-000000000000"
      ]

      for uuid <- uuids, path <- ["/a/#{uuid}", "/#{uuid}/b", "/a/#{uuid}/b/c"] do
        refute RequestLogger.rota(path) =~ uuid,
               "vazou #{uuid} em #{path} → #{RequestLogger.rota(path)}"
      end
    end

    test "segmento que NÃO é identificador passa intacto" do
      # A barreira não pode comer a rota: sem isto, o log perderia a informação que justifica
      # existir.
      assert RequestLogger.rota("/api/auth/me") == "/api/auth/me"
      assert RequestLogger.rota("/api/json/appointments") == "/api/json/appointments"
      assert RequestLogger.rota("/") == "/"
    end

    # Regressão (auditoria doc 96, S-2). A barreira reconhecia UUID e número — e o token de
    # `/api/reply/:token` é um `Phoenix.Token` base64, que não casa com nenhum dos dois e saía
    # INTEIRO na linha de log. Ele vale 30 dias (`Api.Messaging.ReplyToken`) e o Loki retém 30
    # dias: quem lê o Grafana podia replayar `POST /api/reply/<token>` e responder pelo paciente.
    # Credencial em log é exatamente a classe que este módulo existe para impedir.
    test "token opaco de rota pública não vaza no log" do
      token =
        "SFMyNTY.g2gDdAAAAAFkAAptZXNzYWdlX2lkbQAAACQwMTk4LWZha2UtdG9rZW4tcGFyYS10ZXN0ZQ.abc123"

      rota = RequestLogger.rota("/api/reply/#{token}")

      assert rota == "/api/reply/:token"
      refute rota =~ token
      refute rota =~ "SFMy"
    end

    test "o corte de segmento opaco não come nome de rota longo" do
      # `sign-out-everywhere` (19) é o segmento literal mais longo do router. O piso precisa
      # ficar acima dele, ou a barreira apagaria a rota que o log existe para agrupar.
      assert RequestLogger.rota("/api/auth/sign-out-everywhere") ==
               "/api/auth/sign-out-everywhere"

      assert RequestLogger.rota("/api/clinic-exceptions") == "/api/clinic-exceptions"
    end
  end

  describe "handle/4 — o evento" do
    # O `test.exs` fixa o Logger em `:warning`, e o `:level` do `capture_log` só filtra o que já
    # passou — não levanta o nível. Sem baixar aqui, o evento de rotina (200) seria descartado
    # antes da captura e o teste mediria o vazio, passando por engano nos casos negativos.
    setup do
      nivel = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: nivel) end)
    end

    # O falso precisa ter `req_headers` e `remote_ip` porque a linha carrega `client_ip` desde o
    # doc 96 (O-1), e `ApiWeb.ClientIp.get/1` lê os dois. Antes o mapa era mínimo, e o handler
    # estourava no `get_req_header/2` — o `rescue` do `RequestLogger` segurava (era para isso que
    # ele existia), mas a linha se perdia inteira.
    # Um `%Plug.Conn{}` de verdade, e não um mapa solto: `ApiWeb.ClientIp.get/1` casa contra a
    # struct (o `client_ip` entrou na linha no doc 96, O-1), e o mapa mínimo que estava aqui
    # estourava no `get_req_header/2`. O `rescue` do `RequestLogger` segurava o estouro — era
    # exatamente para isso que ele existia —, mas a linha se perdia inteira. O falso passa a ter a
    # mesma forma do que o `[:phoenix, :endpoint, :stop]` entrega em produção.
    defp evento(conn_extra, duracao_native \\ 1_000_000) do
      conn =
        Map.merge(
          %Plug.Conn{
            method: "GET",
            request_path: "/api/x",
            status: 200,
            req_headers: [],
            remote_ip: {127, 0, 0, 1}
          },
          conn_extra
        )

      capture_log(fn ->
        RequestLogger.handle(
          [:phoenix, :endpoint, :stop],
          %{duration: duracao_native},
          %{conn: conn},
          nil
        )
      end)
    end

    test "health check com sucesso NÃO gera linha" do
      # 34.560 requisições/dia de puro ruído (doc 62 §2.1). Filtrar aqui, e não na consulta, é o
      # que impede o ruído de consumir rede, disco e retenção.
      assert evento(%{request_path: "/api/health"}) == ""
      assert evento(%{request_path: "/api/ready"}) == ""
    end

    test "barra final não fura o filtro" do
      # Medido ao vivo: `/api/health/` escapou do match exato e foi para o log. Proxy, monitor e
      # copiar-colar de URL acrescentam a barra sem avisar — e o ruído volta inteiro.
      assert evento(%{request_path: "/api/health/"}) == ""
      assert evento(%{request_path: "/api/ready/"}) == ""
    end

    test "a raiz continua sendo registrada" do
      # A normalização não pode transformar "/" em "" e casar com coisa nenhuma.
      assert evento(%{request_path: "/"}) =~ "requisição"
    end

    test "health check que FALHA gera linha" do
      # O 2xx é ruído; a falha é o sintoma de que a instância saiu da rotação.
      assert evento(%{request_path: "/api/ready", status: 503}) =~ "requisição"
    end

    test "só 5xx é error; erro de cliente é rotina" do
      # O nível codifica acionabilidade. 401 de sessão expirada e 422 de formulário não são
      # incidente — e marcá-los como warning treina a equipe a ignorar warning.
      assert evento(%{status: 500}) =~ "[error]"
      assert evento(%{status: 503}) =~ "[error]"
      assert evento(%{status: 404}) =~ "[info]"
      assert evento(%{status: 401}) =~ "[info]"
      assert evento(%{status: 422}) =~ "[info]"
      assert evento(%{status: 200}) =~ "[info]"
    end

    test "o path do evento também passa pela barreira" do
      log = evento(%{request_path: "/api/json/patients/019f7c5b-1bee-7a32-9fad-c3d6f0a83177"})

      refute log =~ "019f7c5b"
    end
  end
end
