defmodule Api.Accounts.AvatarSyncJobTest do
  @moduledoc """
  O job que busca a foto do Google e a guarda no bucket. Sem rede (o `Req.Test` responde no
  lugar do `googleusercontent.com`) e sem Cloudflare (`Api.Storage.Memory`).

  O que estes testes cravam, além do caminho feliz: **falha de conteúdo não retenta** (bytes que
  não são imagem, imagem grande demais, 404 do Google são `{:cancel, _}`) e **falha de rede
  retenta** (500 e timeout são `{:error, _}`). A distinção é o que impede um job condenado de
  ocupar a fila três vezes — e o que impede uma indisponibilidade momentânea de custar a foto.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Accounts
  alias Api.Accounts.AvatarSyncJob
  alias Api.Accounts.User.Avatar
  alias Api.Storage.Memory

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 13, "IHDR">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0>>
  @url "https://lh3.googleusercontent.com/a/ACg8ocK=s96-c"

  setup do
    Memory.limpar()
    :ok
  end

  defp usuario do
    email = "google-#{System.unique_integer([:positive])}@example.com"
    Accounts.register_user!("Ana Souza", email, authorize?: false)
  end

  defp responder(fun), do: Req.Test.stub(AvatarSyncJob, fun)

  defp rodar(user, url \\ @url) do
    AvatarSyncJob.perform(%Oban.Job{args: %{"user_id" => user.id, "url" => url}})
  end

  describe "caminho feliz" do
    test "baixa a foto, guarda no bucket e grava a chave no usuário" do
      user = usuario()
      responder(fn conn -> Req.Test.text(conn, @png) end)

      assert :ok = rodar(user)

      chave = Avatar.chave(user.id, "image/png")
      assert chave in Memory.chaves()

      atualizado = Accounts.get_user!(user.id, authorize?: false)
      assert atualizado.avatar_key == chave
      assert atualizado.avatar_origem == @url
    end

    test "a foto trocar de formato apaga o objeto antigo — sem órfão no bucket" do
      # O mesmo desenho de `Api.Storage` (que por isso não tem `list`): objeto que nenhuma linha
      # aponta é invisível ao sistema. Aqui ele apareceria calado, porque a chave leva a extensão
      # e o Google serve PNG ou JPEG conforme a origem da foto.
      user = usuario()
      responder(fn conn -> Req.Test.text(conn, @png) end)
      assert :ok = rodar(user)

      user = Accounts.get_user!(user.id, authorize?: false)
      responder(fn conn -> Req.Test.text(conn, @jpeg) end)
      assert :ok = rodar(user, @url <> "2")

      assert Memory.chaves() == [Avatar.chave(user.id, "image/jpeg")]
    end
  end

  describe "o que não vira avatar (e não retenta)" do
    test "bytes que não são imagem" do
      user = usuario()
      responder(fn conn -> Req.Test.text(conn, "<!doctype html><script>alert(1)</script>") end)

      assert {:cancel, _} = rodar(user)
      assert Memory.chaves() == []

      # Recusa permanente carimba a ORIGEM sem chave: é o que diz "esta conta já passou pela
      # busca". Sem o carimbo, o gatilho do `SyncGoogleAvatar` (as duas colunas nulas) continuaria
      # verdadeiro e a conta baixaria a mesma foto recusada a cada login, para sempre.
      atualizado = Accounts.get_user!(user.id, authorize?: false)
      assert atualizado.avatar_key == nil
      assert atualizado.avatar_origem == @url
    end

    test "imagem acima do teto" do
      user = usuario()
      gigante = @png <> :binary.copy("x", Avatar.max_bytes() * 2)
      responder(fn conn -> Req.Test.text(conn, gigante) end)

      assert {:cancel, _} = rodar(user)
      assert Memory.chaves() == []
    end

    test "404 do Google (a foto sumiu de lá)" do
      user = usuario()
      responder(fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:cancel, _} = rodar(user)
    end

    test "URL fora da allowlist nem chega a discar" do
      user = usuario()
      responder(fn _conn -> flunk("não devia ter feito requisição") end)

      assert {:cancel, _} = rodar(user, "http://169.254.169.254/latest/meta-data/")
    end

    test "usuário que não existe mais" do
      responder(fn _conn -> flunk("não devia ter feito requisição") end)

      assert {:cancel, _} =
               AvatarSyncJob.perform(%Oban.Job{
                 args: %{"user_id" => Ash.UUID.generate(), "url" => @url}
               })
    end

    test "sem storage configurado a fatia inteira fica desligada" do
      user = usuario()
      config = Application.get_env(:api, Api.Storage)
      Application.put_env(:api, Api.Storage, Keyword.put(config, :bucket, ""))
      on_exit(fn -> Application.put_env(:api, Api.Storage, config) end)

      responder(fn _conn -> flunk("não devia ter feito requisição") end)

      assert {:cancel, _} = rodar(user)
    end
  end

  describe "o que retenta" do
    test "500 do Google" do
      user = usuario()
      responder(fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, _} = rodar(user)
      assert Memory.chaves() == []

      # E NÃO carimba a origem: aqui quem decide desistir é o Oban (`max_attempts`), não este
      # caminho. Carimbar marcaria a conta como "já processada" por causa de um 500 momentâneo.
      assert Accounts.get_user!(user.id, authorize?: false).avatar_origem == nil
    end

    test "falha de transporte" do
      user = usuario()
      responder(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, _} = rodar(user)
    end
  end

  describe "coletor/1 — o teto vale sobre o que entra na memória" do
    # O teste do job acima prova a **recusa**; este prova a **parada**. Os dois são necessários
    # porque o `Req.Test` entrega o corpo inteiro numa chamada só: é contra o adaptador real
    # (Finch, que streama) que parar no meio importa, e ali nenhum teste da suíte chega.
    test "continua enquanto cabe e para no pedaço que estoura" do
      coletor = AvatarSyncJob.coletor(10)
      resp = %Req.Response{status: 200, body: ""}

      assert {:cont, {:req, %{body: "12345"}}} = coletor.({:data, "12345"}, {:req, resp})

      assert {:halt, {:req, %{body: corpo}}} =
               coletor.({:data, :binary.copy("x", 11)}, {:req, resp})

      assert byte_size(corpo) == 11
    end
  end

  describe "enqueue/2" do
    test "enfileira com o id do usuário e a URL da foto" do
      user = usuario()

      assert {:ok, %Oban.Job{}} = AvatarSyncJob.enqueue(user, @url)

      assert_enqueued(worker: AvatarSyncJob, args: %{"user_id" => user.id, "url" => @url})
    end
  end
end
