defmodule Api.Tenancy do
  @moduledoc """
  O corte transversal de tenancy — o que os domínios por-tenant precisam mas não pertence a
  nenhum deles.

  Mora aqui porque `Directory`, `Scheduling` e `Records` usam as mesmas duas peças, e deixá-las
  em um dos domínios obrigava os outros dois a importar de um vizinho (era o caso: o change
  vivia em `Api.Directory.Changes` e era usado pelos três).

    * `in_clinic/2` — **leitura** sob RLS: roda a função com a GUC de tenant setada.
    * `Api.Tenancy.SetTenantGuc` — **escrita** sob RLS: seta a GUC dentro da transação da
      própria ação (ver o moduledoc do change para por que não dá para envolver a escrita
      num `in_clinic`).
  """

  @doc """
  Roda `fun` com o GUC `movimento.clinic_id` setado (ADR-018) e devolve o resultado já
  desembrulhado — `Api.Repo.with_clinic/2` responde `{:ok, _}` porque abre transação.

  Só para **leitura**: envolver escrita numa transação externa quebra o caminho de erro (o
  rollback do Ash na transação interna arrebenta a de fora e um 422 vira 500).

  Aceita um `Api.Scope` **ou o `clinic_id` cru**. A segunda forma existe porque nem todo
  chamador tem escopo: as fontes de disponibilidade são carregadas de dentro de uma ação, que
  conhece o tenant e não a sessão. Sem ela esses pontos reescreviam o desembrulho do
  `Api.Repo.with_clinic/2` à mão — era a mesma linha copiada em três lugares.
  """
  def in_clinic(scope_or_clinic_id, fun)

  def in_clinic(%Api.Scope{clinic_id: clinic_id}, fun) when is_binary(clinic_id) do
    in_clinic(clinic_id, fun)
  end

  def in_clinic(clinic_id, fun) when is_binary(clinic_id) do
    {:ok, result} = Api.Repo.with_clinic(clinic_id, fun)
    result
  end
end
