defmodule Api.Records.AttachmentStatus do
  @moduledoc """
  Estado de um anexo. **Dois**, não três.

  `:pendente` é a linha criada antes de o browser enviar os bytes; `:disponivel` é o que passou
  pela conferência de tamanho e magic bytes (`Api.Records.Attachment.Conteudo.conferir/4`).

  Não existe `:rejeitado` porque nada rejeitado sobrevive: a conferência é **síncrona** na
  confirmação, e o que reprova tem o objeto apagado e a linha destruída na mesma chamada — não
  há estado intermediário para o usuário observar. O `:rejeitado` do
  [`06 §7.4`](../../../../docs/06-seguranca-e-lgpd.md) pressupõe varredura antivírus assíncrona;
  quando ela entrar ([`50 §D-6`](../../../../docs/50-debitos-tecnicos.md)), este enum ganha o
  terceiro valor e a conferência sai do caminho da request.
  """
  use Ash.Type.Enum, values: [:pendente, :disponivel]
end
