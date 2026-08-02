defmodule Api.Accounts.User.AvatarTest do
  @moduledoc """
  As regras de "que foto pode entrar" no avatar vindo do Google. Puro, sem banco, sem rede e sem
  storage — é onde mora a decisão de segurança desta fatia (de onde baixamos, o que aceitamos
  como imagem, e qual chave o objeto ganha no bucket).
  """
  use ExUnit.Case, async: true

  alias Api.Accounts.User.Avatar

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>>
  @webp <<"RIFF", 36::little-32, "WEBPVP8 ">>
  @pdf "%PDF-1.7\n%êãÏÓ"

  describe "origem_valida?/1 — de onde aceitamos baixar" do
    test "aceita os hosts de foto do Google" do
      assert Avatar.origem_valida?("https://lh3.googleusercontent.com/a/ACg8ocK=s96-c")
      assert Avatar.origem_valida?("https://lh6.googleusercontent.com/foto.jpg")
    end

    test "recusa qualquer outro host" do
      # O `user_info` chega verificado do Google, mas a URL dentro dele é só uma string: sem a
      # allowlist, quem controlasse o payload apontaria o servidor para onde quisesse (SSRF) —
      # inclusive para `169.254.169.254` e para serviços internos.
      for url <- [
            "https://evil.example.com/foto.png",
            "http://169.254.169.254/latest/meta-data/",
            "https://googleusercontent.com.evil.example/foto.png",
            "https://lh3.googleusercontent.com.evil.example/foto.png"
          ] do
        refute Avatar.origem_valida?(url), "aceitou #{url}"
      end
    end

    test "recusa http puro, mesmo no host certo" do
      refute Avatar.origem_valida?("http://lh3.googleusercontent.com/foto.png")
    end

    test "recusa lixo" do
      for url <- [nil, "", "não é url", 42] do
        refute Avatar.origem_valida?(url)
      end
    end
  end

  describe "conferir/2 — o que os bytes baixados são de verdade" do
    test "aceita as três imagens da allowlist e devolve o tipo farejado" do
      assert Avatar.conferir(@png) == {:ok, "image/png"}
      assert Avatar.conferir(@jpeg) == {:ok, "image/jpeg"}
      assert Avatar.conferir(@webp) == {:ok, "image/webp"}
    end

    test "PDF é tipo conhecido, mas não é avatar" do
      # O farejador de `Api.Storage.MagicBytes` reconhece PDF (o anexo aceita); a allowlist
      # daqui é só de imagem, e a diferença entre "conheço" e "aceito" é justamente o ponto.
      assert Avatar.conferir(@pdf) == {:error, :tipo_nao_aceito}
    end

    test "SVG e HTML não passam nem pelo farejador" do
      assert Avatar.conferir(~s(<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>)) ==
               {:error, :tipo_nao_aceito}

      assert Avatar.conferir("<!doctype html>") == {:error, :tipo_nao_aceito}
    end

    test "recusa imagem acima do teto" do
      grande = @png <> :binary.copy("x", Avatar.max_bytes())
      assert Avatar.conferir(grande) == {:error, :arquivo_grande_demais}
    end

    test "recusa corpo vazio" do
      assert Avatar.conferir("") == {:error, :tipo_nao_aceito}
    end
  end

  describe "chave/2 — o endereço do objeto no bucket" do
    test "é derivada do id do usuário, com a extensão do tipo real" do
      id = "0198f1e0-0000-7000-8000-000000000001"

      assert Avatar.chave(id, "image/png") == "user/#{id}/avatar.png"
      assert Avatar.chave(id, "image/jpeg") == "user/#{id}/avatar.jpg"
      assert Avatar.chave(id, "image/webp") == "user/#{id}/avatar.webp"
    end

    test "não é por clínica: o User é global (ADR-014)" do
      chave = Avatar.chave("0198f1e0-0000-7000-8000-000000000001", "image/png")
      refute chave =~ "clinic/"
    end
  end

  describe "tipo_da_chave/1 — o caminho de volta, para assinar o GET" do
    test "devolve o content-type gravado na extensão" do
      assert Avatar.tipo_da_chave("user/abc/avatar.png") == "image/png"
      assert Avatar.tipo_da_chave("user/abc/avatar.jpg") == "image/jpeg"
      assert Avatar.tipo_da_chave("user/abc/avatar.webp") == "image/webp"
    end

    test "chave sem extensão conhecida cai num tipo genérico de imagem" do
      assert Avatar.tipo_da_chave("user/abc/avatar") == "application/octet-stream"
    end
  end
end
