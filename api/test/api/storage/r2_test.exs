defmodule Api.Storage.R2Test do
  @moduledoc """
  O adaptador do Cloudflare R2 — a metade que **não** precisa de rede.

  `presign_put/4` e `presign_get/4` são computação pura (config + `Api.Storage.SigV4`), e é onde
  moram as duas decisões que dão errado em silêncio: o teto de tamanho que viaja no
  `content-length` assinado, e o `Content-Disposition` com nome de arquivo brasileiro. `head`,
  `get_range` e `delete` falam HTTP e ficam para a verificação ao vivo.
  """
  use ExUnit.Case, async: false

  alias Api.Storage.R2

  @config [
    adapter: R2,
    account_id: "conta123",
    bucket: "anexos",
    access_key_id: "AKIAEXEMPLO",
    secret_access_key: "segredo"
  ]

  setup do
    anterior = Application.get_env(:api, Api.Storage)
    Application.put_env(:api, Api.Storage, @config)
    on_exit(fn -> Application.put_env(:api, Api.Storage, anterior) end)
    :ok
  end

  defp query(url), do: url |> URI.parse() |> Map.get(:query) |> URI.decode_query()

  describe "presign_put/4" do
    test "assina content-type e content-length, mas só devolve o content-type ao cliente" do
      {:ok, %{url: url, headers: headers}} =
        R2.presign_put("clinic/c/patient/p/a.pdf", "application/pdf", 4096, [])

      assert query(url)["X-Amz-SignedHeaders"] == "content-length;content-type;host"

      # O `content-length` é header proibido ao JS: o browser o envia sozinho a partir do Blob.
      # Devolvê-lo aqui só induziria a tela a tentar setá-lo (e o browser a ignorar).
      assert headers == %{"content-type" => "application/pdf"}
    end

    test "a validade do PUT é maior que a do GET — upload de 50 MB em conexão ruim" do
      {:ok, %{expira_em: put}} = R2.presign_put("k", "application/pdf", 10, [])
      {:ok, %{expira_em: get}} = R2.presign_get("k", "a.pdf", "application/pdf", [])

      assert put > get
    end

    test "sem credencial configurada, não assina nada" do
      Application.put_env(:api, Api.Storage, adapter: R2, bucket: "anexos")

      assert R2.presign_put("k", "application/pdf", 10, []) == {:error, :storage_unconfigured}

      assert R2.presign_get("k", "a.pdf", "application/pdf", []) ==
               {:error, :storage_unconfigured}
    end
  end

  describe "presign_get/4 — o Content-Disposition sai do bucket" do
    test "leva disposition e content-type na query assinada" do
      {:ok, %{url: url}} = R2.presign_get("k", "laudo.pdf", "application/pdf", [])
      q = query(url)

      assert q["response-content-disposition"] == "inline; filename=\"laudo.pdf\""
      assert q["response-content-type"] == "application/pdf"
    end

    test "aceita attachment quando quem chama quer forçar download" do
      {:ok, %{url: url}} =
        R2.presign_get("k", "laudo.pdf", "application/pdf", disposition: :attachment)

      assert query(url)["response-content-disposition"] =~ "attachment;"
    end

    test "nome com acento não quebra o header — e o resto do nome sobrevive" do
      # `Content-Disposition` é header HTTP: byte fora de ASCII ali produz erro ou lixo. Nome de
      # paciente brasileiro tem acento em quase toda ficha, então isto não é caso de borda.
      {:ok, %{url: url}} =
        R2.presign_get("k", "Ressonância joelho (avaliação).pdf", "application/pdf", [])

      disposicao = query(url)["response-content-disposition"]

      assert disposicao == "inline; filename=\"Ressonancia joelho (avaliacao).pdf\""
      assert disposicao =~ "joelho"
    end

    test "aspas e barras somem — não há como escapá-las dentro do valor entre aspas" do
      {:ok, %{url: url}} = R2.presign_get("k", "../../etc/pa\"ssw\"d.pdf", "application/pdf", [])

      disposicao = query(url)["response-content-disposition"]

      # Só as duas aspas que delimitam o `filename=` podem existir no valor.
      assert disposicao |> String.graphemes() |> Enum.count(&(&1 == "\"")) == 2
      refute disposicao =~ "/"
      assert disposicao =~ "etc"
    end

    test "nome que vira vazio depois da limpeza tem um fallback" do
      {:ok, %{url: url}} = R2.presign_get("k", "日本語", "application/pdf", [])

      assert query(url)["response-content-disposition"] == "inline; filename=\"anexo\""
    end
  end
end
