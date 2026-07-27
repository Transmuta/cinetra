defmodule Api.Storage.R2 do
  @moduledoc """
  Adaptador de `Api.Storage` para **Cloudflare R2** (bucket privado, ADR-008).

  Toda operação — inclusive as do servidor — passa por URL assinada de
  `Api.Storage.SigV4` e um verbo HTTP cru via `Req`. Não há SDK, e é de propósito: o R2 fala
  S3 e as cinco operações que usamos não precisam de nenhuma resposta em XML (`HEAD` lê header,
  `GET` devolve bytes, `DELETE` devolve 204). Foi o que dispensou `ex_aws` + `sweet_xml` +
  cliente HTTP próprio — ver o moduledoc de `Api.Storage.SigV4`.

  ## Validades

    * `PUT` — #{div(600, 60)} min. É o teto de paciência de um upload de 50 MB em conexão ruim;
      curto o bastante para a URL não virar link compartilhável.
    * `GET` — #{div(300, 60)} min. O usuário clica e o browser abre; não há razão para durar
      mais que isso ([`06 §7.2`](../../../../docs/06-seguranca-e-lgpd.md): "vida curta").

  ## O `Content-Disposition` é `inline`, e isso é uma divergência deliberada

  [`06 §7.6`](../../../../docs/06-seguranca-e-lgpd.md) pede `attachment`. Aqui o padrão é
  `inline`, porque o pedido do produto é "baixar **ou visualizar**" e forçar download para ver uma
  radiografia é fricção diária.

  O que tornava `attachment` obrigatório era *"sem permitir execução inline **no contexto do
  app**"* — e esse contexto não existe: os bytes saem de `*.r2.cloudflarestorage.com`, origem
  diferente da do app, em aba separada. Um PDF malicioso renderizado ali não alcança sessão,
  cookie nem DOM nosso. Somem-se as duas travas de conteúdo: a allowlist é fechada
  (PDF/PNG/JPEG/WEBP) e o tipo é conferido por **magic bytes** no servidor, então HTML/SVG não
  entram; e o `response-content-type` da URL assinada é o tipo **farejado**, não o declarado —
  mesmo que algo passasse, não seria servido como `text/html`.
  """

  @behaviour Api.Storage

  require Logger

  @put_ttl 600
  @get_ttl 300
  @timeout 15_000

  @impl true
  def presign_put(key, content_type, bytes, opts) do
    with {:ok, config} <- config() do
      ttl = Keyword.get(opts, :expires_in, @put_ttl)

      url =
        Api.Storage.SigV4.presigned_url(config, "PUT", key,
          expires_in: ttl,
          now: opts[:now],
          # `content-length` assinado é o teto de tamanho de verdade (ver SigV4). O browser
          # não deixa o JS escrevê-lo, mas o manda sozinho a partir do Blob — por isso ele
          # NÃO vai na lista de headers devolvida à tela.
          headers: %{
            "content-type" => content_type,
            "content-length" => Integer.to_string(bytes)
          }
        )

      {:ok, %{url: url, headers: %{"content-type" => content_type}, expira_em: ttl}}
    end
  end

  @impl true
  def presign_get(key, nome, content_type, opts) do
    with {:ok, config} <- config() do
      ttl = Keyword.get(opts, :expires_in, @get_ttl)
      disposicao = Keyword.get(opts, :disposition, :inline)

      url =
        Api.Storage.SigV4.presigned_url(config, "GET", key,
          expires_in: ttl,
          now: opts[:now],
          query: %{
            "response-content-disposition" => "#{disposicao}; filename=\"#{ascii(nome)}\"",
            "response-content-type" => content_type
          }
        )

      {:ok, %{url: url, expira_em: ttl}}
    end
  end

  @impl true
  def head(key) do
    case request(:head, key) do
      {:ok, %{status: 200, headers: headers}} -> {:ok, %{bytes: content_length(headers)}}
      {:ok, %{status: 404}} -> {:error, :not_found}
      outro -> erro(outro, "HEAD")
    end
  end

  @impl true
  def get_range(key, first, last) do
    # `Range` NÃO é header assinado: SigV4 só verifica os que estão em `X-Amz-SignedHeaders`, e
    # mandar um a mais é legítimo. Assiná-lo obrigaria a gerar uma URL por faixa pedida.
    case request(:get, key, headers: [{"range", "bytes=#{first}-#{last}"}]) do
      {:ok, %{status: status, body: body}} when status in [200, 206] -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      outro -> erro(outro, "GET range")
    end
  end

  @impl true
  def delete(key) do
    case request(:delete, key) do
      # 404 é sucesso: apagar o que não existe é o estado desejado. Sem isto, a repetição de
      # uma remoção que falhou na segunda metade travaria para sempre.
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      outro -> erro(outro, "DELETE")
    end
  end

  # ---- interno ----

  defp request(method, key, opts \\ []) do
    with {:ok, config} <- config() do
      url = Api.Storage.SigV4.presigned_url(config, verb(method), key, expires_in: 60)

      Req.request(
        method: method,
        url: url,
        headers: Keyword.get(opts, :headers, []),
        decode_body: false,
        retry: false,
        receive_timeout: @timeout
      )
    end
  end

  defp verb(:head), do: "HEAD"
  defp verb(:get), do: "GET"
  defp verb(:delete), do: "DELETE"

  defp content_length(headers) do
    case Map.get(headers, "content-length") do
      [valor | _] -> String.to_integer(valor)
      valor when is_binary(valor) -> String.to_integer(valor)
      _ -> 0
    end
  end

  # O corpo do erro do bucket NÃO entra no log: pode ecoar a chave, que carrega os ids do
  # paciente e da clínica ([`05 §2.4`](../../../../docs/05-observabilidade-e-producao.md)).
  defp erro({:ok, %{status: status}}, operacao) do
    Logger.warning("storage: #{operacao} respondeu #{status}")
    {:error, {:storage, status}}
  end

  defp erro({:error, motivo}, operacao) do
    Logger.warning("storage: #{operacao} falhou (#{inspect(motivo)})")
    {:error, {:storage, motivo}}
  end

  defp erro(outro, _operacao), do: outro

  defp config do
    config = Api.Storage.config()

    if Api.Storage.configured?() do
      {:ok,
       %{
         endpoint: "https://#{config[:account_id]}.r2.cloudflarestorage.com",
         bucket: config[:bucket],
         access_key_id: config[:access_key_id],
         secret_access_key: config[:secret_access_key],
         # O R2 não tem região: a assinatura usa `auto`, que é o que o Cloudflare documenta.
         region: "auto"
       }}
    else
      {:error, :storage_unconfigured}
    end
  end

  # `Content-Disposition` é um header HTTP: acento e caractere de controle não passam
  # (RFC 6266 exige `filename*` para isso). O nome real fica na coluna `nome` do anexo — este
  # é só o nome que o browser sugere ao salvar. Aspas e barras saem por não terem como escapar
  # dentro de um valor entre aspas.
  defp ascii(nome) do
    nome
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\x20-\x7E]/u, "")
    |> String.replace(~r/["\\\/]/, "-")
    |> String.slice(0, 120)
    |> case do
      "" -> "anexo"
      limpo -> limpo
    end
  end
end
