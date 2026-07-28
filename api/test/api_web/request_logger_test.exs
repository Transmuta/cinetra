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

    defp evento(conn_extra, duracao_native \\ 1_000_000) do
      conn = Map.merge(%{method: "GET", request_path: "/api/x", status: 200}, conn_extra)

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
