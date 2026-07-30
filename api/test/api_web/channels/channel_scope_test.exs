defmodule ApiWeb.ChannelScopeTest do
  @moduledoc """
  A guarda de `join` compartilhada pelos três canais (D7 do doc 29).

  Os canais têm cada um o seu teste de join — este cobre a guarda **em si**, que é onde a regra
  agora mora. Vale o teste próprio porque esta é a fronteira de autorização inteira do WebSocket:
  ele não passa por plug nem por RLS, então "vínculo revogado depois do token" e "tópico de outra
  clínica" só têm este ponto para morrer.
  """
  use Api.DataCase, async: false

  alias ApiWeb.ChannelScope

  doctest ApiWeb.ChannelScope, only: [parse_topic: 2]

  defp socket_de(user_id, clinic_id), do: %{assigns: %{user_id: user_id, clinic_id: clinic_id}}

  describe "same_clinic/2" do
    test "o tópico de outra clínica não passa, mesmo com socket válido" do
      assert :ok == ChannelScope.same_clinic("c1", socket_de("u1", "c1"))
      assert :error == ChannelScope.same_clinic("c2", socket_de("u1", "c1"))
    end
  end

  describe "scope_for/2" do
    test "devolve o escopo com papel e usuário do vínculo ativo" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)

      assert {:ok, scope} = ChannelScope.scope_for(recep.user.id, ctx.clinic.id)
      assert scope.papel == :recepcao
      assert scope.clinic_id == ctx.clinic.id
      # O nome sai daqui — é o que a presença da fila mostra ("Fulana está oferecendo").
      assert scope.user.nome == "recepcao"
    end

    test "vínculo revogado não abre escopo — é o furo que o token de 15 min deixaria" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)

      :ok = Api.Accounts.revoke_access(recep.membership, actor: ctx.owner)

      assert :error == ChannelScope.scope_for(recep.user.id, ctx.clinic.id)
    end

    test "usuário sem vínculo nenhum com a clínica não abre escopo" do
      ctx = clinica()
      estranho = usuario!("Estranho")

      assert :error == ChannelScope.scope_for(estranho.id, ctx.clinic.id)
    end
  end

  describe "authorize/2" do
    test "junta as duas perguntas: mesma clínica E vínculo ativo" do
      ctx = clinica()
      prof = escopo_de_membro!(ctx, :profissional, ctx.prof.id)
      socket = socket_de(prof.user.id, ctx.clinic.id)

      assert {:ok, scope} = ChannelScope.authorize(ctx.clinic.id, socket)
      assert scope.professional_id == ctx.prof.id

      # Tópico de outra clínica com socket legítimo: morre na primeira pergunta, sem ir ao banco.
      outra = clinica()
      assert :error == ChannelScope.authorize(outra.clinic.id, socket)
    end
  end
end
