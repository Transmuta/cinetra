defmodule ApiWeb.AgendaPresenceTest do
  @moduledoc """
  **F5** (doc 30 / 09 §7.4) — "quem está vendo este dia".

  A pergunta que a feature responde é operacional, não social: numa recepção com duas pessoas,
  saber que a colega está com o mesmo dia aberto é o que evita as duas remarcarem o mesmo
  paciente ao mesmo tempo. É a irmã do "alguém já está oferecendo esta vaga" da fila (doc 39), e
  usa a mesma peça — `ApiWeb.Presence` — pelas mesmas razões: morre com o socket, não vai ao
  banco e não trava nada.

  As três decisões que este arquivo protege:

    * **só a visão de DIA rastreia.** Semana assina os 5–7 tópicos de dia da janela; se o `join`
      rastreasse sempre, quem abriu a Semana apareceria como "vendo" sete dias ao mesmo tempo, o
      que é falso. O predicado é o `mode` que o cliente já declara (`block` = Dia/Lista);
    * **a chave é o usuário, não o socket.** Duas abas da mesma pessoa são uma pessoa na tela —
      o `Presence` junta os metas sob a mesma chave;
    * **o nome vem do servidor**, do vínculo lido no `join`, como na fila.
  """
  use ApiWeb.ChannelCase, async: false

  alias Api.Accounts

  @dia "2026-07-20"

  defp fixture do
    owner = sign_in!(email_unico("pres"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    %{owner: owner, clinic: clinic}
  end

  defp socket_for(user, clinic) do
    Phoenix.ChannelTest.socket(ApiWeb.UserSocket, "user_socket:#{user.id}", %{
      user_id: user.id,
      clinic_id: clinic.id
    })
  end

  defp dia_topic(clinic, dia \\ @dia), do: "clinic:#{clinic.id}:agenda:#{dia}"

  defp entrar_no_dia(user, clinic, params \\ %{}) do
    {:ok, _, socket} =
      user
      |> socket_for(clinic)
      |> subscribe_and_join(ApiWeb.AgendaChannel, dia_topic(clinic), params)

    socket
  end

  defp eventualmente(fun, tentativas \\ 50) do
    cond do
      fun.() -> true
      tentativas == 0 -> false
      true -> Process.sleep(20) && eventualmente(fun, tentativas - 1)
    end
  end

  describe "quem está vendo este dia" do
    test "o join do dia rastreia o assinante, com o nome do servidor" do
      ctx = fixture()
      socket = entrar_no_dia(ctx.owner, ctx.clinic)

      assert eventualmente(fn -> map_size(ApiWeb.Presence.list(socket)) == 1 end),
             "o assinante do dia não apareceu na presença"

      assert %{metas: [meta]} = ApiWeb.Presence.list(socket)[ctx.owner.id]
      assert meta.nome == ctx.owner.nome
    end

    test "o estado inicial chega no join — quem entra depois vê quem já estava" do
      ctx = fixture()
      recep = sessao_de_membro!(ctx.owner, ctx.clinic, :recepcao)

      _dono = entrar_no_dia(ctx.owner, ctx.clinic)
      segundo = entrar_no_dia(recep, ctx.clinic)

      # Sem este push, quem chega depois só descobriria no próximo diff — ou seja, nunca, se
      # ninguém mexer. É o mesmo `after_join` da fila.
      assert_push "presence_state", estado
      assert map_size(estado) >= 1

      assert eventualmente(fn -> map_size(ApiWeb.Presence.list(segundo)) == 2 end),
             "os dois assinantes deveriam se ver"
    end

    test "duas abas da mesma pessoa são UMA pessoa na tela" do
      ctx = fixture()

      _aba1 = entrar_no_dia(ctx.owner, ctx.clinic)
      aba2 = entrar_no_dia(ctx.owner, ctx.clinic)

      assert eventualmente(fn -> map_size(ApiWeb.Presence.list(aba2)) == 1 end)

      assert %{metas: metas} = ApiWeb.Presence.list(aba2)[ctx.owner.id]
      assert length(metas) == 2, "as duas abas viram dois metas sob a MESMA chave de usuário"
    end

    test "fechar a aba tira o aviso — não há TTL nem limpeza a fazer" do
      ctx = fixture()
      recep = sessao_de_membro!(ctx.owner, ctx.clinic, :recepcao)

      socket = entrar_no_dia(ctx.owner, ctx.clinic)
      observador = entrar_no_dia(recep, ctx.clinic)

      assert eventualmente(fn -> map_size(ApiWeb.Presence.list(observador)) == 2 end)

      # `leave/1` derruba o processo do canal, linkado ao do teste — sem o unlink o EXIT mata o
      # teste antes da asserção.
      Process.unlink(socket.channel_pid)
      leave(socket)

      assert eventualmente(fn -> map_size(ApiWeb.Presence.list(observador)) == 1 end),
             "a presença de quem saiu não sumiu"
    end

    test "a SEMANA não rastreia — senão uma pessoa apareceria em sete dias ao mesmo tempo" do
      ctx = fixture()

      socket = entrar_no_dia(ctx.owner, ctx.clinic, %{"mode" => "signal"})

      # Nada a esperar: o `after_join` nem é agendado. Uma janela curta é suficiente para pegar
      # um track que tivesse acontecido.
      refute eventualmente(fn -> map_size(ApiWeb.Presence.list(socket)) > 0 end, 5),
             "a visão que renderiza contagem não pode aparecer como 'vendo o dia'"
    end

    test "o tópico do MÊS não rastreia" do
      ctx = fixture()

      {:ok, _, socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(
          ApiWeb.AgendaChannel,
          "clinic:#{ctx.clinic.id}:agenda:month:2026-07"
        )

      refute eventualmente(fn -> map_size(ApiWeb.Presence.list(socket)) > 0 end, 5)
    end
  end
end
