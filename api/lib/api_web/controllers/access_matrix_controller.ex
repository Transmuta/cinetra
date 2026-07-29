defmodule ApiWeb.AccessMatrixController do
  @moduledoc """
  A matriz de acesso por papel (AN-06 / D-H7): o resumo das policies que a tela de Equipe
  exibe na hora de convidar. O conteúdo é **estático por versão do código** — mora em
  `Api.Accounts.AccessMatrix`, ao lado das policies, com tripwire de teste. Aqui só se
  serializa; leitura para qualquer membro (o dado não é sensível: é a regra do jogo).
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Accounts.AccessMatrix

  # GET /api/access-matrix
  def show(conn, _params) do
    with_member_scope(conn, fn _scope ->
      json(conn, %{
        papeis: AccessMatrix.papeis(),
        areas:
          Enum.map(AccessMatrix.areas(), fn area ->
            %{id: area.id, label: area.label, obs: area.obs, acesso: area.acesso}
          end)
      })
    end)
  end
end
