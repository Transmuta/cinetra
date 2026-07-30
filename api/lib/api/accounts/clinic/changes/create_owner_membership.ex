defmodule Api.Accounts.Clinic.Changes.CreateOwnerMembership do
  @moduledoc """
  ADR-016: ao criar uma clínica (`onboard`), o usuário atual vira o `owner` dela — na
  mesma transação. Garante a invariante "≥1 owner por tenant" desde o nascimento do
  tenant e dá acesso a quem criou. Sem actor (chamada de sistema), não cria nada.

  ## Não deixa linha na trilha, e é decisão

  O par convite+aceite aqui não é concessão de acesso a ninguém: é a **invariante** do onboard,
  e a trilha o registrava como "Convidou Fulana" seguido de "Fulana aceitou o convite" — duas
  linhas descrevendo algo que não aconteceu (ninguém convidou ninguém). Quem conta o fato é
  "Criou a clínica", do mesmo usuário e no mesmo instante, e é dela que se lê que ele é o dono.

  Convite de verdade (`Api.Accounts.invite_member` pela tela de Equipe) continua deixando as
  duas linhas — lá o acesso é concedido a um terceiro, e é o registro mais sensível da trilha.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, clinic ->
      case context.actor do
        %{id: user_id} when not is_nil(user_id) ->
          {:ok, membership} =
            Api.Accounts.invite_member(
              %{papel: :owner, user_id: user_id, clinic_id: clinic.id},
              authorize?: false,
              context: %{audit_cascade: true}
            )

          {:ok, _active} =
            Api.Accounts.accept_invite(membership,
              authorize?: false,
              context: %{audit_cascade: true}
            )

          {:ok, clinic}

        _ ->
          {:ok, clinic}
      end
    end)
  end
end
