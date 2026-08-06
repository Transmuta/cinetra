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

  defmodule Coletor do
    @moduledoc """
    Handler do `:logger` que reenvia o evento cru para o processo de teste.

    Existe porque o metadata que interessa (`payload`, `response`) não aparece no texto do
    `capture_log`: o formatter de teste tem a própria lista de chaves, e o que não está nela é
    descartado antes de virar texto. Um teste montado sobre o texto mediria a lista do formatter,
    não o que o `RequestLogger` produziu.
    """
    def log(evento, %{config: %{pai: pai}}), do: send(pai, {:linha, evento})
  end

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

    # As linhas do evento SOB TESTE, e só elas — para provar que o filtro engoliu o evento.
    #
    # Por que não `evento(...) == ""`, que é o óbvio e era o que estava aqui: `capture_log`
    # captura o Logger do **nó**, não o do processo do teste. Como este módulo é `async: true`,
    # qualquer teste concorrente que logue dentro da janela de captura entra no buffer, e a
    # igualdade contra `""` quebra sem ter nada a ver com o filtro.
    #
    # Não é hipótese: quebrou no CI em 2026-08-06 (PR #16), com uma linha de
    # `route=/api/reply/:token` — do teste do controller de resposta do paciente — dentro da
    # asserção do health check. Reproduzido depois de forma determinística com um módulo vizinho
    # que loga em volume.
    #
    # Filtrar pelo último segmento do path (`health`, `ready`) mantém o que o teste promete — se o
    # filtro furar, a linha do evento carrega o path e aparece aqui — e para de depender de quem
    # mais está logando no mesmo instante. `async: false` também resolveria o vizinho, mas não
    # resolveria log de processo de fundo, e custaria o paralelismo do arquivo.
    defp silencio(conn_extra) do
      marcador =
        conn_extra.request_path |> String.trim("/") |> String.split("/") |> List.last()

      conn_extra
      |> evento()
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, marcador))
      |> Enum.join("\n")
    end

    # O metadata **real** do evento, e não o texto formatado.
    #
    # `payload` e `response` não estão na lista de metadata do formatter de teste, então eles
    # simplesmente não apareceriam no `capture_log` — e o teste passaria por vazio, medindo a
    # lista do formatter em vez do que o `RequestLogger` produziu. Este coletor é um handler do
    # `:logger` de verdade: ele recebe o evento com o metadata intacto, que é o que segue para o
    # formatter em produção.
    defp metadados(conn_extra) do
      :logger.add_handler(:coletor_de_teste, Coletor, %{config: %{pai: self()}})
      on_exit(fn -> :logger.remove_handler(:coletor_de_teste) end)

      conn =
        Map.merge(
          %Plug.Conn{
            method: "POST",
            request_path: "/api/coletor",
            status: 200,
            req_headers: [],
            remote_ip: {127, 0, 0, 1}
          },
          conn_extra
        )

      RequestLogger.handle(
        [:phoenix, :endpoint, :stop],
        %{duration: 1_000_000},
        %{conn: conn},
        nil
      )

      receber_linha()
    end

    defp receber_linha do
      receive do
        {:linha, %{meta: meta, msg: {:string, "requisição"}}} ->
          Enum.to_list(meta)

        {:linha, _outro} ->
          receber_linha()
      after
        500 -> flunk("o RequestLogger não emitiu a linha de requisição")
      end
    end

    test "200 não carrega payload nem resposta" do
      # O escopo do ADR-025 é 4xx/5xx. Se o caminho feliz carregasse payload, seria dado de
      # paciente de TODA operação bem-sucedida indo para o Loki — exatamente o que a decisão
      # evitou.
      meta = metadados(%{status: 200, body_params: %{"cpf" => "12345678901"}})

      refute Keyword.has_key?(meta, :payload)
      refute Keyword.has_key?(meta, :response)
    end

    test "422 carrega o payload, redigido" do
      meta =
        metadados(%{
          status: 422,
          body_params: %{"cpf" => "12345678901", "clinic_id" => "019f"}
        })

      assert meta[:payload] == %{"cpf" => "***", "clinic_id" => "019f"}
    end

    test "422 carrega a resposta capturada pelo plug, redigida" do
      meta =
        metadados(%{
          status: 422,
          private: %{resposta_capturada: ~s({"errors":[{"field":"cpf"}],"nome":"Maria"})}
        })

      assert meta[:response] == %{"errors" => [%{"field" => "cpf"}], "nome" => "***"}
    end

    test "500 também carrega os dois" do
      meta =
        metadados(%{
          status: 500,
          body_params: %{"tel" => "11987654321"},
          private: %{resposta_capturada: ~s({"error":"boom"})}
        })

      assert meta[:payload] == %{"tel" => "***"}
      assert meta[:response] == %{"error" => "boom"}
    end

    test "a query string de uma requisição recusada entra, sem a credencial" do
      # `GET /api/auth/magic-link/callback?token=…` é o caminho onde a query É o payload — e onde
      # ela carrega a credencial que assina a sessão. Logar a query sem redigir `token` seria
      # publicar sessão no Grafana.
      meta =
        metadados(%{
          status: 401,
          query_params: %{"token" => "SFMyNTY.longo", "clinic" => "019f"}
        })

      assert meta[:query] == %{"token" => "***", "clinic" => "019f"}
    end

    test "4xx sem corpo nenhum não inventa campo vazio" do
      meta = metadados(%{status: 404})

      refute Keyword.has_key?(meta, :payload)
      refute Keyword.has_key?(meta, :response)
      refute Keyword.has_key?(meta, :query)
    end

    test "health check com sucesso NÃO gera linha" do
      # 34.560 requisições/dia de puro ruído (doc 62 §2.1). Filtrar aqui, e não na consulta, é o
      # que impede o ruído de consumir rede, disco e retenção.
      assert silencio(%{request_path: "/api/health"}) == ""
      assert silencio(%{request_path: "/api/ready"}) == ""
    end

    test "barra final não fura o filtro" do
      # Medido ao vivo: `/api/health/` escapou do match exato e foi para o log. Proxy, monitor e
      # copiar-colar de URL acrescentam a barra sem avisar — e o ruído volta inteiro.
      assert silencio(%{request_path: "/api/health/"}) == ""
      assert silencio(%{request_path: "/api/ready/"}) == ""
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
