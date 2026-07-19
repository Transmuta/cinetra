defmodule Api.Scheduling.Appointment.Preparations.OwnAgendaOnly do
  @moduledoc """
  A7/D1: o papel `profissional` enxerga **só a própria** agenda; os demais papéis veem a
  clínica inteira.

  É uma preparation e não um `authorize_if`, porque a pergunta não é "pode ler?" e sim "quais
  linhas": `HasClinicRole` é `SimpleCheck` e devolve booleano — não filtra linhas.

  ## O fail-open que este módulo existe para evitar

  `Membership.professional_id` é `allow_nil? true` — o moduledoc do recurso o chama de
  *"UUID mole"*. Existe, portanto, membro com `papel: :profissional` e `professional_id: nil`.
  A implementação ingênua ("se tem professional_id, filtra") deixaria esse membro **sem
  filtro nenhum**, ou seja, vendo a agenda inteira da clínica — exatamente o oposto da regra.

  Aqui o caso fecha: sem `professional_id`, o filtro é impossível de satisfazer e a leitura
  devolve lista vazia. Fail-**closed**. Tem teste dedicado (doc 25 §4).
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case scope_papel(query) do
      {:profissional, nil} ->
        # Fail-closed: profissional sem vínculo de diretório não vê agenda nenhuma.
        Ash.Query.filter(query, false)

      {:profissional, professional_id} ->
        Ash.Query.filter(query, professional_id == ^professional_id)

      _ ->
        query
    end
  end

  # O papel vem do `Api.Scope`, que chega ao contexto da query por `Ash.Scope.ToOpts`
  # (ver `Api.Scope.get_context/1`). Não dá para derivá-lo do actor: papel e `professional_id`
  # são **por-tenant**, o mesmo usuário é profissional numa clínica e admin em outra.
  #
  # Sem escopo (chamada interna, seed, `authorize?: false`) não há recorte — quem chama sem
  # escopo está fora da fronteira HTTP e já respondeu por si.
  defp scope_papel(query) do
    case query.context[:scope] do
      %Api.Scope{papel: papel, professional_id: professional_id} -> {papel, professional_id}
      _ -> {nil, nil}
    end
  end
end
