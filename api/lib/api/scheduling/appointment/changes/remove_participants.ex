defmodule Api.Scheduling.Appointment.Changes.RemoveParticipants do
  @moduledoc """
  Tira participantes da turma destruindo as `Attendance` deles (doc 41 etapa 3), de dentro da
  transação da ação do bloco — o espelho de `CascadeToAttendances`, que atualiza as presenças pelo
  mesmo caminho.

  ## Por que destrói em vez de cancelar a presença

  Sair da turma não é "faltou nem compareceu": é não estar mais marcado. Uma presença `:cancelada`
  continuaria aparecendo na composição do bloco e no diff da trilha como participante — e a trilha
  já registra a saída (`Attendance` tem paper trail, e foi por isso que ele foi ligado lá: *"quem
  tirou o paciente da turma?"*).

  ## O guard do último participante

  Remover a última presença viva deixaria um bloco com zero participantes — um horário ocupado na
  agenda que não é sessão de ninguém, invisível para quem olha a coluna. Quem quer desmarcar a
  sessão inteira **cancela o bloco**; é o que `Api.Packages.Bulk` decide antes de chamar aqui.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    ids = changeset |> Ash.Changeset.get_argument(:patient_ids) |> List.wrap()

    Ash.Changeset.after_action(changeset, fn cs, appointment ->
      vivas = live_attendances(appointment.id, cs.tenant)
      {alvos, restantes} = Enum.split_with(vivas, &(&1.patient_id in ids))

      cond do
        alvos == [] ->
          {:error,
           Ash.Error.Changes.InvalidArgument.exception(
             field: :patient_ids,
             message: "participante não encontrado neste agendamento"
           )}

        restantes == [] ->
          {:error,
           Ash.Error.Changes.InvalidArgument.exception(
             field: :patient_ids,
             message: "não dá para tirar o último participante — cancele o agendamento"
           )}

        true ->
          Enum.each(
            alvos,
            &Ash.destroy!(&1,
              action: :remove,
              authorize?: false,
              tenant: cs.tenant,
              actor: context.actor
            )
          )

          {:ok, %{appointment | attendances: restantes}}
      end
    end)
  end

  # As presenças vivas do bloco. `authorize?: false` como a cascata irmã: quem autorizou foi a
  # ação do bloco, e o recorte A7 aqui esconderia participante do próprio bloco que já se leu.
  defp live_attendances(appointment_id, tenant) do
    Api.Scheduling.Attendance
    |> Ash.Query.filter(appointment_id == ^appointment_id and status != :cancelada)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end
end
