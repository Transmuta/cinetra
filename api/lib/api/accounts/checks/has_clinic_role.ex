defmodule Api.Accounts.Checks.HasClinicRole do
  @moduledoc """
  Check de RBAC por tenant (ADR-016): o actor tem um `Membership` **ativo** na clínica
  relevante, opcionalmente com um dos papéis exigidos. Usada em mutações, onde uma FilterCheck
  declarativa não cabe.

  A resolução da membership é de `Api.Accounts.ActiveMembership` — a mesma fonte da leitura
  (`OwnAgendaOnly`) e da escrita (`OwnProfessionalColumn`). Antes cada check consultava por si,
  o que dava 5 SELECTs idênticos em `memberships` por request (achado (g) do doc 26).

  Opções:
    * `:roles` — lista de papéis aceitos, ou `:any` (qualquer membro ativo). Default `:any`.
    * `:clinic_from` — de onde tirar o `clinic_id`:
        * `:tenant` (default) — o tenant ativo (recursos por-atributo, ex. Professional);
        * `:record` — `changeset.data.clinic_id` (update/destroy de recurso global);
        * `{:argument, name}` — um argumento da ação (ex. o `:clinic_id` do convite).
  """
  use Ash.Policy.SimpleCheck

  alias Api.Accounts.ActiveMembership

  @impl true
  def describe(opts) do
    "actor é membro ativo (#{inspect(Keyword.get(opts, :roles, :any))}) da clínica " <>
      "(#{inspect(Keyword.get(opts, :clinic_from, :tenant))})"
  end

  @impl true
  def match?(actor, context, opts) do
    case ActiveMembership.fetch(actor, clinic_id(context, opts), Map.get(context, :subject)) do
      {:ok, %{papel: papel}} -> papel_permitido?(papel, Keyword.get(opts, :roles, :any))
      :error -> false
    end
  end

  # O filtro de papel saiu da query e virou casamento em memória: com a membership já
  # resolvida, "tem papel aceito?" não precisa de uma segunda ida ao banco.
  defp papel_permitido?(_papel, :any), do: true
  defp papel_permitido?(papel, roles) when is_list(roles), do: papel in roles

  defp clinic_id(%{subject: subject}, opts) do
    case Keyword.get(opts, :clinic_from, :tenant) do
      :tenant -> normalize(Map.get(subject, :tenant))
      :record -> subject |> Map.get(:data) |> record_clinic_id()
      {:argument, name} -> normalize(Ash.Changeset.get_argument(subject, name))
    end
  end

  defp clinic_id(_context, _opts), do: nil

  defp record_clinic_id(%{clinic_id: clinic_id}), do: normalize(clinic_id)
  defp record_clinic_id(_), do: nil

  defp normalize(nil), do: nil
  defp normalize(value), do: to_string(value)
end
