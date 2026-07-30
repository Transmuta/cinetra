defmodule Api.Records.Attachment.ConteudoTest do
  @moduledoc """
  As regras de "o que pode entrar" como anexo. Puro, sem banco e sem storage — é onde mora a
  decisão de segurança da fatia, e ela precisa ser exercitável isoladamente.
  """
  use ExUnit.Case, async: true

  alias Api.Records.Attachment.Conteudo

  # Assinaturas mínimas de cada formato, mais o resto de bytes que um arquivo real teria.
  @pdf "%PDF-1.7\n%êãÏÓ"
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>>
  @webp <<"RIFF", 36::little-32, "WEBPVP8 ">>

  describe "validar_declarado/2 — a porta de entrada, antes de assinar a URL" do
    test "aceita os quatro tipos da allowlist" do
      for tipo <- Conteudo.tipos_aceitos() do
        assert Conteudo.validar_declarado(tipo, 1024) == :ok
      end
    end

    test "SVG não entra, mesmo sendo 'imagem'" do
      # O protótipo aceitava `image/*` ([`:955`]). SVG é XML com <script>: aberto no browser,
      # executa. A allowlist é nominal justamente para não deixar isso passar por descuido.
      assert Conteudo.validar_declarado("image/svg+xml", 1024) == {:error, :tipo_nao_aceito}
    end

    test "outros tipos comuns de ataque também ficam de fora" do
      for tipo <- ["text/html", "application/x-msdownload", "application/octet-stream", ""] do
        assert Conteudo.validar_declarado(tipo, 1024) == {:error, :tipo_nao_aceito}
      end
    end

    test "recusa tamanho ausente, zero ou negativo" do
      for bytes <- [nil, 0, -1, "1024"] do
        assert Conteudo.validar_declarado("application/pdf", bytes) == {:error, :tamanho_invalido}
      end
    end

    test "recusa acima de 50 MB e aceita exatamente 50 MB" do
      assert Conteudo.validar_declarado("application/pdf", Conteudo.max_bytes()) == :ok

      assert Conteudo.validar_declarado("application/pdf", Conteudo.max_bytes() + 1) ==
               {:error, :arquivo_grande_demais}
    end
  end

  describe "farejar/1 — o que os bytes SÃO" do
    test "reconhece os quatro formatos aceitos" do
      assert Conteudo.farejar(@pdf) == {:ok, "application/pdf"}
      assert Conteudo.farejar(@png) == {:ok, "image/png"}
      assert Conteudo.farejar(@jpeg) == {:ok, "image/jpeg"}
      assert Conteudo.farejar(@webp) == {:ok, "image/webp"}
    end

    test "não reconhece HTML, SVG nem executável — nem com extensão mentirosa" do
      for amostra <- ["<!DOCTYPE html><script>", "<svg xmlns=", <<"MZ", 0x90, 0>>, "PK\x03\x04"] do
        assert Conteudo.farejar(amostra) == :error
      end
    end

    test "RIFF que não é WEBP não passa" do
      # Um WAV começa com RIFF e tem "WAVE" no byte 8. A assinatura do WEBP exige "WEBP" ali.
      assert Conteudo.farejar(<<"RIFF", 36::little-32, "WAVEfmt ">>) == :error
    end
  end

  describe "conferir/4 — o que de fato chegou ao bucket" do
    test "passa quando tamanho e tipo batem" do
      assert Conteudo.conferir("application/pdf", 14, 14, @pdf) == :ok
    end

    test "pega o arquivo trocado por outro de tipo diferente" do
      # O caso que a allowlist sozinha não pega: JPEG é tipo aceito, então `farejar` diz {:ok, _}.
      # Sem comparar com o DECLARADO, o anexo ficaria com o Content-Type errado para sempre.
      assert Conteudo.conferir("application/pdf", 16, 16, @jpeg) == {:error, :tipo_divergente}
    end

    test "pega conteúdo que não é de nenhum tipo aceito" do
      html = "<!DOCTYPE html><script>alert(1)</script>"

      assert Conteudo.conferir("application/pdf", byte_size(html), byte_size(html), html) ==
               {:error, :tipo_nao_aceito}
    end

    test "pega divergência de tamanho — o cliente declarou um arquivo e subiu outro" do
      assert Conteudo.conferir("application/pdf", 14, 999, @pdf) == {:error, :tamanho_divergente}
    end

    test "o teto vale também para o tamanho REAL, não só para o declarado" do
      # A segunda camada do limite: mesmo que a assinatura do `content-length` fosse burlada, o
      # HEAD pega. Repare que o declarado aqui é honesto — quem mentiu foi o upload.
      grande = Conteudo.max_bytes() + 1

      assert Conteudo.conferir("application/pdf", grande, grande, @pdf) ==
               {:error, :arquivo_grande_demais}
    end
  end

  describe "chave/4" do
    test "é derivada só de ids, e nunca do nome do arquivo" do
      chave = Conteudo.chave("cli", "pac", "anx", "application/pdf")

      assert chave == "clinic/cli/patient/pac/anx.pdf"
    end

    test "a extensão sai do tipo, não do que o usuário escreveu" do
      assert Conteudo.chave("c", "p", "a", "image/jpeg") =~ ".jpg"
      assert Conteudo.chave("c", "p", "a", "image/webp") =~ ".webp"
      assert Conteudo.chave("c", "p", "a", "tipo/desconhecido") =~ ".bin"
    end
  end
end
