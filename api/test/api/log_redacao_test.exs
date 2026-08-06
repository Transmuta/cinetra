defmodule Api.LogRedacaoTest do
  @moduledoc """
  A redação que torna aceitável logar payload e resposta (ADR-025).

  O log vive **fora do banco e fora da RLS**: 30 dias no Loki, lido por uma conta de Grafana
  compartilhada, sem trilha de quem leu o quê (doc 95, R-M17). Levar payload para lá só se
  sustenta com esta camada — e ela é uma **blocklist**, o que significa que erra ABERTO por
  construção: campo novo que não estiver na lista sai em claro.

  Por isso a lista é conferida contra os atributos reais dos recursos, e o teste do fim deste
  arquivo cobra isso: campo sensível novo em `Patient` ou `Professional` reprova aqui até alguém
  decidir conscientemente o que fazer com ele.
  """

  use ExUnit.Case, async: true

  alias Api.LogRedacao

  describe "redigir/1 — o mapa" do
    test "campo sensível vira ***" do
      redigido = LogRedacao.redigir(%{"cpf" => "12345678901", "nome" => "Maria Silva"})

      assert redigido == %{"cpf" => "***", "nome" => "***"}
    end

    test "campo de diagnóstico fica em claro — é o motivo de o log existir" do
      payload = %{
        "id" => "019f7c5b-1bee-7a32-9fad-c3d6f0a83177",
        "clinic_id" => "019f7c5b-1bee-7a32-9fad-000000000001",
        "status" => "confirmado",
        "starts_at" => "2026-08-05T14:00:00Z",
        "ativo" => true
      }

      assert LogRedacao.redigir(payload) == payload
    end

    test "alcança mapa aninhado" do
      redigido =
        LogRedacao.redigir(%{
          "patient" => %{"cpf" => "12345678901", "id" => "019f"},
          "meta" => %{"origem" => "web"}
        })

      assert redigido == %{
               "patient" => %{"cpf" => "***", "id" => "019f"},
               "meta" => %{"origem" => "web"}
             }
    end

    test "alcança lista de mapas" do
      redigido =
        LogRedacao.redigir(%{"pacientes" => [%{"tel" => "11987654321"}, %{"tel" => "x"}]})

      assert redigido == %{"pacientes" => [%{"tel" => "***"}, %{"tel" => "***"}]}
    end

    test "não depende de a chave ser string, atom ou de caixa" do
      # O `body_params` do Plug vem com chave string; um mapa montado no código vem com atom; e
      # um cliente pode mandar "CPF". Errar qualquer um dos três é vazar.
      assert LogRedacao.redigir(%{cpf: "1"}) == %{cpf: "***"}
      assert LogRedacao.redigir(%{"CPF" => "1"}) == %{"CPF" => "***"}
      assert LogRedacao.redigir(%{"Nome_Social" => "x"}) == %{"Nome_Social" => "***"}
    end

    test "redige valor de qualquer tipo, não só string" do
      # `tags` é lista, `nascimento` é data. Redigir só string deixaria os dois passarem.
      assert LogRedacao.redigir(%{"tags" => ["HIV+"], "nascimento" => "1985-03-12"}) ==
               %{"tags" => "***", "nascimento" => "***"}
    end

    test "texto longo em campo não sensível é truncado com marca" do
      longo = String.duplicate("a", 500)

      %{"motivo" => cortado} = LogRedacao.redigir(%{"motivo" => longo})

      assert String.length(cortado) < 300
      assert cortado =~ "[+"
    end

    test "payload grande demais vira marcador, não linha gigante" do
      grande = %{
        "itens" => Enum.map(1..500, &%{"i" => &1, "obs" => "texto de tamanho médio #{&1}"})
      }

      assert %{truncado: true, bytes: bytes} = LogRedacao.redigir(grande)
      assert bytes > 4096
    end

    test "nil e mapa vazio não viram lixo na linha" do
      assert LogRedacao.redigir(nil) == nil
      assert LogRedacao.redigir(%{}) == nil
    end

    test "o corpo não-fetchado do Plug não vira linha" do
      # GET sem corpo: `Plug.Parsers` deixa `%Plug.Conn.Unfetched{}`. Serializar isso poria
      # `{"aspect":"body_params"}` em toda linha de erro, dizendo nada.
      assert LogRedacao.redigir(%Plug.Conn.Unfetched{aspect: :body_params}) == nil
    end
  end

  describe "resposta/1 — o corpo da resposta" do
    test "JSON vira mapa redigido" do
      corpo = ~s({"errors":[{"field":"cpf","message":"inválido"}],"nome":"Maria"})

      assert LogRedacao.resposta(corpo) == %{
               "errors" => [%{"field" => "cpf", "message" => "inválido"}],
               "nome" => "***"
             }
    end

    test "o motivo da recusa sobrevive à redação" do
      # É o ponto todo do ADR-025: `field: "cpf"` diz QUAL campo foi recusado sem dizer o valor.
      # Se a redação comesse isto, logar a resposta não teria comprado nada.
      corpo = ~s({"errors":[{"field":"cpf","code":"formato_invalido"}]})

      assert %{"errors" => [%{"field" => "cpf", "code" => "formato_invalido"}]} =
               LogRedacao.resposta(corpo)
    end

    test "corpo que não é JSON vira texto truncado" do
      assert LogRedacao.resposta("Internal Server Error") == "Internal Server Error"
      assert LogRedacao.resposta(String.duplicate("x", 5000)) =~ "[+"
    end

    test "corpo vazio ou ausente não vira campo" do
      assert LogRedacao.resposta("") == nil
      assert LogRedacao.resposta(nil) == nil
    end

    test "iodata (o que o Plug entrega) é aceita" do
      assert LogRedacao.resposta([~s({"a":), ~s(1})]) == %{"a" => 1}
    end
  end

  describe "o que chega torto" do
    test "upload vira metadado do arquivo, nunca o conteúdo" do
      # Um POST multipart recusado tem `%Plug.Upload{}` dentro do `body_params`. Sem este caso, o
      # `inspect` da struct entraria na linha com o caminho do arquivo temporário — e um anexo de
      # paciente é justamente o que não pode ir para o log.
      upload = %Plug.Upload{
        filename: "exame.pdf",
        content_type: "application/pdf",
        path: "/tmp/plug-1234/multipart-abc"
      }

      assert LogRedacao.redigir(%{"arquivo" => upload}) == %{
               "arquivo" => %{arquivo: "exame.pdf", tipo: "application/pdf"}
             }
    end

    test "struct qualquer vira texto, não mapa de campos internos" do
      assert %{"quando" => texto} = LogRedacao.redigir(%{"quando" => ~D[2026-08-01]})
      assert texto =~ "2026-08-01"
    end

    test "dado que não serializa vira marcador em vez de derrubar a linha" do
      # Um PID ou uma referência dentro do payload faria o formatter estourar — e formatter que
      # estoura não perde um campo, perde a LINHA inteira.
      assert LogRedacao.redigir(%{"pid" => self()}) == %{truncado: true, bytes: 0}
    end

    test "o que não é mapa nem corpo não vira campo" do
      assert LogRedacao.redigir("uma string solta") == nil
      assert LogRedacao.redigir(123) == nil
      assert LogRedacao.resposta(123) == nil
      assert LogRedacao.resposta(:atom) == nil
    end

    test "chave que não é atom nem string não quebra a redação" do
      refute LogRedacao.sensivel?(42)
      refute LogRedacao.sensivel?({:tupla, :estranha})
    end

    test "new/1 devolve a configuração que o formatter espera" do
      assert LogRedacao.new(algo: 1) == {LogRedacao, [algo: 1]}
    end
  end

  describe "redact/3 — o backstop no formatter" do
    test "a linha inteira passa pela redação, não só o payload" do
      # Segunda camada, no mesmo espírito das três do doc 05 §2.4: se algum `Logger.info` pelo
      # sistema carimbar `cpf:` no metadata, ele também sai redigido — sem depender de quem
      # escreveu a chamada ter lembrado.
      {modulo, config} =
        Api.LogFormatter.new(
          metadata: [:cpf, :route],
          redactors: [{Api.LogRedacao, []}]
        )

      linha =
        %{
          level: :info,
          meta: %{time: 1_780_000_000_000_000, cpf: "12345678901", route: "/api/x"},
          msg: {:string, "oi"}
        }
        |> modulo.format(config)
        |> IO.iodata_to_binary()
        |> Jason.decode!()

      assert linha["cpf"] == "***"
      assert linha["route"] == "/api/x"
    end
  end

  describe "a lista contra a realidade" do
    test "todo campo sensível da trilha de auditoria também é redigido no log" do
      # A trilha (`Api.Audit.Sensiveis`) e o log são duas superfícies do mesmo dado. Um campo
      # que a trilha considera sensível e o log não seria uma inconsistência silenciosa — e o
      # log é a superfície MENOS protegida das duas (sem RLS, fora do banco).
      for {_recurso, campos} <- Api.Audit.Sensiveis.todos(), campo <- campos do
        assert LogRedacao.sensivel?(to_string(campo)),
               "`#{campo}` é redigido na trilha de auditoria mas sairia em claro no log"
      end
    end

    test "os campos de identificação do paciente estão cobertos" do
      # Blocklist erra aberto: esta lista é o que impede o erro de ser descoberto em produção.
      for campo <- ~w[nome nome_social cpf rg nascimento tel email cep endereco
                      emergencia_nome emergencia_tel medico crm convenio carteirinha tags] do
        assert LogRedacao.sensivel?(campo), "`#{campo}` do Patient sairia em claro no log"
      end
    end

    test "credencial nunca sai em claro" do
      for campo <- ~w[token senha password secret authorization api_key signature] do
        assert LogRedacao.sensivel?(campo), "`#{campo}` é credencial e sairia em claro no log"
      end
    end

    test "o que é chave de diagnóstico NÃO está na blocklist" do
      # O oposto do teste acima: uma blocklist larga demais apaga o valor do log. Estes seis são
      # o que se usa para achar a requisição e entender a recusa.
      for campo <- ~w[id clinic_id status route errors field] do
        refute LogRedacao.sensivel?(campo), "`#{campo}` é diagnóstico e não deveria ser redigido"
      end
    end
  end
end
