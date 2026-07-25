defmodule Api.Scheduling.Appointment.Changes.ManageParticipants do
  @moduledoc """
  Cria as presenças dos `patient_ids` **já com o `package_id`** (doc 41 etapa 2), em vez do
  `manage_relationship` declarativo com `value_is_key: :patient_id`.

  Existe por causa do carimbo do pacote: `value_is_key` só sabe embrulhar o valor numa chave, e o
  vínculo participante↔pacote precisa entrar na mesma escrita. Antes ele era carimbado **depois**,
  de fora da transação (`Api.Packages.Sessions.stamp/3`: relê o bloco e chama `set_package`), o que
  custava uma leitura e uma escrita a mais por sessão e deixava uma janela em que a presença
  existia sem pacote — se o processo morresse no meio, a sessão não era contada por `usadas` e
  ninguém saberia.

  `package_id` nulo (encaixe avulso/particular) é o caso comum e passa reto: o mapa vira
  `%{patient_id: id, package_id: nil}`, que é o que a presença já fazia. Quem garante que o pacote
  é do paciente é `Validations.PackageBelongsToPatient`, antes daqui.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    package_id = Ash.Changeset.get_argument(changeset, :package_id)
    ids = changeset |> Ash.Changeset.get_argument(:patient_ids) |> List.wrap()

    Ash.Changeset.manage_relationship(
      changeset,
      :attendances,
      Enum.map(ids, &%{patient_id: &1, package_id: package_id}),
      type: :create
    )
  end
end
