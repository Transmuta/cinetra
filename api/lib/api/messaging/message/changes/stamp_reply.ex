defmodule Api.Messaging.Message.Changes.StampReply do
  @moduledoc """
  Grava a resposta do paciente (doc 52 §5).

  Idempotente **por comparação**, no mesmo espírito do `StampReadAtOnce` das notificações: o
  instante é o da **primeira** resposta e não se reescreve, mas a resposta em si é sempre a
  **última** — quem confirmou e depois clicou em "preciso remarcar" mudou de ideia, e é a segunda
  que a recepção precisa ver.

  Guardar as duas datas (primeira e última) seria mais fiel e não tem consumidor: a timeline
  mostra uma linha por mensagem, e a trilha (`AshPaperTrail`) já preserva a sequência inteira
  para quem precisar reconstituir.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    resposta = Ash.Changeset.get_argument(changeset, :resposta)

    changeset
    |> Ash.Changeset.force_change_attribute(:resposta, resposta)
    |> carimbar_uma_vez()
  end

  defp carimbar_uma_vez(%{data: %{respondido_em: %DateTime{}}} = changeset), do: changeset

  defp carimbar_uma_vez(changeset),
    do: Ash.Changeset.force_change_attribute(changeset, :respondido_em, DateTime.utc_now())
end
