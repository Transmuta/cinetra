defmodule Api.Accounts.Clinic.Changes.EnqueueWelcomeEmail do
  @moduledoc """
  Enfileira as boas-vindas quando a clínica nasce (`Api.Accounts.WelcomeEmailJob`).

  ## Por que `after_transaction`, e não `after_action`

  Porque o job **não pode existir antes do commit**. Num `after_action` o insert do Oban entra na
  mesma transação do `onboard`: se qualquer coisa depois dele falhar (o seed do expediente, a
  policy, o `Membership` do owner), a transação volta e o job volta junto — ou, pior no caminho
  feliz, um worker de outro nó pega o job antes do commit e não acha a clínica. É a mesma
  armadilha que fez o `Api.Notifications.Notifier` existir, e aqui ela é evitada pelo hook.

  ## Por que um change na ação, e não um notifier no recurso

  O `Clinic` tem um notifier só (`CacheNotifier`), e ele existe para uma coisa. Pendurar o
  `Api.Notifications.Notifier` no recurso inteiro para reagir a **uma** ação faria toda escrita de
  clínica passar por ele — mais superfície do que a regra precisa. Aqui a regra é do `onboard`, e
  fica escrita no `onboard`, que é onde o próximo leitor vai procurar.

  ## Best-effort, e por quê

  Falha de enfileiramento não derruba a criação da clínica: o cadastro é o que a pessoa veio
  fazer, e perder as boas-vindas por causa do Oban seria trocar o essencial pelo acessório. O
  `Logger.warning` deixa rastro — silêncio aqui viraria "o onboarding parou de mandar e-mail" sem
  ninguém saber desde quando.
  """
  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, clinic} = resultado ->
        enfileirar(clinic, context.actor)
        resultado

      _changeset, resultado ->
        resultado
    end)
  end

  # Sem actor não há para quem escrever. Não acontece pela fronteira HTTP (a policy do `onboard`
  # exige `actor_present()`), mas acontece em script e em teste que chama com `authorize?: false`.
  defp enfileirar(_clinic, nil), do: :ok

  defp enfileirar(clinic, actor) do
    Api.Accounts.WelcomeEmailJob.enqueue(%{user_id: actor.id, clinic_id: clinic.id})
    :ok
  rescue
    erro ->
      Logger.warning("boas-vindas não enfileiradas (#{clinic.id}): #{Exception.message(erro)}")
      :ok
  end
end
