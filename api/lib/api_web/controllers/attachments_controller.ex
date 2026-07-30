defmodule ApiWeb.AttachmentsController do
  @moduledoc """
  Anexos do paciente (doc 51). Molde do `PatientsController`: escopo da sessão na fronteira,
  code interfaces do domínio, `clinic_id` **sempre** do escopo.

  ## Uma guarda de papel própria

  As demais telas se dividem em "todo membro lê / owner-admin escreve", e as duas guardas de
  `ApiWeb.TenantScope` cobriam exatamente isso. Anexo não cabe em nenhuma: quem acessa é
  **owner, admin e recepção** — inclusive para ler —, e o `profissional` fica de fora (decisão de
  produto de 2026-07-27). Foi o que fez `with_admin_scope/2` virar caso particular de
  `with_roles_scope/3`, com a lista de papéis vindo de quem chama.

  A guarda **não substitui** a policy de `Api.Records.Attachment`: a policy continua sendo a
  autoridade e é o que barra qualquer caminho que não passe por aqui. Ela existe para o
  `profissional` receber um **403 limpo** em vez de um `Ash.Error.Forbidden` estourando no meio
  de um `list!` e virando 500. A lista sai de um lugar só: `Attachment.papeis/0`.

  ## Os quatro passos do upload

      POST   /patients/:patient_id/attachments          → linha :pendente + URL de PUT assinada
      (o browser faz o PUT direto no R2 — os bytes não passam por aqui)
      POST   /attachments/:id/confirm                   → confere e libera
      GET    /attachments/:id/download                  → URL de GET assinada (+ trilha)
      PATCH  /attachments/:id                           → renomeia
      DELETE /attachments/:id                           → apaga bytes e linha

  Nenhum byte de laudo atravessa este módulo. O que trafega é metadado e URL assinada
  ([`05 §5.5`](../../../../docs/05-observabilidade-e-producao.md)).
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Records
  alias Api.Records.Attachment
  alias Api.Records.Attachment.Conteudo

  # GET /api/patients/:patient_id/attachments
  def index(conn, %{"patient_id" => patient_id}) do
    with_patient(conn, patient_id, fn scope, patient ->
      json(conn, %{
        attachments:
          Enum.map(Records.list_patient_attachments(scope, patient), &attachment_json/1),
        limites: limites()
      })
    end)
  end

  # POST /api/patients/:patient_id/attachments — abre o upload.
  def create(conn, %{"patient_id" => patient_id} = params) do
    with_patient(conn, patient_id, fn scope, patient ->
      attrs = %{
        nome: nome(params["nome"]),
        content_type: to_string(params["content_type"] || ""),
        bytes: parse_int(params["bytes"])
      }

      case Records.start_attachment(scope, patient, attrs) do
        {:ok, anexo, upload} ->
          conn
          |> put_status(:created)
          |> json(%{
            attachment: attachment_json(anexo),
            upload: %{url: upload.url, headers: upload.headers, expira_em: upload.expira_em}
          })

        {:error, motivo} ->
          erro(conn, motivo)
      end
    end)
  end

  # POST /api/attachments/:id/confirm — o browser terminou o PUT.
  def confirm(conn, %{"id" => id}) do
    with_attachment(conn, id, fn scope, anexo ->
      case Records.confirm_attachment(scope, anexo) do
        {:ok, confirmado} -> json(conn, %{attachment: attachment_json(confirmado)})
        {:error, motivo} -> erro(conn, motivo)
      end
    end)
  end

  # GET /api/attachments/:id/download — URL assinada de vida curta.
  def download(conn, %{"id" => id}) do
    with_attachment(conn, id, fn scope, anexo ->
      case Records.attachment_download(scope, anexo) do
        {:ok, %{url: url, expira_em: expira_em}} -> json(conn, %{url: url, expira_em: expira_em})
        {:error, motivo} -> erro(conn, motivo)
      end
    end)
  end

  # PATCH /api/attachments/:id — renomeia (só o rótulo).
  def update(conn, %{"id" => id} = params) do
    with_attachment(conn, id, fn scope, anexo ->
      case Records.rename_attachment(scope, anexo, nome(params["nome"])) do
        {:ok, renomeado} -> json(conn, %{attachment: attachment_json(renomeado)})
        {:error, motivo} -> erro(conn, motivo)
      end
    end)
  end

  # DELETE /api/attachments/:id — apaga os bytes e a linha.
  def delete(conn, %{"id" => id}) do
    with_attachment(conn, id, fn scope, anexo ->
      case Records.delete_attachment(scope, anexo) do
        :ok -> send_resp(conn, :no_content, "")
        {:error, motivo} -> erro(conn, motivo)
      end
    end)
  end

  # ---- guardas ----

  # Owner, admin ou recepção de uma clínica ativa. 403 para os demais membros (inclusive
  # `profissional`), 401 sem sessão. A lista sai de `Attachment.papeis/0` — um lugar só.
  defp with_attachment_scope(conn, fun),
    do: with_roles_scope(conn, Attachment.papeis(), fun)

  # Resolve o paciente pela porta escopada ANTES de qualquer coisa: id de outra clínica (ou
  # lixo) vira 404, e o `%Patient{}` que segue já é comprovadamente desta clínica — que é o que
  # a cabeça de `Records.start_attachment/3` casa.
  defp with_patient(conn, patient_id, fun) do
    with_attachment_scope(conn, fn scope ->
      case Records.fetch_clinic_patient(scope, patient_id) do
        {:ok, %{} = patient} -> fun.(scope, patient)
        {:ok, nil} -> not_found(conn)
      end
    end)
  end

  defp with_attachment(conn, id, fun) do
    with_attachment_scope(conn, fn scope ->
      case Records.fetch_clinic_attachment(scope, id) do
        {:ok, %{} = anexo} -> fun.(scope, anexo)
        {:ok, nil} -> not_found(conn)
      end
    end)
  end

  # ---- respostas ----

  # `chave` NÃO sai: é o endereço do objeto no bucket, e o cliente não tem o que fazer com ele
  # (o acesso é sempre por URL assinada, emitida sob policy e registrada na trilha).
  defp attachment_json(a) do
    %{
      id: a.id,
      nome: a.nome,
      content_type: a.content_type,
      bytes: a.bytes,
      status: a.status,
      inserted_at: a.inserted_at
    }
  end

  # A tela precisa saber os limites para avisar ANTES de o usuário escolher um arquivo de 80 MB —
  # e precisa que eles venham do servidor, senão viram dois números para manter em sincronia
  # (é o D-3 da paleta de cores, e não há motivo para repetir o erro de propósito).
  #
  # **`nil` quando não há credencial de storage**, e isso é o sinal de "não ofereça o upload".
  # Sem esta cláusula a lista respondia 200 com os limites mesmo sem bucket, a drop-zone aparecia
  # e o 503 só chegava DEPOIS de o usuário escolher o arquivo — exatamente o modo de falha que
  # `Api.Storage.configured?/0` existe para evitar. Pego na verificação ao vivo, não pelos testes:
  # na suíte o storage está sempre configurado (é o adaptador de memória).
  defp limites do
    if Api.Storage.configured?() do
      %{
        max_bytes: Conteudo.max_bytes(),
        max_por_paciente: Conteudo.max_por_paciente(),
        tipos: Conteudo.tipos_aceitos()
      }
    end
  end

  # O nome do arquivo é texto do usuário: trim e teto. O teto é o mesmo da constraint da coluna —
  # cortar aqui dá uma mensagem melhor que o 422 do banco.
  defp nome(valor) do
    valor |> to_string() |> String.trim() |> String.slice(0, 200)
  end

  @mensagens %{
    tipo_nao_aceito: "Envie um PDF, PNG, JPEG ou WEBP.",
    tipo_divergente: "O arquivo enviado não é do tipo que foi declarado.",
    tamanho_invalido: "Tamanho de arquivo inválido.",
    tamanho_divergente: "O arquivo enviado tem tamanho diferente do declarado.",
    cota_excedida: "Este paciente já atingiu o limite de anexos.",
    patient_outside_clinic: "Paciente não é desta clínica.",
    not_found: "O arquivo não chegou ao storage. Tente enviar de novo."
  }

  # Fora do mapa de propósito: o número vem de `Conteudo.max_bytes/0`, que é a autoridade. Escrito
  # à mão ("limite de 50 MB") era uma segunda fonte da mesma verdade — do tipo que não quebra
  # nada, só passa a mentir no dia em que o teto mudar.
  defp erro(conn, :arquivo_grande_demais) do
    invalid(conn, "O arquivo passa do limite de #{div(Conteudo.max_bytes(), 1024 * 1024)} MB.")
  end

  # `storage_unconfigured` é 503 e não 422: não é erro do pedido, é o sistema sem credencial de
  # bucket. Devolver 422 mandaria o usuário corrigir algo que não está com ele.
  defp erro(conn, :storage_unconfigured) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: "storage_unavailable",
      details: [%{field: nil, message: "Storage de anexos não configurado."}]
    })
  end

  defp erro(conn, motivo) when is_map_key(@mensagens, motivo),
    do: invalid(conn, @mensagens[motivo])

  defp erro(conn, %Ash.Error.Forbidden{} = error), do: error_response(conn, error)
  defp erro(conn, %Ash.Error.Invalid{} = error), do: error_response(conn, error)

  # Falha do próprio bucket (5xx, timeout). Não é culpa do pedido nem coisa que o usuário
  # conserte — e o motivo cru não vai para o corpo (pode ecoar a chave, que carrega os ids).
  defp erro(conn, {:storage, _}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: "storage_error",
      details: [%{field: nil, message: "O storage não respondeu. Tente de novo."}]
    })
  end

  defp erro(conn, _motivo), do: conn |> put_status(:bad_request) |> json(%{error: "bad_request"})
end
