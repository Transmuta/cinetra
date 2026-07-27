defmodule Api.Storage.SigV4Test do
  @moduledoc """
  A assinatura das URLs do storage.

  ## O que estes testes provam — e o que não provam

  Provam **estrutura e estabilidade**: que os parâmetros obrigatórios saem, que os headers certos
  entram em `X-Amz-SignedHeaders`, que a query é canônica (ordenada e percent-encoded) e que a
  assinatura é uma função determinística das entradas — trocar qualquer uma muda o resultado.
  O vetor fixado em "não muda sem querer" é regressão: ele trava a algoritmia para que um
  refactor não a altere em silêncio.

  **Não** provam interoperabilidade com o R2 — só o serviço real prova isso, e é por lá que a
  verificação ao vivo passa. Fica escrito para ninguém confundir suíte verde com "assina certo".
  """
  use ExUnit.Case, async: true

  alias Api.Storage.SigV4

  @config %{
    endpoint: "https://conta123.r2.cloudflarestorage.com",
    bucket: "anexos",
    access_key_id: "AKIAEXEMPLO",
    secret_access_key: "segredo-de-exemplo",
    region: "auto"
  }

  # Instante fixo — sem ele a assinatura mudaria a cada execução e nada aqui seria comparável.
  @agora ~U[2026-07-27 12:00:00Z]

  defp assinar(method, key, opts \\ []) do
    SigV4.presigned_url(@config, method, key, Keyword.put_new(opts, :now, @agora))
  end

  defp query(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  describe "forma da URL" do
    test "usa path-style com o bucket no caminho (é o endpoint documentado do R2)" do
      url = assinar("GET", "clinic/c1/patient/p1/a1.pdf")

      assert %URI{host: "conta123.r2.cloudflarestorage.com", path: caminho} = URI.parse(url)
      assert caminho == "/anexos/clinic/c1/patient/p1/a1.pdf"
    end

    test "traz os cinco parâmetros obrigatórios do SigV4 mais a assinatura" do
      q = query(assinar("PUT", "k", headers: %{"content-type" => "application/pdf"}))

      assert q["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
      assert q["X-Amz-Credential"] == "AKIAEXEMPLO/20260727/auto/s3/aws4_request"
      assert q["X-Amz-Date"] == "20260727T120000Z"
      assert q["X-Amz-Expires"] == "300"
      assert q["X-Amz-SignedHeaders"]
      assert String.match?(q["X-Amz-Signature"], ~r/^[0-9a-f]{64}$/)
    end

    test "o escopo da credencial usa a data da assinatura, não a de hoje" do
      q = query(assinar("GET", "k", now: ~U[2029-01-02 03:04:05Z]))

      assert q["X-Amz-Credential"] =~ "/20290102/"
      assert q["X-Amz-Date"] == "20290102T030405Z"
    end
  end

  describe "headers assinados — o teto de tamanho e de tipo" do
    test "por padrão só `host` é assinado" do
      assert query(assinar("GET", "k"))["X-Amz-SignedHeaders"] == "host"
    end

    test "no PUT, content-length e content-type entram assinados e em ordem canônica" do
      q =
        query(
          assinar("PUT", "k",
            headers: %{"content-type" => "application/pdf", "content-length" => "12345"}
          )
        )

      # Ordenados alfabeticamente: é o que a especificação exige, e o que o R2 vai recomputar.
      assert q["X-Amz-SignedHeaders"] == "content-length;content-type;host"
    end

    test "mudar o tamanho declarado muda a assinatura" do
      # É ISTO que faz o `content-length` ser um limite de verdade: uma URL assinada para 1 MB
      # não serve para enviar 60 MB — o R2 recomputa e recusa.
      um = assinar("PUT", "k", headers: %{"content-length" => "1048576"})
      outro = assinar("PUT", "k", headers: %{"content-length" => "62914560"})

      assert query(um)["X-Amz-Signature"] != query(outro)["X-Amz-Signature"]
    end

    test "o nome do header é normalizado para minúsculas" do
      q = query(assinar("PUT", "k", headers: %{"Content-Type" => "image/png"}))

      assert q["X-Amz-SignedHeaders"] == "content-type;host"
    end
  end

  describe "query assinada — Content-Disposition sai do bucket, não do cliente" do
    test "os parâmetros de resposta viajam dentro da assinatura" do
      url =
        assinar("GET", "k",
          query: %{
            "response-content-disposition" => "inline; filename=\"laudo joelho.pdf\"",
            "response-content-type" => "application/pdf"
          }
        )

      q = query(url)
      assert q["response-content-disposition"] == "inline; filename=\"laudo joelho.pdf\""
      assert q["response-content-type"] == "application/pdf"
    end

    test "espaço vira %20 e nunca +, e aspas são percent-encoded" do
      # `+` é a codificação de formulário, não a do RFC 3986. Um `+` aqui produziria uma
      # canonical query string diferente da que o servidor recompõe → 403.
      url = assinar("GET", "k", query: %{"response-content-disposition" => ~s(inline; f="a b")})

      assert url =~ "%20"
      refute String.contains?(URI.parse(url).query, "+")
      assert url =~ "%22"
    end

    test "mexer no disposition depois de assinado invalidaria a assinatura" do
      inline = assinar("GET", "k", query: %{"response-content-disposition" => "inline"})
      anexo = assinar("GET", "k", query: %{"response-content-disposition" => "attachment"})

      assert query(inline)["X-Amz-Signature"] != query(anexo)["X-Amz-Signature"]
    end
  end

  describe "a assinatura é função determinística das entradas" do
    test "mesmas entradas, mesma assinatura" do
      assert assinar("GET", "k") == assinar("GET", "k")
    end

    test "método, chave, validade e segredo mudam o resultado" do
      base = query(assinar("GET", "k"))["X-Amz-Signature"]

      assert query(assinar("PUT", "k"))["X-Amz-Signature"] != base
      assert query(assinar("GET", "outra"))["X-Amz-Signature"] != base
      assert query(assinar("GET", "k", expires_in: 60))["X-Amz-Signature"] != base

      outro_segredo = %{@config | secret_access_key: "outro"}

      assert query(SigV4.presigned_url(outro_segredo, "GET", "k", now: @agora))["X-Amz-Signature"] !=
               base
    end

    test "vetor fixado — a algoritmia não muda sem alguém decidir" do
      # Regressão pura: se um refactor alterar canonicalização, derivação de chave ou
      # string-to-sign, este valor muda e o teste acusa. Não é prova de interoperabilidade —
      # essa é do R2 (ver o moduledoc).
      url =
        SigV4.presigned_url(@config, "PUT", "clinic/c/patient/p/a.pdf",
          now: @agora,
          expires_in: 600,
          headers: %{"content-type" => "application/pdf", "content-length" => "1024"}
        )

      assert query(url)["X-Amz-Signature"] ==
               "6535c695a9c3d2617ffc5ee0422c5e64d257bc2fe1fc2354b5456535b0c612cf"
    end
  end
end
