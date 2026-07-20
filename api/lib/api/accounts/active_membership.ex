defmodule Api.Accounts.ActiveMembership do
  @moduledoc """
  A **fonte única** da membership ativa de um actor numa clínica. Todo recorte por papel —
  leitura e escrita — passa por aqui.

  ## Por que existe

  Leitura e escrita tinham autoridades **diferentes** para o mesmo recorte, e reresolver a
  membership a cada avaliação de policy custava várias leituras idênticas por request — os
  achados (b) e (g) de [doc 26 §5](../../../../docs/26-auditoria-bate-volta-agenda.md), onde
  estão a medição e o antes/depois.

  Estar num módulo só é o ponto: unificar na consulta seria correto e lento; unificar no
  escopo, rápido e frouxo. O acordo abaixo é o que dá as duas coisas.

  ## O acordo: reusar o escopo, mas conferindo

  A membership que o `Api.Scope` carrega é aceita **somente** se ela é

    * deste `actor` (`user_id` bate com o actor que o Ash resolveu para a ação),
    * desta clínica (`clinic_id` bate com o tenant da ação), e
    * `status: :ativo`.

  Qualquer divergência cai na consulta ao banco. Isso é o que mantém o cache honesto: ele não
  é uma fonte de verdade nova, é a memoização de um valor que seria lido do banco do mesmo
  jeito — e os campos conferidos são justamente os que um escopo mentiroso precisaria falsear,
  vindos de onde o chamador não controla (o actor e o tenant da própria ação).

  A quarta condição é a que fecha a forja: a membership precisa estar **carregada do banco**
  (`__meta__.state == :loaded`), não montada em memória. Sem ela, um chamador interno que
  fizesse `Api.Scope.with_membership(user, %Membership{papel: :owner, ...})` com o próprio
  `user_id` e o próprio `clinic_id` passaria pelas outras três — os campos conferem, porque
  ele os escolheu. Exigir `:loaded` custa um casamento de padrão e transforma "confere consigo
  mesma" em "existe no banco". Tem teste dedicado.

  ## Por que a memoização não é o dicionário de processo

  A alternativa óbvia — memoizar em `Process.put/2` — funciona por request e morre com ele,
  mas **arma uma armadilha para a Entrega 3**: processos de Channel são longevos, e um papel
  revogado continuaria valendo pelo resto da conexão. Aqui o ciclo de vida do cache é o do
  escopo, que é o da requisição, por construção.
  """
  require Ash.Query

  alias Api.Accounts.Membership

  @doc """
  Resolve a membership ativa de `actor` em `clinic_id`.

  `subject` é a query/changeset da ação (ou qualquer mapa com `:context`), de onde sai o
  `Api.Scope` que pode já ter a membership carregada. Passar `nil` força a consulta.
  """
  @spec fetch(term(), term(), term()) :: {:ok, Membership.t()} | :error
  def fetch(actor, clinic_id, subject \\ nil)

  def fetch(%{id: actor_id}, clinic_id, subject) when is_binary(actor_id) do
    case normalize(clinic_id) do
      nil -> :error
      cid -> resolve(actor_id, cid, scope_membership(subject))
    end
  end

  def fetch(_actor, _clinic_id, _subject), do: :error

  # `__meta__.state` é o que separa "lida do banco" de "montada em memória" — ver o moduledoc.
  defp resolve(actor_id, clinic_id, %Membership{status: :ativo, __meta__: %{state: :loaded}} = m) do
    if normalize(m.user_id) == actor_id and normalize(m.clinic_id) == clinic_id,
      do: {:ok, m},
      else: query(actor_id, clinic_id)
  end

  defp resolve(actor_id, clinic_id, _), do: query(actor_id, clinic_id)

  defp query(actor_id, clinic_id) do
    Membership
    |> Ash.Query.filter(user_id == ^actor_id and clinic_id == ^clinic_id and status == :ativo)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [membership] -> {:ok, membership}
      [] -> :error
    end
  end

  # O escopo chega ao contexto da query/changeset por `Ash.Scope.ToOpts` — ver
  # `Api.Scope.get_context/1`. Duas cláusulas porque são dois canais: a query da ação recebe
  # `:scope` direto; as queries de `load:` de relacionamento só herdam `:shared`.
  defp scope_membership(%{context: %{scope: %Api.Scope{membership: membership}}}), do: membership

  defp scope_membership(%{context: %{shared: %{scope: %Api.Scope{membership: membership}}}}),
    do: membership

  defp scope_membership(_), do: nil

  defp normalize(nil), do: nil
  defp normalize(value), do: to_string(value)
end
