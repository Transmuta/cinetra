defmodule Api.Scope do
  @moduledoc """
  O escopo da requisição (ADR-014): quem é o usuário e qual o tenant ativo. Derivado
  do `Membership` ativo na sessão pelo `ApiWeb.Plugs.LoadScope`. É a **única** fonte do
  `tenant` (clinic_id) e do `actor` das ações Ash — nunca vindo do corpo/URL (09 §8).

  Implementa `Ash.Scope.ToOpts`, então basta passar `scope: scope` às chamadas de ação
  que o Ash extrai `actor` (o `User`), `tenant` (o `clinic_id`) e o **contexto**. `papel` e
  `professional_id` são informativos (espelho de UI e `/auth/me`); a autoridade real é a
  policy do servidor, que consulta o `Membership`.

  ## O relógio

  O escopo carrega `now` e o entrega no contexto da ação, de onde validações e changes o
  leem (`changeset.context[:now]`) em vez de chamar `DateTime.utc_now/0`. É o que torna
  determinística toda regra temporal da agenda — "já começou", "é passado", "hoje" — sem
  o teste depender do relógio de parede nem quebrar na virada do dia (25 §4).

  `now` é resolvido **na construção** do escopo e é estável dali em diante: a mesma
  requisição enxerga um único instante, mesmo que atravesse várias ações.

  Sempre em UTC. O fuso é da clínica (`Clinic.timezone`, ADR-009) e entra só na fronteira,
  quando se converte data+hora local para o `:utc_datetime` do agendamento — nunca aqui.
  """
  @enforce_keys [:user, :now]
  defstruct [:user, :now, :clinic_id, :papel, :professional_id, :membership]

  @type t :: %__MODULE__{
          user: Api.Accounts.User.t() | nil,
          now: DateTime.t(),
          clinic_id: Ecto.UUID.t() | nil,
          papel: atom() | nil,
          professional_id: Ecto.UUID.t() | nil,
          membership: Api.Accounts.Membership.t() | nil
        }

  @doc """
  Escopo só com o usuário autenticado, sem tenant ativo (antes de escolher a clínica).

  Aceita `:now` para cravar o relógio; sem ele, usa o relógio de parede em UTC.
  """
  def new(user, opts \\ []), do: %__MODULE__{user: user, now: resolve_now(opts)}

  @doc """
  Escopo com tenant ativo, derivado de um `Membership` (que traz papel e professional_id).

  Aceita `:now` para cravar o relógio; sem ele, usa o relógio de parede em UTC.
  """
  def with_membership(user, membership, opts \\ [])

  def with_membership(user, %Api.Accounts.Membership{} = membership, opts) do
    %__MODULE__{
      user: user,
      now: resolve_now(opts),
      clinic_id: membership.clinic_id,
      papel: membership.papel,
      professional_id: membership.professional_id,
      membership: membership
    }
  end

  defp resolve_now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = now -> now
      nil -> DateTime.utc_now()
    end
  end

  defimpl Ash.Scope.ToOpts do
    def get_actor(%{user: user}), do: {:ok, user}

    def get_tenant(%{clinic_id: nil}), do: :error
    def get_tenant(%{clinic_id: clinic_id}), do: {:ok, clinic_id}

    # Abre o canal de contexto (antes `:error`, ou seja, fechado) para levar às ações:
    #
    #   * `now` — o relógio (ver o moduledoc). Lido como `changeset.context[:now]`.
    #   * `scope` — o escopo inteiro, porque `papel` e `professional_id` são **por-tenant** e
    #     não estão no actor: uma preparation que precise recortar linhas por papel (A7,
    #     `OwnAgendaOnly`) não teria como derivá-los sem uma consulta extra a `Membership`.
    def get_context(%{now: now} = scope), do: {:ok, %{now: now, scope: scope}}
    def get_tracer(_scope), do: :error
    def get_authorize?(_scope), do: :error
  end
end
