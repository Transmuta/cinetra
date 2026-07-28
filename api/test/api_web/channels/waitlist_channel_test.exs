defmodule ApiWeb.WaitlistChannelTest do
  @moduledoc """
  O canal da fila (Entrega 5, D-E5.3). Protege, em ordem de gravidade:

    * **o `clinic_id` do tópico é validado no `join`** — o WebSocket não passa pela sessão nem
      pela RLS, então assinar a fila de outra clínica seria vazamento por fora de tudo;
    * o vínculo revogado depois do token emitido não entra (token vive 15 min);
    * uma mutação na fila empurra o sinal `waitlist_changed` (o cliente recarrega a lista).
  """
  use ApiWeb.ChannelCase, async: false

  alias Api.Accounts
  alias Api.Records
  alias Api.Waitlist

  defp fixture do
    owner = sign_in!(email_unico("wchan"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    paciente =
      Records.create_patient!("Paciente", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    {:ok, membership} = Accounts.get_active_membership(owner.id, clinic.id, authorize?: false)

    %{
      owner: owner,
      clinic: clinic,
      paciente: paciente,
      scope: Api.Scope.with_membership(owner, membership)
    }
  end

  defp socket_for(user, clinic) do
    Phoenix.ChannelTest.socket(ApiWeb.UserSocket, "user_socket:#{user.id}", %{
      user_id: user.id,
      clinic_id: clinic.id
    })
  end

  defp topic(clinic), do: "waitlist:#{clinic.id}"

  describe "join" do
    test "membro entra no tópico da própria clínica" do
      ctx = fixture()

      assert {:ok, _reply, _socket} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))
    end

    test "tópico de OUTRA clínica é recusado" do
      ctx = fixture()
      intruso = fixture()

      assert {:error, %{reason: "unauthorized"}} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(intruso.clinic))
    end

    test "tópico malformado é recusado" do
      ctx = fixture()

      assert {:error, %{reason: "invalid_topic"}} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, "waitlist:")
    end

    test "vínculo revogado depois do token emitido não entra" do
      ctx = fixture()
      {user, membership} = convite_aceito!(ctx.owner, ctx.clinic, :recepcao)
      :ok = Accounts.revoke_access(membership, actor: ctx.owner)

      assert {:error, %{reason: "unauthorized"}} =
               user
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))
    end
  end

  describe "sinal" do
    test "enfileirar empurra waitlist_changed" do
      ctx = fixture()

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      {:ok, _entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})

      assert_push "waitlist_changed", payload
      assert payload.change == "entry_upserted"
      assert payload.actor.id == ctx.owner.id
    end
  end

  # Doc 39: o aviso "alguém já está oferecendo esta vaga" é presença, não reserva. O que estes
  # testes travam é o que a reserva no banco fazia de errado — e que a presença não pode repetir:
  # não travar nada, e sumir sozinha quando a aba morre.
  describe "presença de oferta (doc 39)" do
    test "quem abre o modal aparece para os outros, com o nome do SERVIDOR" do
      ctx = fixture()
      {:ok, entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})

      {:ok, _, socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      # O cliente manda só o id do item; o nome NÃO viaja no corpo.
      ref = push(socket, "offering", %{"entry_id" => entry.id, "nome" => "Impostor"})
      assert_reply ref, :ok

      presencas = ApiWeb.Presence.list(socket)
      assert %{metas: [meta]} = presencas[entry.id]
      assert meta.nome == ctx.owner.nome
      refute meta.nome == "Impostor"
    end

    test "fechar o modal tira o aviso" do
      ctx = fixture()
      {:ok, entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})

      {:ok, _, socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      ref = push(socket, "offering", %{"entry_id" => entry.id})
      assert_reply ref, :ok
      assert map_size(ApiWeb.Presence.list(socket)) == 1

      ref = push(socket, "stopped_offering", %{"entry_id" => entry.id})
      assert_reply ref, :ok
      assert ApiWeb.Presence.list(socket) == %{}
    end

    # O que a reserva no banco NÃO fazia: sumir quando a pessoa some. Aqui a vaga não fica presa.
    test "a aba morre e o aviso morre junto" do
      ctx = fixture()
      {:ok, entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})

      {:ok, _, socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      ref = push(socket, "offering", %{"entry_id" => entry.id})
      assert_reply ref, :ok

      # Um segundo assinante, para observar a presença depois que o primeiro cair.
      {:ok, _, observador} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      assert map_size(ApiWeb.Presence.list(observador)) == 1

      # `leave/1` derruba o processo do canal, que é linkado ao do teste — sem o unlink, o EXIT
      # mata o teste antes da asserção (é a saída normal do canal, não uma falha).
      Process.unlink(socket.channel_pid)
      leave(socket)

      # A limpeza é assíncrona (o Presence propaga a saída pelo PubSub), então espera-se pela
      # CONDIÇÃO, não por um tempo fixo — teste que dorme é teste que fica intermitente.
      assert eventualmente(fn -> ApiWeb.Presence.list(observador) == %{} end),
             "o aviso não sumiu quando o socket caiu — é a vaga presa que o doc 39 removeu"
    end

    test "mensagem desconhecida não derruba o canal" do
      ctx = fixture()

      {:ok, _, socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.WaitlistChannel, topic(ctx.clinic))

      push(socket, "lixo", %{"foo" => "bar"})
      push(socket, "offering", %{})

      # Continua vivo e servindo: o sinal normal da fila ainda chega.
      {:ok, _} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})
      assert_push "waitlist_changed", %{change: "entry_upserted"}
    end
  end

  # Espera uma condição virar verdadeira (até ~1s). Existe porque a saída de um socket propaga
  # pelo PubSub e não é síncrona com o `leave/1`.
  defp eventualmente(fun, tentativas \\ 50) do
    cond do
      fun.() -> true
      tentativas == 0 -> false
      true -> Process.sleep(20) && eventualmente(fun, tentativas - 1)
    end
  end
end
