defmodule Api.Accounts.User.Changes.StampTermsAcceptance do
  @moduledoc """
  Carimba o aceite dos documentos legais — **uma vez por versão** (`[D-14]`, doc 101 A4).

  A regra inteira é a idempotência por versão, e ela é o que separa um registro de aceite de um
  registro de último login:

    * versão **diferente** (ou nunca aceita) → grava versão e instante;
    * versão **igual** à que já está lá → não toca em nada.

  Sem a segunda cláusula, `termos_aceitos_em` viraria "quando entrou pela última vez" — o carimbo
  seria reescrito a cada login, e a pergunta que o D-14 quer responder ("quando esta pessoa passou
  pela versão 1.0?") deixaria de ter resposta no dia seguinte ao primeiro acesso.

  O relógio é `DateTime.utc_now/0` e não o do escopo: quem chama é a fronteira de autenticação,
  onde não há `Api.Scope` montado ainda — é o mesmo caso das ações de `Api.Messaging.Message`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    versao = Ash.Changeset.get_argument(changeset, :versao)

    if versao == changeset.data.termos_versao do
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:termos_versao, versao)
      |> Ash.Changeset.force_change_attribute(:termos_aceitos_em, DateTime.utc_now())
    end
  end
end
