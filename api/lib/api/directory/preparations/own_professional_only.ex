defmodule Api.Directory.Preparations.OwnProfessionalOnly do
  @moduledoc """
  P1 (2026-07-21): o papel `profissional` enxerga **só o próprio** registro no diretório; os
  demais papéis (owner/admin/recepção) veem a clínica inteira.

  É a irmã da `Api.Scheduling.Preparations.OwnAgendaOnly`: aquela recorta os *agendamentos*
  (A7), esta recorta os *profissionais*. Como `Api.Directory.list_professionals!/1` é a mesma
  leitura que alimenta a sidebar da agenda, a barra de Semana/Mês e `/api/availability`, o
  recorte flui para todas elas de uma vez — um profissional deixa de ver a coluna vazia, o `0`
  ao lado do nome do colega e a disponibilidade alheia, e também a ficha do colega (CPF, dados
  bancários) na tela `/profissionais`, que não tinha recorte de leitura.

  É uma preparation e não um `authorize_if` pela mesma razão da irmã: a pergunta não é
  "pode ler?" e sim "quais linhas". `HasClinicRole` é `SimpleCheck` e devolve booleano — não
  filtra linhas.

  ## O fail-open que este módulo existe para evitar

  `Membership.professional_id` é `allow_nil? true` (o "UUID mole"): existe membro com
  `papel: :profissional` e `professional_id: nil`. A implementação ingênua ("se tem
  professional_id, filtra") deixaria esse membro **sem filtro**, vendo o diretório inteiro —
  o oposto da regra. Aqui, sem `professional_id`, o filtro é impossível de satisfazer e a
  leitura devolve lista vazia. Fail-**closed**, com teste dedicado.

  Sem membership resolvível (chamada interna, seed, `authorize?: false` sem actor) não há
  recorte: quem chama de dentro, sem actor ou tenant, está fora da fronteira HTTP e já
  respondeu por si. É o que mantém os motores (availability, candidatos da fila) enxergando
  todos os profissionais quando quem opera é a recepção.
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, context) do
    case papel_e_vinculo(query, context) do
      {:profissional, nil} ->
        Ash.Query.filter(query, false)

      {:profissional, professional_id} ->
        Ash.Query.filter(query, id == ^professional_id)

      _ ->
        query
    end
  end

  # Papel e `professional_id` são por-tenant (o mesmo usuário é profissional numa clínica e
  # admin em outra), então saem da MESMA fonte que a escrita e o recorte da agenda usam —
  # `Api.Accounts.ActiveMembership` —, que reusa o escopo no caminho feliz mas confere contra
  # o banco. Ver o moduledoc de `OwnAgendaOnly` para o histórico (achado (b) do doc 26).
  defp papel_e_vinculo(query, context) do
    actor = Map.get(context, :actor)
    tenant = Map.get(context, :tenant) || query.tenant

    case Api.Accounts.ActiveMembership.fetch(actor, tenant, query) do
      {:ok, %{papel: papel, professional_id: professional_id}} -> {papel, professional_id}
      :error -> {nil, nil}
    end
  end
end
