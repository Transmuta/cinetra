defmodule Api.Changes.Canonicalizar do
  @moduledoc """
  Guarda CPF, telefone e e-mail na forma **canônica** — só dígitos, E.164 e minúsculo — em vez de
  "como a recepção digitou".

      change {Api.Changes.Canonicalizar, campo: :cpf}
      change {Api.Changes.Canonicalizar, campo: :tel}
      change {Api.Changes.Canonicalizar, campo: :email}

  Sucede o `Api.Records.Patient.Changes.NormalizeTel`, que fazia só o telefone e só na ficha do
  paciente. Mora num namespace neutro (`Api.Changes`) porque os dois cadastros de pessoa —
  `Api.Records.Patient` e `Api.Directory.Professional` — usam a mesma régua; é a mesma razão de
  `Api.Tenancy.SetTenantGuc` e `Api.Validations.TelObrigatorio` não morarem dentro de um recurso.

  ## Por que canônico no banco, e não na leitura

  Porque **unicidade é igualdade de string**. `123.456.789-09` e `12345678909` são a mesma pessoa
  e strings diferentes: com a máscara guardada, o índice único de CPF não impede a segunda ficha
  — bastaria digitar sem os pontos. O mesmo vale para `Ana@Example.com` e `ana@example.com`, e
  para `(11) 98765-4321` contra `11987654321`.

  O telefone já tinha um segundo motivo, anterior à unicidade (doc 52 §9): o mesmo número precisa
  ser **o mesmo valor** em três lugares que não se falam — o `destino` congelado na mensagem, a
  linha de `OptOut` (que casa por igualdade) e o `participantId` que vai para a Zernio. Alguém
  pede "SAIR", o opt-out grava um formato, e a próxima mensagem sai porque a ficha guarda o outro.

  Normalizar na leitura deixaria a comparação certa e o dado errado — e toda consulta nova teria
  de lembrar de normalizar. A exibição volta a ser bonita na tela: `web/src/lib/masks.ts` formata
  na leitura. É a divisão que `Api.Cnpj` já usa — canônico no banco, mascarado na tela.

  ## Vazio vira `nil`, e isso não é detalhe

  Campo em branco **tem** de virar `nil`: com `""` guardado, a segunda ficha sem CPF colidiria com
  a primeira no índice único (duas strings vazias são iguais; dois `nil` não são — o índice é
  `NULLS DISTINCT`), e a tela recusaria um cadastro por um campo que ninguém preencheu. O
  formulário já manda `null` para campo vazio (`fichaPayload`), mas a API é superfície pública: o
  `""` precisa morrer aqui, não lá.

  ## Valor que não é o que diz ser fica como está

  Se a canonicalização não reconhece o valor (`"abc"` como telefone), o original é preservado —
  quem recusa é a validação (`Api.Validations.TelObrigatorio`,
  `Api.Records.Patient.Validations.CampoValido`), e sobrescrever aqui apagaria o que a pessoa
  digitou antes de a mensagem de erro poder mostrá-lo de volta no formulário.
  """
  use Ash.Resource.Change

  alias Api.Messaging.Dispatch

  @campos [:cpf, :tel, :email]

  @impl true
  def init(opts) do
    if opts[:campo] in @campos,
      do: {:ok, opts},
      else: {:error, "campo deve ser um de #{inspect(@campos)}"}
  end

  @impl true
  def change(changeset, opts, _context) do
    campo = opts[:campo]

    if Ash.Changeset.changing_attribute?(changeset, campo) do
      aplicar(changeset, campo, Ash.Changeset.get_attribute(changeset, campo))
    else
      changeset
    end
  end

  defp aplicar(changeset, _campo, nil), do: changeset

  defp aplicar(changeset, campo, valor) when is_binary(valor) do
    if String.trim(valor) == "" do
      Ash.Changeset.change_attribute(changeset, campo, nil)
    else
      case canonico(campo, valor) do
        nil -> changeset
        canonico -> Ash.Changeset.change_attribute(changeset, campo, canonico)
      end
    end
  end

  # Tipo inesperado (o cast do Ash já barrou antes; isto é cinto de segurança).
  defp aplicar(changeset, _campo, _valor), do: changeset

  defp canonico(:cpf, valor), do: Api.Cpf.normalize(valor)
  defp canonico(:tel, valor), do: Dispatch.normalizar(:whatsapp, valor)
  defp canonico(:email, valor), do: Dispatch.normalizar(:email, valor)
end
