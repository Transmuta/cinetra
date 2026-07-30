defmodule Api.Accounts.Membership.Validations.RoleManagement do
  @moduledoc """
  ADR-016 — hierarquia de gestão de papéis. A policy de `:update`/`:revoke_access` autoriza
  qualquer owner/admin ativo da clínica; esta validação impõe a hierarquia por cima disso:

    * **owner** pode tudo — inclusive alterar/remover OUTRO owner (o `NotLastOwner` ainda
      protege o invariante "≥1 owner").
    * **admin** só gerencia os papéis abaixo dele (`profissional`/`recepcao`): não pode
      promover ninguém a `owner` (nem a si mesmo), não pode mexer num `owner`, e não pode
      alterar/remover **outro** `admin` (o PRÓPRIO vínculo é permitido).

  Sem esta regra, a policy (que autoriza qualquer owner/admin) deixaria um admin se
  autopromover a owner e destituir os owners originais (takeover), ou rebaixar/expulsar um
  admin par. O `NotLastOwner` não cobre isso: o admin viraria owner *antes* de o owner
  original deixar de ser o último.

  Não-atômica: precisa consultar o `Membership` (global) para saber se o actor é owner da
  clínica do vínculo. Complementa (não substitui) o `NotLastOwner`. Operações de sistema
  (`authorize?: false`, sem actor) passam direto — RBAC é para atores.
  """
  use Ash.Resource.Validation

  alias Api.Accounts.Membership.OwnerCheck

  @impl true
  def validate(changeset, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    target = changeset.data

    cond do
      # owner pode tudo (o NotLastOwner ainda guarda o "≥1 owner").
      OwnerCheck.owner?(actor_id, target.clinic_id) ->
        :ok

      # Daqui pra baixo o actor é admin (owner/admin garantido pela policy da ação).
      target.papel == :owner ->
        error("só a dona (owner) pode alterar ou remover owners")

      Ash.Changeset.get_attribute(changeset, :papel) == :owner ->
        error("só a dona (owner) pode promover alguém a owner")

      target.papel == :admin and target.user_id != actor_id ->
        error("um administrador não pode alterar ou remover outro administrador")

      true ->
        :ok
    end
  end

  # Sem actor (operação de sistema, authorize?: false): RBAC não se aplica.
  def validate(_changeset, _opts, _context), do: :ok

  defp error(message), do: {:error, field: :papel, message: message}
end
