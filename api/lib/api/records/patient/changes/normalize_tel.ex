defmodule Api.Records.Patient.Changes.NormalizeTel do
  @moduledoc """
  Guarda o `tel` na forma canônica E.164 (`+5511987654321`), descartando a máscara que chega do
  formulário — doc 52 §9.

  ## Por que canônico no banco, e não "como a recepção digitou"

  Porque o mesmo número precisa ser **o mesmo valor** em três lugares que não se falam: o
  `destino` congelado na mensagem, a linha de `OptOut` (que casa por igualdade) e o
  `participantId` que vai para a Zernio. `(11) 98765-4321` e `11987654321` são a mesma pessoa e
  strings diferentes — e o efeito de tratá-las como distintas é o pior possível: alguém pede
  "SAIR", a linha de opt-out grava um formato, e a próxima mensagem sai porque a ficha guarda o
  outro.

  Normalizar na leitura, em vez de na escrita, deixaria a comparação certa e o dado errado — e
  toda consulta nova teria de lembrar de normalizar.

  ## A exibição volta a ser bonita na tela

  `web/src/lib/telefone.ts` formata na leitura. É a mesma divisão de `Api.Cnpj`: canônico no
  banco, mascarado na tela.

  Valor que não é telefone é deixado como está — quem recusa é a
  `Api.Records.Patient.Validations.TelObrigatorio`, e sobrescrever aqui apagaria o que a pessoa
  digitou antes de a mensagem de erro poder mostrá-lo de volta no formulário.
  """
  use Ash.Resource.Change

  alias Api.Messaging.Dispatch

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :tel) do
      valor = Ash.Changeset.get_attribute(changeset, :tel)

      case Dispatch.normalizar(:whatsapp, valor) do
        nil -> changeset
        e164 -> Ash.Changeset.change_attribute(changeset, :tel, e164)
      end
    else
      changeset
    end
  end
end
