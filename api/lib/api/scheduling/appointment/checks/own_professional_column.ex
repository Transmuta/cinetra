defmodule Api.Scheduling.Appointment.Checks.OwnProfessionalColumn do
  @moduledoc """
  A7 **na escrita**: o membro de papel `profissional` só cria agendamento na própria coluna.

  A A7 nasceu implementada só na leitura (`Preparations.OwnAgendaOnly`), e o buraco que sobrou
  era pior do que parece: o profissional não conseguia **ler** a agenda do colega, mas escrevia
  nela às cegas — bastava mandar outro `professional_id` no corpo. Ler-restrito e escrever-livre
  é a pior combinação possível, porque o autor do estrago não vê o estrago.

  ## Por que a fonte é o `Membership`, e não o `Api.Scope`

  O `Api.Scope` diz de si mesmo que `papel` e `professional_id` são **informativos** — espelho
  de UI e de `/auth/me` — e que *"a autoridade real é a membership"*. Uma policy é o lugar onde
  a diferença importa: aqui consultamos a membership ativa, como faz `HasClinicRole`, e não
  dependemos de o chamador ter passado escopo.

  ## Fail-closed no "UUID mole"

  `Membership.professional_id` é `allow_nil? true`. Existe membro `papel: :profissional` com
  `professional_id: nil` — e para ele a resposta é **não**, em coluna nenhuma. A alternativa
  ("sem vínculo, sem restrição") seria o mesmo fail-open que `OwnAgendaOnly` existe para evitar,
  só que do lado que grava.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "agendando na própria coluna do profissional"

  @impl true
  def match?(actor, %{subject: subject}, _opts) do
    with %{id: actor_id} when not is_nil(actor_id) <- actor,
         clinic_id when not is_nil(clinic_id) <- Map.get(subject, :tenant),
         {:ok, %{professional_id: professional_id}} when not is_nil(professional_id) <-
           Api.Accounts.get_active_membership(actor_id, to_string(clinic_id),
             authorize?: false,
             not_found_error?: false
           ) do
      Ash.Changeset.get_attribute(subject, :professional_id) == professional_id
    else
      _ -> false
    end
  end
end
