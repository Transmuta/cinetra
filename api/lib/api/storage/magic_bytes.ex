defmodule Api.Storage.MagicBytes do
  @moduledoc """
  Que tipo os bytes **são de verdade** — a assinatura de formato, sem heurística e sem confiar
  em extensão nem em `Content-Type` declarado.

  Mora aqui, e não dentro de um domínio, porque hoje há **dois** caminhos que precisam da mesma
  pergunta e nenhum dos dois é dono dela:

    * o anexo de paciente (`Api.Records.Attachment.Conteudo`), que fareja os bytes que o browser
      subiu direto no bucket;
    * o avatar do Google (`Api.Accounts.User.Avatar`), que fareja os bytes que o servidor baixou
      de `googleusercontent.com`.

  A **allowlist continua sendo de quem chama** — anexo aceita PDF, avatar não. Este módulo só
  responde "o que é isto"; quem decide "isto pode entrar" é o domínio, e é lá que a decisão de
  produto deve ser lida.

  16 bytes bastam para todas as assinaturas abaixo (WEBP, a mais longa, precisa do byte 11).
  """

  @doc "Quantos bytes bastam para farejar qualquer um dos tipos conhecidos."
  def amostra, do: 16

  @doc """
  `{:ok, content_type}` para as quatro assinaturas conhecidas, `:error` para o resto.

  O que não casa não entra — é a postura certa quando o custo do falso-negativo é "o usuário
  reenvia" e o do falso-positivo é "executável no prontuário".
  """
  def farejar(<<"%PDF-", _::binary>>), do: {:ok, "application/pdf"}
  def farejar(<<0x89, "PNG\r\n", 0x1A, "\n", _::binary>>), do: {:ok, "image/png"}
  def farejar(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def farejar(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def farejar(_), do: :error
end
