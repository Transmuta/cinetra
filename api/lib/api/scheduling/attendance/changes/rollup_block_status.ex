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

  ## Não deixa linha na trilha, e é decisão

  Quem decidiu foi a PRESENÇA: "Marcou a falta de Fulano" já conta o fato, e o desfecho do bloco é
  derivado dela — o rollup nunca registra escolha de ninguém. Sem o marcador `audit_cascade` (lido
  por `Api.Audit.Capture`), todo clique de presença escrevia duas linhas no mesmo segundo: a da
  presença e um "Atualizou a situação pelos participantes", que num bloco de um paciente é a mesma
  frase dita de outro jeito.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Api.Scheduling.Attendance.Rollup

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn cs, attendance ->
      # `FOR UPDATE` no bloco ANTES de ler as presenças (bate-volta 2026-07-24): sem o lock, duas
      # transições simultâneas de participantes DIFERENTES leem, cada uma, um snapshot velho das
      # presenças (READ COMMITTED) e o rollup fica preso na fase antiga (ex.: `:agendado` quando os
      # dois concluíram). O lock serializa os rollups do mesmo bloco: a 2ª espera a 1ª commitar e
      # relê as presenças já frescas. A escrita das presenças é em linhas distintas; o ponto de
      # serialização é o próprio bloco.
      appt =
        Api.Scheduling.Appointment
        |> Ash.Query.filter(id == ^attendance.appointment_id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one!(authorize?: false, tenant: cs.tenant)
        |> Ash.load!([:attendances], authorize?: false, tenant: cs.tenant)

      statuses = Enum.map(appt.attendances, & &1.status)
      novo = Rollup.block_status(appt.status, statuses)

      Ash.update!(appt, %{status: novo},
        action: :apply_participant_rollup,
        authorize?: false,
        tenant: cs.tenant,
        actor: context.actor,
        context: %{audit_cascade: true}
      )

      {:ok, attendance}
    end)
  end
end
