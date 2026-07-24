defmodule Api.Waitlist.WaitlistNotifier do
  @moduledoc """
  Publica as mutações da fila no `Phoenix.PubSub` (Entrega 5, D-E5.3), no molde do
  `Api.Scheduling.AgendaNotifier`. O `Ash.Notifier` roda **depois do commit**, então nenhum
  assinante enxerga um item que a transação ainda vai desfazer.

  ## Sinal, não patch — e por quê

  Diferente da agenda, a fila **não é recortada por papel** (todo membro vê a fila inteira da
  clínica), então não há o problema de reimplementar o filtro no push. E a fila não é um grid de
  alta frequência: um sinal leve que manda o cliente **recarregar a lista** (como a visão Mês faz
  com `agenda_changed`) é robusto e evita transportar o item serializado + sidecar de paciente por
  assinante. O que trafega é `{change, actor}` — a tela recarrega e reordena por prioridade.

  ## Tópico

  Interno (PubSub): `waitlist_events:<clinic_id>`. O cliente assina `waitlist:<clinic_id>` no
  `ApiWeb.WaitlistChannel` — prefixo próprio (não `clinic:<id>:waitlist` do doc 09) porque o
  socket roteia `clinic:*` inteiro para o `AgendaChannel`; um prefixo separado evita o conflito.

  ## O que este notifier NÃO faz

  O aviso "alguém está oferecendo esta vaga" **não** passa por aqui: ele é presença efêmera
  (`Phoenix.Presence` no `ApiWeb.WaitlistChannel`), não mutação de tabela. Ver o doc 39.
  """
  use Ash.Notifier

  # As ações da fila que viram sinal. `enqueue` cobre adicionar E editar (upsert por paciente);
  # `dequeue` cobre remover à mão E a conversão (que remove o item).
  @events [:enqueue, :update, :dequeue]

  @doc "Tópico interno de uma clínica. Fonte única — o canal assina pelo mesmo caminho."
  def internal_topic(clinic_id) when is_binary(clinic_id), do: "waitlist_events:#{clinic_id}"

  @doc "Assina o tópico interno (o canal chama no `join`)."
  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(Api.PubSub, topic)

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Waitlist.WaitlistEntry,
        action: %{name: name},
        data: %{clinic_id: clinic_id},
        actor: actor
      })
      when name in @events do
    broadcast(internal_topic(clinic_id), %{change: change_name(name), actor: actor_payload(actor)})

    :ok
  end

  @impl true
  def notify(_notification), do: :ok

  defp broadcast(topic, payload),
    do: Phoenix.PubSub.broadcast(Api.PubSub, topic, {:waitlist_event, payload})

  defp change_name(:enqueue), do: "entry_upserted"
  defp change_name(:update), do: "entry_upserted"
  defp change_name(:dequeue), do: "entry_removed"

  defp actor_payload(%{id: id, nome: nome}), do: %{id: id, nome: nome}
  defp actor_payload(_actor), do: nil
end
