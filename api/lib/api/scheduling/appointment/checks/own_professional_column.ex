defmodule Api.Scheduling.Appointment.Checks.OwnProfessionalColumn do
  @moduledoc """
  A7 **na escrita**: o membro de papel `profissional` só cria agendamento na própria coluna.

  A A7 nasceu implementada só na leitura (`Preparations.OwnAgendaOnly`), e o buraco que sobrou
  era pior do que parece: o profissional não conseguia **ler** a agenda do colega, mas escrevia
  nela às cegas — bastava mandar outro `professional_id` no corpo. Ler-restrito e escrever-livre
  é a pior combinação possível, porque o autor do estrago não vê o estrago.

  ## A fonte é o `Membership`, resolvido por `Api.Accounts.ActiveMembership`

  O `Api.Scope` dizia de si mesmo que `papel` e `professional_id` eram **informativos** e que
  *"a autoridade real é a membership"* — e este check consultava a membership por conta
  própria, enquanto a leitura irmã (`Preparations.OwnAgendaOnly`) lia do escopo. Achado (b) do
  doc 26: duas autoridades para o mesmo recorte. Hoje os dois entram pelo mesmo resolvedor, que
  reusa a membership do escopo **só quando ela confere** com o actor e o tenant da ação (e veio
  do banco) — sem afrouxar esta escrita para acelerar aquela leitura.

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
    case Api.Accounts.ActiveMembership.fetch(actor, Map.get(subject, :tenant), subject) do
      {:ok, %{professional_id: professional_id}} when not is_nil(professional_id) ->
        Ash.Changeset.get_attribute(subject, :professional_id) == professional_id

      _ ->
        false
    end
  end
end
