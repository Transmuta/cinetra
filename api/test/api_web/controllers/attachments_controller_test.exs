defmodule ApiWeb.AttachmentsControllerTest do
  @moduledoc """
  Os anexos ponta a ponta (doc 51): sessão real, RBAC por papel, isolamento entre clínicas, o
  ciclo `start → PUT → confirm` e a trilha de acesso.

  O `PUT` do browser é simulado por `Api.Storage.Memory.subir/3` — em produção esses bytes vão
  direto ao R2 e **não** passam pelo servidor, então não existe função de produção a chamar aqui.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Records
  alias Api.Records.Attachment.Conteudo
  alias Api.Storage.Memory

  @pdf "%PDF-1.7\n%êãÏÓ conteúdo de laudo"
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 2, 3, 4, 5, 6, 7, 8>>

  defp owner_with_clinic(prefixo \\ "anx") do
    owner = sign_in!(email_unico(prefixo))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{unico()}", %{}, actor: owner)

    {owner, clinic}
  end

  defp paciente(clinic, nome \\ "Mariana Alves") do
    Records.create_patient!(nome, %{}, tenant: clinic.id, authorize?: false)
  end

  # O ciclo completo, do jeito que a tela faz: abre o upload, "sobe" os bytes, confirma.
  defp anexar(conn, patient, corpo \\ @pdf, opts \\ []) do
    tipo = Keyword.get(opts, :content_type, "application/pdf")
    nome = Keyword.get(opts, :nome, "laudo.pdf")

    body =
      conn
      |> post(~p"/api/patients/#{patient.id}/attachments", %{
        "nome" => nome,
        "content_type" => tipo,
        "bytes" => byte_size(corpo)
      })
      |> json_response(201)

    id = body["attachment"]["id"]
    Memory.subir(chave_de(id, patient.clinic_id), tipo, corpo)
    {id, body}
  end

  # A chave nunca sai no JSON (é o endereço do laudo no bucket), então o teste a lê do banco —
  # com tenant, porque o recurso é por-atributo e uma query sem ele é recusada de saída.
  defp chave_de(id, clinic_id) do
    Ash.get!(Api.Records.Attachment, id, tenant: clinic_id, authorize?: false).chave
  end

  setup %{conn: conn} do
    Memory.limpar()
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "quem pode — owner, admin e recepção; profissional não" do
    test "os três papéis autorizados leem a lista", %{
      base_conn: base,
      owner: owner,
      clinic: clinic
    } do
      patient = paciente(clinic)

      for papel <- [:admin, :recepcao] do
        user = sessao_de_membro!(owner, clinic, papel)

        assert base
               |> authed(user)
               |> get(~p"/api/patients/#{patient.id}/attachments")
               |> json_response(200)
      end
    end

    test "profissional recebe 403 em TODAS as portas — inclusive na leitura", %{
      base_conn: base,
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      patient = paciente(clinic)
      {id, _} = anexar(conn, patient)
      conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)

      prof = authed(base, sessao_de_membro!(owner, clinic, :profissional))

      # A ficha inteira é legível por todo membro (D16); anexo é a exceção, e a exceção vale
      # também para LER. Se um dia a decisão virar, é `Attachment.papeis/0` que muda — e este
      # teste é quem avisa.
      assert prof |> get(~p"/api/patients/#{patient.id}/attachments") |> json_response(403)
      assert prof |> get(~p"/api/attachments/#{id}/download") |> json_response(403)
      assert prof |> patch(~p"/api/attachments/#{id}", %{"nome" => "x"}) |> json_response(403)
      assert prof |> delete(~p"/api/attachments/#{id}") |> json_response(403)

      assert prof
             |> post(~p"/api/patients/#{patient.id}/attachments", %{
               "nome" => "x.pdf",
               "content_type" => "application/pdf",
               "bytes" => 10
             })
             |> json_response(403)
    end

    test "sem sessão → 401", %{base_conn: base, clinic: clinic} do
      patient = paciente(clinic)

      assert base |> get(~p"/api/patients/#{patient.id}/attachments") |> json_response(401)
    end

    test "a lista de papéis é a mesma dos dois lados da fronteira", %{conn: _conn} do
      # TRIPWIRE. `web/src/lib/attachments.ts` repete esta lista para a tela esconder a seção de
      # quem não pode — e nenhum compilador liga as duas linguagens (é o D-3 da paleta de cores).
      # O irmão desta asserção está em `web/src/lib/attachments.test.ts`. Mudar quem vê anexo é
      # mudar os DOIS lados; deixar só um vermelho é o alarme.
      assert Api.Records.Attachment.papeis() == [:owner, :admin, :recepcao]
    end
  end

  describe "isolamento entre clínicas" do
    test "paciente de outra clínica é indistinguível de inexistente (404)", %{conn: conn} do
      {_outro_owner, outra} = owner_with_clinic("outra")
      alheio = paciente(outra, "Paciente Alheio")

      assert conn |> get(~p"/api/patients/#{alheio.id}/attachments") |> json_response(404)

      assert conn
             |> post(~p"/api/patients/#{alheio.id}/attachments", %{
               "nome" => "x.pdf",
               "content_type" => "application/pdf",
               "bytes" => 10
             })
             |> json_response(404)
    end

    test "anexo de outra clínica não é lido, renomeado nem apagado", %{
      base_conn: base,
      conn: conn
    } do
      {outro_owner, outra} = owner_with_clinic("outra")
      alheio = paciente(outra, "Paciente Alheio")
      {id, _} = anexar(authed(base, outro_owner), alheio)

      assert conn |> get(~p"/api/attachments/#{id}/download") |> json_response(404)
      assert conn |> patch(~p"/api/attachments/#{id}", %{"nome" => "x"}) |> json_response(404)
      assert conn |> delete(~p"/api/attachments/#{id}") |> json_response(404)
    end

    test "id malformado vira 404, não 500", %{conn: conn} do
      assert conn |> get(~p"/api/attachments/nao-e-uuid/download") |> json_response(404)
    end
  end

  describe "start — abrir o upload" do
    test "devolve a linha pendente e uma URL de PUT assinada", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)

      body =
        conn
        |> post(~p"/api/patients/#{patient.id}/attachments", %{
          "nome" => "ressonancia.pdf",
          "content_type" => "application/pdf",
          "bytes" => 2048
        })
        |> json_response(201)

      assert body["attachment"]["status"] == "pendente"
      assert body["attachment"]["nome"] == "ressonancia.pdf"
      assert body["upload"]["url"]
      assert body["upload"]["headers"]["content-type"] == "application/pdf"
      assert body["upload"]["expira_em"] > 0
    end

    test "a chave do objeto NÃO vai para o cliente", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)
      {_id, body} = anexar(conn, patient)

      # A chave é o endereço do laudo no bucket. O cliente acessa por URL assinada, emitida sob
      # policy e registrada na trilha — nunca montando o caminho por conta própria.
      refute Map.has_key?(body["attachment"], "chave")
    end

    test "tipo fora da allowlist → 422", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)

      body =
        conn
        |> post(~p"/api/patients/#{patient.id}/attachments", %{
          "nome" => "mapa.svg",
          "content_type" => "image/svg+xml",
          "bytes" => 500
        })
        |> json_response(422)

      assert hd(body["details"])["message"] =~ "PDF"
    end

    test "acima de 50 MB → 422, antes de assinar qualquer URL", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)

      body =
        conn
        |> post(~p"/api/patients/#{patient.id}/attachments", %{
          "nome" => "enorme.pdf",
          "content_type" => "application/pdf",
          "bytes" => Conteudo.max_bytes() + 1
        })
        |> json_response(422)

      assert hd(body["details"])["message"] =~ "50 MB"
      assert Memory.chaves() == []
    end

    test "a cota por paciente conta também os pendentes", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)

      # Abre `max_por_paciente` uploads e não confirma nenhum: se a cota olhasse só os
      # disponíveis, este seria o caminho para encher o bucket de graça.
      for _ <- 1..Conteudo.max_por_paciente() do
        conn
        |> post(~p"/api/patients/#{patient.id}/attachments", %{
          "nome" => "a.pdf",
          "content_type" => "application/pdf",
          "bytes" => 10
        })
        |> json_response(201)
      end

      body =
        conn
        |> post(~p"/api/patients/#{patient.id}/attachments", %{
          "nome" => "a-mais.pdf",
          "content_type" => "application/pdf",
          "bytes" => 10
        })
        |> json_response(422)

      assert hd(body["details"])["message"] =~ "limite de anexos"
    end
  end

  describe "confirm — o que de fato chegou ao bucket" do
    test "libera o anexo e grava o tamanho real", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)
      {id, _} = anexar(conn, patient)

      body = conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)

      assert body["attachment"]["status"] == "disponivel"
      assert body["attachment"]["bytes"] == byte_size(@pdf)
    end

    test "conteúdo que não bate com o tipo declarado é RECUSADO e descartado", %{
      conn: conn,
      clinic: clinic
    } do
      patient = paciente(clinic)

      # Declara PDF e sobe JPEG: o `Content-Type` do browser é falsificável, e é por isso que a
      # verdade sai dos magic bytes lidos do próprio bucket.
      body =
        conn
        |> post(~p"/api/patients/#{patient.id}/attachments", %{
          "nome" => "disfarce.pdf",
          "content_type" => "application/pdf",
          "bytes" => byte_size(@jpeg)
        })
        |> json_response(201)

      id = body["attachment"]["id"]
      Memory.subir(chave_de(id, clinic.id), "application/pdf", @jpeg)

      erro = conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(422)
      assert hd(erro["details"])["message"] =~ "não é do tipo"

      # Recusado é recusado: nem linha, nem bytes.
      assert Memory.chaves() == []
      assert conn |> get(~p"/api/attachments/#{id}/download") |> json_response(404)
    end

    test "upload que nunca chegou ao bucket → 422 e a linha pendente some", %{
      conn: conn,
      clinic: clinic
    } do
      patient = paciente(clinic)

      body =
        conn
        |> post(~p"/api/patients/#{patient.id}/attachments", %{
          "nome" => "fantasma.pdf",
          "content_type" => "application/pdf",
          "bytes" => 100
        })
        |> json_response(201)

      id = body["attachment"]["id"]

      assert conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(422)
      assert conn |> get(~p"/api/attachments/#{id}/download") |> json_response(404)
    end

    test "confirmar de novo é no-op: não duplica a trilha nem volta ao storage", %{
      conn: conn,
      owner: owner,
      clinic: clinic
    } do
      patient = paciente(clinic)
      {id, _} = anexar(conn, patient)

      for _ <- 1..5 do
        assert conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)
      end

      # `:enviou` significa "este arquivo entrou", e isso acontece UMA vez. Antes, cada POST
      # repetido gravava mais uma linha (medido: 5 POSTs → 5 eventos) e gastava mais duas idas
      # ao R2 — auditoria poluída e amplificação de rede, ambas acionáveis por quem já está
      # autenticado.
      eventos = Records.list_clinic_attachment_events(escopo(owner, clinic), id)
      assert Enum.count(eventos, &(&1.acao == :enviou)) == 1
    end

    test "confirmar de novo não reabre a janela de verificação sobre bytes trocados", %{
      conn: conn,
      clinic: clinic
    } do
      patient = paciente(clinic)
      {id, _} = anexar(conn, patient)
      conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)

      # Alguém troca os bytes no bucket (a URL de PUT assinada ainda vale pela janela dela) e
      # chama confirm de novo. O anexo JÁ está resolvido: o segundo confirm não pode nem aprovar
      # nem descartar — ele simplesmente não roda.
      Memory.subir(chave_de(id, clinic.id), "application/pdf", "<html>não é pdf</html>")

      body = conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)

      assert body["attachment"]["status"] == "disponivel"
      # e o anexo continua existindo — não foi descartado por causa dos bytes trocados
      assert conn |> get(~p"/api/attachments/#{id}/download") |> json_response(200)
    end

    test "pendente não aparece na lista da ficha", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)
      {_id, _} = anexar(conn, patient)

      body = conn |> get(~p"/api/patients/#{patient.id}/attachments") |> json_response(200)
      assert body["attachments"] == []
    end
  end

  describe "download — URL assinada e trilha" do
    setup %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)
      {id, _} = anexar(conn, patient)
      conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)
      %{patient: patient, attachment_id: id}
    end

    test "devolve URL de vida curta", %{conn: conn, attachment_id: id} do
      body = conn |> get(~p"/api/attachments/#{id}/download") |> json_response(200)

      assert body["url"] =~ "disposicao=inline"
      assert body["expira_em"] > 0 and body["expira_em"] <= 600
    end

    test "cada emissão de URL vira uma linha na trilha", %{
      conn: conn,
      attachment_id: id,
      clinic: clinic,
      owner: owner
    } do
      # É a exigência do `05 §5.5` que o protótipo não tinha: acesso a anexo é auditado. E é
      # gravado na EMISSÃO da URL, que é quando o acesso passa a existir.
      conn |> get(~p"/api/attachments/#{id}/download") |> json_response(200)
      conn |> get(~p"/api/attachments/#{id}/download") |> json_response(200)

      scope = escopo(owner, clinic)
      eventos = Records.list_clinic_attachment_events(scope, id)

      assert Enum.count(eventos, &(&1.acao == :visualizou)) == 2
      assert Enum.any?(eventos, &(&1.acao == :enviou))
      assert Enum.all?(eventos, &(&1.user_id == owner.id))
    end

    test "a trilha guarda o nome, para continuar legível depois da remoção", %{
      conn: conn,
      attachment_id: id,
      clinic: clinic,
      owner: owner
    } do
      conn |> get(~p"/api/attachments/#{id}/download") |> json_response(200)
      assert conn |> delete(~p"/api/attachments/#{id}") |> response(204)

      eventos = Records.list_clinic_attachment_events(escopo(owner, clinic), id)

      assert Enum.any?(eventos, &(&1.acao == :removeu))
      assert Enum.all?(eventos, &(&1.nome == "laudo.pdf"))
    end

    test "recepção não audita — a trilha é owner/admin", %{
      base_conn: base,
      owner: owner,
      clinic: clinic,
      attachment_id: id
    } do
      recepcao = sessao_de_membro!(owner, clinic, :recepcao)

      # Vazio, e **não** exceção: numa `read`, o Ash traduz policy reprovada em FILTRO, não em
      # `Ash.Error.Forbidden` (que é o que ele levanta em create/update/destroy — ver o teste de
      # defesa-em-profundidade abaixo). O efeito é o mesmo (ninguém lê), mas quem escrever teste
      # esperando exceção numa leitura vai vê-lo passar por engano.
      assert Records.list_clinic_attachment_events(escopo(recepcao, clinic), id) == []
      assert Records.list_clinic_attachment_events(escopo(owner, clinic), id) != []

      # Mas continua podendo operar o anexo — são perguntas diferentes.
      assert base
             |> authed(recepcao)
             |> get(~p"/api/attachments/#{id}/download")
             |> json_response(200)
    end
  end

  describe "defesa em profundidade — a policy do recurso, sem passar pelo controller" do
    setup %{owner: owner, clinic: clinic} do
      %{patient: paciente(clinic), prof: sessao_de_membro!(owner, clinic, :profissional)}
    end

    test "profissional não escreve, mesmo chamando o domínio direto", %{
      clinic: clinic,
      patient: patient,
      prof: prof
    } do
      # A guarda do controller (`with_roles_scope`) dá o 403 limpo, mas ela é conveniência de
      # fronteira. A autoridade é a policy — e é ela que este teste exercita, saltando o HTTP.
      scope = escopo(prof, clinic)

      assert {:error, %Ash.Error.Forbidden{}} =
               Records.start_attachment(scope, patient, %{
                 nome: "a.pdf",
                 content_type: "application/pdf",
                 bytes: 10
               })
    end

    test "profissional não renomeia nem remove anexo alheio", %{
      conn: conn,
      clinic: clinic,
      patient: patient,
      prof: prof
    } do
      {id, _} = anexar(conn, patient)
      conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)

      anexo = Ash.get!(Api.Records.Attachment, id, tenant: clinic.id, authorize?: false)
      scope = escopo(prof, clinic)

      assert {:error, %Ash.Error.Forbidden{}} = Records.rename_attachment(scope, anexo, "meu")
      assert {:error, %Ash.Error.Forbidden{}} = Records.delete_attachment(scope, anexo)

      # E os bytes continuam lá: a remoção nem chegou a tocar no bucket.
      assert Memory.chaves() != []
    end

    test "profissional não confirma — nem um anexo JÁ disponível", %{
      conn: conn,
      clinic: clinic,
      patient: patient,
      prof: prof
    } do
      {id, _} = anexar(conn, patient)
      conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)

      anexo = Ash.get!(Api.Records.Attachment, id, tenant: clinic.id, authorize?: false)

      # O no-op do confirm repetido (achado do bate-volta) roda DEPOIS da autorização. Posto
      # antes, ele seria a única porta da fatia a responder `{:ok, _}` a quem a policy recusa —
      # inofensivo na prática, mas quebraria a uniformidade que estes testes afirmam.
      assert {:error, %Ash.Error.Forbidden{}} =
               Records.confirm_attachment(escopo(prof, clinic), anexo)
    end

    test "profissional não LÊ — a lista vem vazia", %{
      conn: conn,
      owner: owner,
      clinic: clinic,
      patient: patient,
      prof: prof
    } do
      {id, _} = anexar(conn, patient)
      conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)

      assert Records.list_patient_attachments(escopo(prof, clinic), patient) == []
      assert Records.list_patient_attachments(escopo(owner, clinic), patient) != []
    end
  end

  describe "renomear e remover" do
    setup %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)
      {id, _} = anexar(conn, patient)
      conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)
      %{patient: patient, attachment_id: id}
    end

    test "renomear muda o rótulo e NÃO mexe no objeto", %{conn: conn, attachment_id: id} do
      antes = Memory.chaves()

      body =
        conn
        |> patch(~p"/api/attachments/#{id}", %{"nome" => "Ressonância joelho direito.pdf"})
        |> json_response(200)

      assert body["attachment"]["nome"] == "Ressonância joelho direito.pdf"
      # Renomear é um UPDATE numa coluna, nunca uma cópia de 50 MB no bucket.
      assert Memory.chaves() == antes
    end

    test "nome vazio → 422", %{conn: conn, attachment_id: id} do
      assert conn |> patch(~p"/api/attachments/#{id}", %{"nome" => "   "}) |> json_response(422)
    end

    test "remover apaga os BYTES e a linha", %{conn: conn, attachment_id: id, patient: patient} do
      assert Memory.chaves() != []

      assert conn |> delete(~p"/api/attachments/#{id}") |> response(204)

      # O ponto da fatia: sem isto, o laudo continuaria no R2 sem nada apontando para ele.
      assert Memory.chaves() == []

      body = conn |> get(~p"/api/patients/#{patient.id}/attachments") |> json_response(200)
      assert body["attachments"] == []
    end
  end

  describe "lista da ficha" do
    test "traz os limites do servidor, do mais novo para o mais antigo", %{
      conn: conn,
      clinic: clinic
    } do
      patient = paciente(clinic)

      for nome <- ["primeiro.pdf", "segundo.pdf"] do
        {id, _} = anexar(conn, patient, @pdf, nome: nome)
        conn |> post(~p"/api/attachments/#{id}/confirm") |> json_response(200)
      end

      body = conn |> get(~p"/api/patients/#{patient.id}/attachments") |> json_response(200)

      assert Enum.map(body["attachments"], & &1["nome"]) == ["segundo.pdf", "primeiro.pdf"]
      assert body["limites"]["max_bytes"] == Conteudo.max_bytes()
      assert body["limites"]["max_por_paciente"] == Conteudo.max_por_paciente()
      assert "application/pdf" in body["limites"]["tipos"]
      refute "image/svg+xml" in body["limites"]["tipos"]
    end

    test "a ordem dos tipos é estável — ela vai para a tela", %{conn: conn, clinic: clinic} do
      patient = paciente(clinic)
      body = conn |> get(~p"/api/patients/#{patient.id}/attachments") |> json_response(200)

      # A drop-zone anuncia "PDF, PNG, JPEG, WEBP". Com `Map.keys/1` a ordem era a do hash e
      # mudaria sozinha ao acrescentar um tipo.
      assert body["limites"]["tipos"] == [
               "application/pdf",
               "image/png",
               "image/jpeg",
               "image/webp"
             ]
    end

    test "sem credencial de storage, `limites` vem nulo — a tela não oferece o upload", %{
      conn: conn,
      clinic: clinic
    } do
      patient = paciente(clinic)
      anterior = Application.get_env(:api, Api.Storage)
      Application.put_env(:api, Api.Storage, adapter: Api.Storage.Memory)
      on_exit(fn -> Application.put_env(:api, Api.Storage, anterior) end)

      body = conn |> get(~p"/api/patients/#{patient.id}/attachments") |> json_response(200)

      # O 503 do upload chegava tarde demais: a drop-zone já estava na tela e o usuário já tinha
      # escolhido o arquivo. Achado da verificação ao vivo (doc 51 §7).
      assert body["limites"] == nil
    end
  end
end
