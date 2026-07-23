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

  ## O indicador "alguém está oferecendo esta vaga" (F4)

  Entrou nesta frente, e **sem Presence**: a reserva já existe como linha (`SlotHold`, 10 min) e
  é ela que de fato bloqueia a outra pessoa. Então o notifier só passou a avisar que a tabela
  mudou — `slot_held` ao reservar, `slot_released` ao soltar — e a tela recarrega, como faz para
  qualquer outra mudança da fila.

  Presence responderia outra pergunta ("fulano está com o modal aberto") e traria um estado que
  morre com o processo; o hold sobrevive a recarregar a página, vale entre nós e é o mesmo dado
  que o 409 usa para dizer quem segura.
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

  # F4: reservar/soltar uma vaga muda o que a fila mostra (o chip "sendo oferecida"), mesmo sem
  # nenhum item ter mudado. O sinal é o mesmo — quem escuta recarrega —, só o nome muda, para o
  # cliente poder distinguir se algum dia quiser.
  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Scheduling.SlotHold,
        action: %{type: type},
        data: %{clinic_id: clinic_id},
        actor: actor
      })
      when type in [:create, :destroy] do
    broadcast(internal_topic(clinic_id), %{
      change: if(type == :create, do: "slot_held", else: "slot_released"),
      actor: actor_payload(actor)
    })

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
