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

  # Doc 96, L-3. O transporte do socket é montado **antes** do router (`endpoint.ex`), e os dois
  # limitadores são plugs de pipeline do router — logo, `join` nunca passou por teto nenhum. Cada
  # join custa uma query (a releitura do vínculo), e um token válido vive 15 min: dá para
  # `join`/`leave` em laço com uma credencial legítima, sem estourar nada.
  #
  # Esta é a terceira porta do sistema (HTTP anônimo, HTTP autenticado, WebSocket) e era a única
  # sem teto.
  describe "teto de join (L-3)" do
    setup do
      Application.put_env(:api, :rate_limit_enabled, true)

      on_exit(fn ->
        Application.put_env(:api, :rate_limit_enabled, false)
        Application.delete_env(:api, :rate_limit_global)
      end)

      :ok
    end

    defp limite_de_join!(n), do: Application.put_env(:api, :rate_limit_global, join_limit: n)

    test "join em laço é barrado depois do teto" do
      limite_de_join!(2)
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)
      socket = socket_de(recep.user.id, ctx.clinic.id)

      assert {:ok, _} = ChannelScope.authorize(ctx.clinic.id, socket)
      assert {:ok, _} = ChannelScope.authorize(ctx.clinic.id, socket)

      assert :error == ChannelScope.authorize(ctx.clinic.id, socket),
             "o join passou do teto — o WebSocket segue fora de qualquer limite"
    end

    test "o balde é por usuário: um em laço não derruba o colega" do
      limite_de_join!(1)
      ctx = clinica()
      um = escopo_de_membro!(ctx, :recepcao)
      outro = escopo_de_membro!(ctx, :profissional, ctx.prof.id)

      assert {:ok, _} =
               ChannelScope.authorize(ctx.clinic.id, socket_de(um.user.id, ctx.clinic.id))

      assert :error == ChannelScope.authorize(ctx.clinic.id, socket_de(um.user.id, ctx.clinic.id))

      assert {:ok, _} =
               ChannelScope.authorize(ctx.clinic.id, socket_de(outro.user.id, ctx.clinic.id))
    end

    test "com a enforcement desligada o teto não morde (dev e teste)" do
      limite_de_join!(1)
      Application.put_env(:api, :rate_limit_enabled, false)

      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)
      socket = socket_de(recep.user.id, ctx.clinic.id)

      for _ <- 1..3, do: assert({:ok, _} = ChannelScope.authorize(ctx.clinic.id, socket))
    end
  end
end
