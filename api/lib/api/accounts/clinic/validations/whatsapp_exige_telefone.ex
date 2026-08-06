defmodule Api.Accounts.Clinic.Validations.WhatsappExigeTelefone do
  @moduledoc """
  O par `msg_whatsapp_ativo` + `telefone` não pode se desfazer.

  ## Por que isto é regra de domínio, e não de tela

  Porque o template HSM leva o telefone como **posicional obrigatório**
  (`Api.Messaging.Templates`). A Meta recusa a mensagem quando a contagem de parâmetros não bate,
  então omitir não é opção: sem telefone, `render_whatsapp/2` manda o travessão do fallback e
  toda mensagem daquela clínica sai dizendo *"Ligue para —"*. É defeito que só aparece no celular
  do paciente, dias depois, e que a recepção não tem como diagnosticar.

  E é a única saída que o canal oferece: o botão do template é URL — abre o navegador e não
  trafega nada pelo WhatsApp —, e uma resposta em texto livre cai no número compartilhado que
  `Api.Messaging.Zernio` diz explicitamente que ninguém lê.

  ## Por que ela roda nas DUAS ações

  `update_messaging` pega "ligar sem telefone". `update_info` pega o contorno: ligar com
  telefone, e apagar o telefone depois, numa tela que não fala de WhatsApp nenhum. Uma validação
  só, aplicada dos dois lados — a alternativa (deixar `update_info` livre e desligar o canal em
  silêncio quando o telefone some) trocaria um erro visível por uma clínica que parou de mandar
  mensagem sem ninguém saber.

  ## Não é atômica

  Ela compara dois atributos, e um deles em geral **não está mudando** — vem do registro. Como o
  resto do recurso já roda `require_atomic? false` (a trilha grava num `after_action`), não há
  custo novo.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    # `get_attribute/2` devolve o valor novo quando a ação o aceita e está mudando, e o valor
    # atual do registro quando não — que é exatamente o que cada uma das duas ações precisa ver
    # do campo que ela **não** mexe.
    ativo? = Ash.Changeset.get_attribute(changeset, :msg_whatsapp_ativo)
    telefone = Ash.Changeset.get_attribute(changeset, :telefone)

    if ativo? and vazio?(telefone) do
      {:error,
       field: :telefone,
       message: "informe o telefone da clínica para falar com o paciente por WhatsApp"}
    else
      :ok
    end
  end

  # Branco é ausente: o `trim?: true` do atributo transforma "   " em nil, mas a validação roda
  # sobre o valor do changeset e não pode depender da ordem em que isso acontece.
  defp vazio?(nil), do: true
  defp vazio?(valor) when is_binary(valor), do: String.trim(valor) == ""
  defp vazio?(_valor), do: false
end
