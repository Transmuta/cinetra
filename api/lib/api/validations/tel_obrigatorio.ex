defmodule Api.Validations.TelObrigatorio do
  @moduledoc """
  O `tel` do cadastro é **obrigatório e precisa ser um número brasileiro válido** (doc 52 §9,
  D-H5 com o D6 na opção (b)). Vale para **paciente e profissional** — os dois cadastros que a
  D6 decidiu cobrar.

  ## Por que mora aqui, e não dentro de um recurso

  A regra é a mesma nos dois, letra por letra: mesma leitura do campo, mesma normalização, mesmas
  duas mensagens. Uma cópia por recurso divergiria no primeiro ajuste — alguém conserta a
  mensagem de um lado e o outro segue dizendo outra coisa para o mesmo erro. Como os dois donos
  estão em **domínios diferentes** (`Api.Records` e `Api.Directory`), não cabe em nenhum dos dois
  namespaces: mora no nível da aplicação, que é o menor escopo que contém os dois.

  ## Por que virou obrigatório

  É metade do par que fecha a lacuna de cobertura do §8: com telefone obrigatório e WhatsApp
  ligado, todo paciente tem pelo menos um canal, e o `:sem_canal` da timeline deixa de ser regra
  para virar exceção. Sozinho, o WhatsApp só alcançaria quem já tinha o número na ficha.

  No profissional o motivo é outro e menor — ninguém manda confirmação para ele —, mas a D6
  decidiu cobrar nos dois pelo mesmo princípio: cadastro sem contato é cadastro pela metade, e a
  hora barata de cobrar é quando a pessoa está na frente de quem digita.

  ## Por que na criação **e** no update, sem migração de dado

  D6 opção (b). A coluna continua anulável no banco e ninguém roda backfill: a ficha antiga sem
  telefone existe e é legítima até alguém encostar nela. No primeiro save, esta validação cobra —
  e a correção acontece no fluxo natural, por quem sabe o número.

  A alternativa (`allow_nil? false` no atributo) exigiria `NOT NULL` numa tabela com linhas nulas:
  ou a migration falha, ou alguém inventa um telefone para o legado. As duas são piores.

  ## Fixo passa

  Aceita 10 ou 11 dígitos (fixo e celular). Exigir celular garantiria WhatsApp para todo mundo, e
  o preço seria a recepção digitando um número qualquer para conseguir salvar o cadastro de quem
  só tem fixo — dado pior para regra mais bonita. Quem tem fixo recebe por e-mail
  (`Api.Messaging.Dispatch.celular?/1` é quem decide isso, na hora do envio).

  Não é atômica: a normalização é por caractere e não se expressa em SQL. Roda em toda escrita
  porque a ausência também é o que se valida — checar só quando o campo está mudando deixaria
  passar exatamente o caso do legado que não o informa.
  """
  use Ash.Resource.Validation

  alias Api.Messaging.Dispatch

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :tel) do
      valor when is_binary(valor) -> conferir(valor)
      _ -> {:error, field: :tel, message: "Telefone é obrigatório"}
    end
  end

  defp conferir(valor) do
    if Dispatch.normalizar(:whatsapp, valor),
      do: :ok,
      else: {:error, field: :tel, message: "Telefone inválido — use DDD + número"}
  end
end
