defmodule Api.Accounts.User.Avatar do
  @moduledoc """
  As regras da **foto de perfil vinda do Google**: de onde é lícito baixar, o que conta como
  imagem aceitável, e qual chave o objeto ganha no bucket. Módulo puro — nem Ash, nem storage,
  nem `Req` — porque é aqui que moram as duas decisões de segurança da fatia e elas precisam ser
  exercitáveis sem nada em volta.

  ## Por que existe uma allowlist de host

  O `user_info` do Google chega **verificado** (ADR-015), mas o `picture` dentro dele é só uma
  string, e quem a consome é um job do servidor fazendo `GET`. Sem allowlist, um payload
  controlado transforma esse `GET` em **SSRF**: `http://169.254.169.254/…` (metadados da
  instância), `http://db:5432` e qualquer serviço interno da rede do compose. A allowlist é
  nominal e sufixada em `googleusercontent.com` — `googleusercontent.com.evil.example` não passa.

  Só `https`. O host certo por `http` seria um downgrade que ninguém pediu.

  ## Por que o tipo declarado (de novo) não vale nada

  Mesma postura de `Api.Records.Attachment.Conteudo`: o `Content-Type` da resposta é do outro
  lado, não nosso. O tipo que grava é o **farejado** (`Api.Storage.MagicBytes`), e a allowlist
  daqui é só de imagem — PDF é tipo conhecido pelo farejador e resposta recusada aqui. SVG não
  chega nem a ser reconhecido, que é o desejado: é XML com `<script>`.

  ## O teto de tamanho

  #{div(2 * 1024 * 1024, 1024 * 1024)} MB. Foto de perfil do Google sai em ~10 KB (`=s96-c`); o
  teto não existe para o caso normal, existe para o caso em que a URL passou a apontar para outra
  coisa. Ele é aplicado sobre os bytes **já na mão** — o job também recusa antes, pelo
  `content-length`, para não gastar a banda.
  """

  # 2 MB. Ver o moduledoc: é teto de abuso, não de uso.
  @max_bytes 2 * 1024 * 1024

  # A ordem é a mesma de `Conteudo`: lista (não `Map.keys/1`), para não depender da ordem do hash.
  @tipos [
    {"image/png", "png"},
    {"image/jpeg", "jpg"},
    {"image/webp", "webp"}
  ]

  @aceitos Enum.map(@tipos, &elem(&1, 0))
  @extensoes Map.new(@tipos)
  @tipos_por_extensao Map.new(@tipos, fn {tipo, ext} -> {ext, tipo} end)

  @host_sufixo ".googleusercontent.com"

  def max_bytes, do: @max_bytes
  def tipos_aceitos, do: @aceitos

  @doc """
  A URL é um destino de onde aceitamos baixar?

  `https` **e** host sob `googleusercontent.com`. Tudo o mais é `false`, inclusive lixo
  (`nil`, string vazia, não-string) — quem chama trata a recusa como "esta pessoa fica sem foto",
  não como erro a retentar.
  """
  def origem_valida?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        String.ends_with?(host, @host_sufixo)

      _ ->
        false
    end
  end

  def origem_valida?(_), do: false

  @doc """
  Os bytes baixados podem virar avatar? Devolve `{:ok, content_type}` — o tipo **farejado**.

  Tamanho antes de tipo, como no anexo: é o tamanho que protege o processo (esses bytes estão
  todos na memória do job).
  """
  def conferir(corpo) when is_binary(corpo) do
    if byte_size(corpo) > @max_bytes do
      {:error, :arquivo_grande_demais}
    else
      case Api.Storage.MagicBytes.farejar(corpo) do
        {:ok, tipo} when tipo in @aceitos -> {:ok, tipo}
        _ -> {:error, :tipo_nao_aceito}
      end
    end
  end

  @doc """
  A chave do objeto no bucket: `user/<user_id>/avatar.<ext>`.

  **Não** leva clínica: o `User` é a identidade global (ADR-014) e a mesma pessoa aparece com a
  mesma cara nas N clínicas dela. Não leva nome nem nada vindo de fora — como no anexo, a chave é
  derivada de id.

  A extensão entra porque o tipo pode mudar entre sincronizações (o Google serve PNG ou JPEG
  conforme a origem da foto); quem grava a chave nova apaga o objeto da antiga.
  """
  def chave(user_id, content_type) do
    "user/#{user_id}/avatar.#{Map.get(@extensoes, content_type, "bin")}"
  end

  @doc """
  O caminho de volta: o `content-type` que a chave carrega na extensão.

  Serve para assinar o `GET` do `/me` sem guardar uma coluna a mais só para isso — a chave já
  contém a informação, e duas fontes para o mesmo fato divergem.
  """
  def tipo_da_chave(chave) when is_binary(chave) do
    chave
    |> Path.extname()
    |> String.trim_leading(".")
    |> then(&Map.get(@tipos_por_extensao, &1, "application/octet-stream"))
  end
end
