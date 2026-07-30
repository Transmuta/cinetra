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

          {:ok,
           %{segura_se_sobrou_so_segurada(appointment, restantes, cs) | attendances: restantes}}
      end
    end)
  end

  # Se o que sobrou no bloco está **todo segurado** por uma pausa de pacote, o bloco entra em hold
  # junto — a invariante que a pausa já mantinha no caso individual: *bloco cuja única presença
  # viva está segurada É bloco segurado*.
  #
  # Sem isto, tirar o colega de uma turma que tinha uma presença segurada deixava o bloco
  # `:agendado` com **zero participantes visíveis**: um fantasma na grade, ocupando o slot pela
  # exclusion constraint, sem ninguém dentro. Medido no bate-volta de 2026-07-26 — foi o guard do
  # "último participante" passando a contar a segurada como remanescente (ela é participante; só
  # não aparece).
  #
  # Cascata interna, como as irmãs: `authorize?: false`, porque quem autorizou foi a ação do bloco.
  defp segura_se_sobrou_so_segurada(appointment, restantes, cs) do
    if restantes != [] and Enum.all?(restantes, & &1.pkg_hold) and not appointment.pkg_hold do
      {:ok, segurado} =
        Api.Scheduling.set_appointment_pkg_hold(appointment, %{pkg_hold: true},
          tenant: cs.tenant,
          authorize?: false
        )

      segurado
    else
      appointment
    end
  end

  # As presenças vivas do bloco. `authorize?: false` como a cascata irmã: quem autorizou foi a
  # ação do bloco, e o recorte A7 aqui esconderia participante do próprio bloco que já se leu.
  #
  # `include_held` porque presença **segurada** por uma pausa de pacote (doc 43 §5c) continua sendo
  # participante do bloco — só está escondida da leitura normal. Sem a porta, a retomada não
  # conseguia tirá-la da turma: `alvos == []` e o 422 "participante não encontrado neste
  # agendamento" abortava a transação inteira do `resume_package`.
  defp live_attendances(appointment_id, tenant) do
    Api.Scheduling.Attendance
    |> Ash.Query.set_context(%{include_held: true})
    |> Ash.Query.filter(appointment_id == ^appointment_id and viva? == true)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end
end
