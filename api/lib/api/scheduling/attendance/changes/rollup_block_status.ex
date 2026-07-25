defmodule Api.Scheduling.Attendance.Changes.RollupBlockStatus do
  @moduledoc """
  Recomputa o status do **bloco** a partir das presenças, depois de uma transição de presença
  (Frente 6/A2, doc 41). É o inverso da antiga `CascadeToAttendances`: lá o bloco mandava no
  status e cascateava; aqui a presença é a autoridade e o bloco **deriva**.

  Roda como `after_action` na mesma transação da ação de presença, então a leitura das presenças
  já enxerga a que acabou de mudar. Aplica `Api.Scheduling.Attendance.Rollup.block_status/2` e
  escreve o resultado no `Appointment` pela ação interna `:apply_participant_rollup` — que
  **sempre** bumpa a `version` (mesmo quando o status não muda): a versão é o lock otimista do
  bloco, e mexer numa presença é mexer no bloco. Esse update é o que dispara o `AgendaNotifier`
  (a agenda repinta o bloco) e devolve o bloco já atualizado ao wrapper.
  """
  use Ash.Resource.Change

  alias Api.Scheduling.Attendance.Rollup

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn cs, attendance ->
      appt =
        Ash.get!(Api.Scheduling.Appointment, attendance.appointment_id,
          authorize?: false,
          tenant: cs.tenant,
          load: [:attendances]
        )

      statuses = Enum.map(appt.attendances, & &1.status)
      novo = Rollup.block_status(appt.status, statuses)

      Ash.update!(appt, %{status: novo},
        action: :apply_participant_rollup,
        authorize?: false,
        tenant: cs.tenant,
        actor: context.actor
      )

      {:ok, attendance}
    end)
  end
end
