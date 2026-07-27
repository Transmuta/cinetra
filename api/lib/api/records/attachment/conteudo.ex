defmodule Api.Records.Attachment.Conteudo do
  @moduledoc """
  As regras de **o que pode entrar** como anexo: allowlist de tipos, teto de tamanho e
  verificação por assinatura de arquivo (magic bytes). Módulo puro — nenhuma dependência de Ash,
  de storage ou de request — porque é aqui que mora a decisão de segurança mais afiada da fatia e
  ela precisa ser testável sem nada em volta.

  ## Por que a allowlist é fechada, e por que SVG não está nela

  O protótipo aceita `image/*` ([`:955`](../../../../interface/Movimento.dc.html#L955)). Um
  `image/*` inclui **SVG**, e SVG é um documento XML que carrega `<script>`: aberto no browser,
  executa. Como o anexo é servido do domínio do R2 e não do nosso, o estrago é contido — mas
  "contido" não é razão para aceitar. A lista é nominal: PDF, PNG, JPEG, WEBP.

  ## Por que o tipo declarado não vale nada

  O `Content-Type` que chega do browser é escolha do cliente e falsificável
  ([`06 §7.3`](../../../../docs/06-seguranca-e-lgpd.md)). Por isso a verificação real acontece
  **depois** do upload, sobre os primeiros bytes lidos do próprio bucket: se a assinatura não
  bater com a allowlist, o objeto é apagado e o anexo não existe. O declarado serve só para
  assinar o `PUT` (o cliente não consegue subir um tipo diferente do que declarou sem quebrar a
  assinatura) e para dar erro cedo, antes de gastar banda.

  ## Antivírus

  **Não há**, e é escolha declarada ([`50 §D-6`](../../../../docs/50-debitos-tecnicos.md)). O que
  fica no lugar: esta allowlist fechada, a verificação por magic bytes, e o fato de o arquivo
  nunca ser renderizado na origem do app. Um PDF com payload malicioso passa — é exatamente o
  risco que o débito nomeia.
  """

  # 50 MB por arquivo (decisão do produto). O teto é imposto em três lugares, de propósito:
  # aqui (antes de assinar), no `content-length` assinado da URL (o R2 recusa o PUT que diverge)
  # e no `HEAD` da confirmação. Um teto que existe só na tela é um teto que não existe.
  @max_bytes 50 * 1024 * 1024

  # Teto de contagem por paciente. Não é limite de negócio, é limite de abuso: sem ele, a URL
  # assinada é um convite a encher o bucket. Um paciente real não passa de algumas dezenas.
  @max_por_paciente 100

  # Quantos bytes bastam para farejar. 16 cobre com folga a maior assinatura da lista (WEBP, que
  # precisa do byte 11), e é um `GET` de faixa de custo desprezível.
  @amostra 16

  # Lista (não `Map.keys/1`) porque a ORDEM vai para a tela: é o "PDF, PNG, JPEG, WEBP" que a
  # drop-zone anuncia, e a ordem de um mapa é a do hash — mudaria sozinha ao acrescentar um tipo.
  @tipos [
    {"application/pdf", "pdf"},
    {"image/png", "png"},
    {"image/jpeg", "jpg"},
    {"image/webp", "webp"}
  ]

  @aceitos Enum.map(@tipos, &elem(&1, 0))
  @extensoes Map.new(@tipos)

  def max_bytes, do: @max_bytes
  def max_por_paciente, do: @max_por_paciente
  def amostra, do: @amostra
  def tipos_aceitos, do: @aceitos

  @doc "Extensão canônica do tipo — cosmética, para a chave do objeto ser legível no console do R2."
  def extensao(content_type), do: Map.get(@extensoes, content_type, "bin")

  @doc """
  O que o cliente declarou é aceitável? Roda **antes** de assinar a URL.

  `{:error, :tipo_nao_aceito | :tamanho_invalido | :arquivo_grande_demais}`.
  """
  def validar_declarado(content_type, bytes) do
    cond do
      content_type not in @aceitos -> {:error, :tipo_nao_aceito}
      not (is_integer(bytes) and bytes > 0) -> {:error, :tamanho_invalido}
      bytes > @max_bytes -> {:error, :arquivo_grande_demais}
      true -> :ok
    end
  end

  @doc """
  Que tipo os bytes **são de verdade**? Devolve `{:ok, content_type}` ou `:error`.

  Sem heurística e sem lista de extensões: só as quatro assinaturas que a allowlist aceita. O que
  não casa não entra — é a postura certa quando o custo do falso-negativo é "o usuário reenvia" e
  o do falso-positivo é "executável no prontuário".
  """
  def farejar(<<"%PDF-", _::binary>>), do: {:ok, "application/pdf"}
  def farejar(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  def farejar(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def farejar(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def farejar(_), do: :error

  @doc """
  O objeto que chegou ao bucket confere com o que foi prometido?

  Duas perguntas, nesta ordem — tamanho antes de tipo, porque tamanho é o que protege o bucket:

    1. o tamanho real (do `HEAD`) respeita o teto e bate com o declarado;
    2. os magic bytes dizem um tipo da allowlist, **e é o mesmo** que foi declarado.

  A segunda metade da regra 2 é o que impede a troca silenciosa: subir um JPEG declarando PDF
  passaria pelo farejador (é tipo aceito) e o anexo ficaria com o `Content-Type` errado para
  sempre. Aqui isso é `:tipo_divergente`.
  """
  def conferir(declarado, bytes_declarados, bytes_reais, amostra) do
    cond do
      bytes_reais > @max_bytes ->
        {:error, :arquivo_grande_demais}

      bytes_reais != bytes_declarados ->
        {:error, :tamanho_divergente}

      true ->
        case farejar(amostra) do
          {:ok, ^declarado} -> :ok
          {:ok, _outro} -> {:error, :tipo_divergente}
          :error -> {:error, :tipo_nao_aceito}
        end
    end
  end

  @doc """
  A chave do objeto no bucket.

  **Nunca** leva o nome que o usuário mandou: nome de arquivo é vetor de path traversal, fonte
  de colisão — e, num prontuário, costuma **ser** o dado sensível
  (`laudo-ressonancia-joelho.pdf`). O nome real mora na coluna `nome` do anexo, atrás da policy;
  a chave é só o id.
  """
  def chave(clinic_id, patient_id, attachment_id, content_type) do
    "clinic/#{clinic_id}/patient/#{patient_id}/#{attachment_id}.#{extensao(content_type)}"
  end
end
