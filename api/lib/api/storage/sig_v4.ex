defmodule Api.Storage.SigV4 do
  @moduledoc """
  Assinatura **SigV4 por query string** (pre-signed URL) para storage compatível com S3 — no
  nosso caso o Cloudflare R2 (ADR-008).

  ## Por que não `ex_aws`

  A biblioteca canônica traria `ex_aws` + `ex_aws_s3` + `sweet_xml` + um cliente HTTP próprio
  (`hackney`, por default) num projeto que **já tem** `req`/`finch` na árvore. Quatro
  dependências para o que este módulo faz em ~90 linhas de HMAC.

  E a economia não é só de dependência: o desenho da porta (`Api.Storage`) usa URL assinada para
  **tudo** — o `PUT` do browser, mas também o `HEAD`, o `GET` de faixa e o `DELETE` que o servidor
  faz. Ou seja, este módulo é exercitado por toda operação de storage do sistema. Um erro aqui não
  se esconde num canto: derruba a suíte inteira de anexos.

  ## O que é assinado

  Payload é sempre `UNSIGNED-PAYLOAD` — obrigatório em URL assinada, já que quem envia os bytes é
  o browser e o servidor nunca os vê para calcular o hash.

  Os **headers assinados** são o mecanismo de defesa, não decoração:

    * `host` — sempre (a especificação exige);
    * `content-type` no `PUT` — o cliente não consegue subir um tipo diferente do declarado sem
      invalidar a assinatura;
    * `content-length` no `PUT` — **o teto de tamanho**. Sem ele, a URL assinada aceita qualquer
      volume de bytes até expirar. O browser não deixa o JS escrever esse header, mas o envia
      sozinho a partir do `Blob`; se o arquivo trocar entre o pedido e o envio, o R2 recusa com
      403. O `HEAD` na confirmação (`Api.Records.confirm_attachment/3`) é a segunda camada — esta
      é a primeira, e é a que evita gastar banda.

  Os parâmetros `response-content-disposition` e `response-content-type` do `GET` entram na query
  **assinada**: é assim que o `Content-Disposition` exigido pelo
  [`06 §7.6`](../../../../docs/06-seguranca-e-lgpd.md) sai do próprio bucket, sem proxy nenhum, e
  sem que o cliente possa alterá-lo (mexer na query quebra a assinatura).
  """

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"
  @unsigned "UNSIGNED-PAYLOAD"

  @typedoc "Credenciais e destino. `region` é `auto` no R2."
  @type config :: %{
          endpoint: String.t(),
          bucket: String.t(),
          access_key_id: String.t(),
          secret_access_key: String.t(),
          region: String.t()
        }

  @doc """
  URL assinada para `method` sobre `key`.

  Opções:

    * `:expires_in` — validade em segundos (default 300);
    * `:query` — parâmetros extras a **assinar** (ex.: `response-content-disposition`);
    * `:headers` — headers extras a **assinar**, além de `host` (ex.: `content-type`);
    * `:now` — `DateTime` do momento da assinatura. Injetável para o teste poder fixar o
      instante e comparar a assinatura com um valor conhecido — sem isso a algoritmia só seria
      verificável contra o serviço real.
  """
  @spec presigned_url(config(), String.t(), String.t(), keyword()) :: String.t()
  def presigned_url(config, method, key, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    expires_in = Keyword.get(opts, :expires_in, 300)
    extra_headers = Keyword.get(opts, :headers, %{})

    uri = URI.parse(config.endpoint)
    host = host_header(uri)
    path = canonical_path(config.bucket, key)

    amz_date = amz_date(now)
    date_stamp = String.slice(amz_date, 0, 8)
    scope = Enum.join([date_stamp, config.region, @service, "aws4_request"], "/")

    headers = Map.merge(%{"host" => host}, downcase_keys(extra_headers))
    signed_headers = headers |> Map.keys() |> Enum.sort() |> Enum.join(";")

    query =
      opts
      |> Keyword.get(:query, %{})
      |> Map.merge(%{
        "X-Amz-Algorithm" => @algorithm,
        "X-Amz-Credential" => "#{config.access_key_id}/#{scope}",
        "X-Amz-Date" => amz_date,
        "X-Amz-Expires" => Integer.to_string(expires_in),
        "X-Amz-SignedHeaders" => signed_headers
      })
      |> canonical_query()

    canonical_request =
      Enum.join(
        [
          String.upcase(method),
          path,
          query,
          canonical_headers(headers),
          signed_headers,
          @unsigned
        ],
        "\n"
      )

    string_to_sign =
      Enum.join([@algorithm, amz_date, scope, hex(sha256(canonical_request))], "\n")

    signature =
      config.secret_access_key
      |> signing_key(date_stamp, config.region)
      |> hmac(string_to_sign)
      |> hex()

    "#{uri.scheme}://#{host}#{path}?#{query}&X-Amz-Signature=#{signature}"
  end

  # ---- canonicalização ----

  # O host canônico leva a porta quando ela não é a do esquema — é o que o cliente HTTP põe no
  # header `Host`, e a assinatura precisa bater com o que chega do outro lado.
  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    if (scheme == "https" and port == 443) or (scheme == "http" and port == 80) or is_nil(port) do
      host
    else
      "#{host}:#{port}"
    end
  end

  # Path-style (`/<bucket>/<key>`), que é o formato do endpoint do R2. Cada segmento é
  # percent-encoded pelo conjunto **unreserved** do RFC 3986 — a barra separadora sobrevive
  # porque a codificação é por segmento, não sobre a string inteira.
  defp canonical_path(bucket, key) do
    ([bucket] ++ String.split(key, "/"))
    |> Enum.map_join("/", &uri_encode/1)
    |> then(&("/" <> &1))
  end

  # Ordenada por chave, com chave e valor percent-encoded. A MESMA string vai para a URL final:
  # reencodar depois é como as assinaturas divergem por um `+` que virou `%20`.
  defp canonical_query(query) do
    query
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("&", fn {k, v} -> "#{uri_encode(k)}=#{uri_encode(to_string(v))}" end)
  end

  defp canonical_headers(headers) do
    headers
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("", fn {k, v} -> "#{k}:#{String.trim(to_string(v))}\n" end)
  end

  defp downcase_keys(headers) do
    Map.new(headers, fn {k, v} -> {k |> to_string() |> String.downcase(), v} end)
  end

  # RFC 3986: só `A-Z a-z 0-9 - _ . ~` passam cru. `URI.encode/2` com `char_unreserved?` é
  # exatamente esse conjunto (e, em particular, codifica a barra e o espaço, que é o que a
  # especificação da AWS pede para segmento e para valor de query).
  defp uri_encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # ---- cripto ----

  defp signing_key(secret, date_stamp, region) do
    ("AWS4" <> secret)
    |> hmac(date_stamp)
    |> hmac(region)
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256(data), do: :crypto.hash(:sha256, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp amz_date(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
