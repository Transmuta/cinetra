defmodule Api.Scheduling.SlotHold.Changes.PurgeExpired do
  @moduledoc """
  Antes de inserir a reserva, apaga na **mesma transação** os holds já vencidos daquele
  profissional (doc 09 §6.2, passo 2). É o que fecha deterministicamente a janela entre "o hold
  venceu" e "o coletor apagou": sem isso, um hold vencido mas ainda na tabela dispararia a
  exclusion constraint e devolveria um `409` falso a quem tenta reservar o mesmo horário.

  Usa o relógio do **banco** (`now()` na DML — que aqui é `IMMUTABLE`-irrelevante, é DML e não
  constraint), não o relógio de negócio do ADR-009: a expiração de um hold é housekeeping da
  reserva, não uma decisão de agenda (doc 09 §6.2). Seta a própria GUC de tenant antes do
  `DELETE` — dois `before_action` (este e o `SetTenantGuc`) não têm ordem garantida entre si, e
  sob RLS o `DELETE` sem GUC não veria linha nenhuma (molde de `CheckAvailability`).

  Nada disto aparece no `mix test` (sandbox `postgres`, BYPASSRLS): a prova é por `psql`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      professional_id = Ash.Changeset.get_attribute(changeset, :professional_id)
      purge(changeset.tenant, professional_id)
      changeset
    end)
  end

  defp purge(clinic_id, professional_id)
       when is_binary(clinic_id) and is_binary(professional_id) do
    Api.Repo.set_clinic_guc(clinic_id)

    Api.Repo.query!(
      "DELETE FROM slot_holds WHERE professional_id = $1 AND expires_at <= now()",
      [Ecto.UUID.dump!(professional_id)]
    )
  end

  # Sem clínica ou sem profissional: nada a purgar; as validações recusam com a mensagem certa.
  defp purge(_clinic_id, _professional_id), do: :ok
end
