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

  ## Na criação, a presença não é evento próprio da trilha

  Criar um agendamento é **um** fato, e a trilha o contava duas vezes: a linha do bloco ("Criou o
  agendamento", que o enriquecimento já mostra COM os participantes) e mais uma por presença
  ("Adicionou Fulano ao atendimento"), gravadas no mesmo instante por esta cascata. Duas linhas
  seguidas dizendo a mesma coisa, na tabela que mais cresce do projeto.

  Daí o marcador `audit_cascade_children`, que `Api.Audit.Capture` lê para calar a presença **só**
  quando ela nasce junto com o bloco. Em `:add_participant` o marcador não é posto, e é deliberado:
  entrar numa turma que já existe é um fato novo, e é a linha da presença que diz QUEM entrou — a
  do bloco ("Adicionou um participante") sai com o diff vazio e cala pelo `skip_unchanged`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    package_id = Ash.Changeset.get_argument(changeset, :package_id)
    ids = changeset |> Ash.Changeset.get_argument(:patient_ids) |> List.wrap()

    changeset = marcar_cascata(changeset)

    # `session_starts_at` é a cópia do horário do bloco que o histórico da ficha ordena (doc 43
    # §4). Nasce **aqui**, na mesma escrita — o `before_action` garante que `starts_at` já está no
    # changeset (na criação vem do corpo; num `add_participant` vem do bloco existente).
    Ash.Changeset.before_action(changeset, fn cs ->
      starts_at = Ash.Changeset.get_attribute(cs, :starts_at) || cs.data.starts_at

      Ash.Changeset.manage_relationship(
        cs,
        :attendances,
        Enum.map(
          ids,
          &%{patient_id: &1, package_id: package_id, session_starts_at: starts_at}
        ),
        type: :create
      )
    end)
  end

  # O marcador viaja em `context.shared` porque `shared` é o único pedaço do contexto que o Ash
  # repassa aos changesets das relações gerenciadas (`Map.take(changeset.context, [:shared])`, em
  # `Ash.Actions.ManagedRelationships`) — é o mesmo carona que leva o relógio e o escopo do
  # `Api.Scope` até a presença.
  #
  # `set_context` também espelha o `shared` no topo do contexto do PRÓPRIO bloco, então a marca
  # fica visível nos dois changesets. Quem separa um do outro é o `accessing_from` que o Ash põe só
  # no filho — ver a leitura em `Api.Audit.Capture`. Sem esse par, o bloco calaria a si mesmo e a
  # trilha perderia justamente a linha que se quis manter.
  defp marcar_cascata(%{action: %{type: :create}} = changeset),
    do: Ash.Changeset.set_context(changeset, %{shared: %{audit_cascade_children: true}})

  defp marcar_cascata(changeset), do: changeset
end
