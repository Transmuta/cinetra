defmodule Api.Messaging.Message.Changes.AdvanceStatus do
  @moduledoc """
  Avança a máquina de entrega e carimba o instante do estado novo (doc 52 §4).

  ## A guarda que este módulo existe para dar

  Webhook fora de ordem é o **caso comum**, não a exceção: `sent` e `delivered` saem do provider
  com milissegundos de diferença e a rede não promete ordem de chegada. Sem a guarda, um `sent`
  atrasado rebaixaria para `:enviado` uma mensagem que a tela já mostra como entregue — e o
  sintoma seria a timeline "andando para trás" sozinha, sem erro em lugar nenhum.

  Quando o evento não avança, a ação vira **no-op** em vez de erro: o provider vai reentregar o
  mesmo evento se receber um erro nosso, e um 500 aqui viraria retentativa eterna de algo que
  está correto. Ver `Api.Messaging.MessageStatus.avanca?/2` para a regra.
  """
  use Ash.Resource.Change

  alias Api.Messaging.MessageStatus

  @carimbo %{
    enviado: :enviado_em,
    entregue: :entregue_em,
    lido: :lido_em,
    falhou: :falhou_em
  }

  @impl true
  def change(changeset, _opts, _context) do
    novo = Ash.Changeset.get_argument(changeset, :novo_status)
    atual = changeset.data.status

    if MessageStatus.avanca?(atual, novo) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, novo)
      |> carimbar(novo)
      |> registrar_erro(Ash.Changeset.get_argument(changeset, :erro))
    else
      changeset
    end
  end

  defp carimbar(changeset, novo) do
    case Map.fetch(@carimbo, novo) do
      {:ok, campo} -> Ash.Changeset.force_change_attribute(changeset, campo, DateTime.utc_now())
      :error -> changeset
    end
  end

  # Só o ramo de falha carrega motivo. Nos demais o argumento chega `nil` e não apaga o erro de
  # uma falha anterior — mas esse caso não existe, porque `:falhou` é terminal (`avanca?/2`).
  defp registrar_erro(changeset, nil), do: changeset

  defp registrar_erro(changeset, erro) when is_binary(erro),
    do: Ash.Changeset.force_change_attribute(changeset, :erro, String.slice(erro, 0, 300))
end
