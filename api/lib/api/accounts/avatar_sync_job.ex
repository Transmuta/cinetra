defmodule Api.Accounts.AvatarSyncJob do
  @moduledoc """
  Busca a foto de perfil do Google e a guarda no **nosso** bucket (R2), fora do request de login.

  Enfileirado por `Api.Accounts.User.Changes.SyncGoogleAvatar` **uma vez por conta**, na primeira
  vez que ela aparece com um `picture` — ver lá o porquê de ser job e não parte do login, e por
  que trocar a foto no Google depois disso não repropaga.

  ## Por que copiar a foto, e não guardar o link do Google

  Guardar a URL seria uma coluna e nenhum job. O que ela custaria:

    * **o browser do usuário passaria a discar para o Google** em toda tela que mostra o avatar.
      A CSP teria de abrir `googleusercontent.com` no `img-src`, e o Google ganharia um sinal de
      quem usa o app e quando — num sistema de clínica, isso é telemetria de terceiro em cima de
      contexto de saúde ([`06`](../../../docs/06-seguranca-e-lgpd.md));
    * **o link morre** quando a pessoa troca a foto lá, e o app fica com avatar quebrado até o
      próximo login;
    * o dado deixaria de ser nosso: o dia em que o Google mudar a regra de acesso a essas URLs,
      a tela muda junto.

  Copiar custa um `GET` por foto nova. É o mesmo desenho do anexo: os bytes que o produto mostra
  moram no bucket do produto.

  ## Fila `notifications`

  Não porque seja notificação, mas pelo mesmo critério do `SendJob`: o que não pode acontecer é a
  foto ficar atrás de uma poda que varre clínica a clínica por minutos. `housekeeping` é a fila
  do trabalho em lote; esta é a do trabalho que alguém está esperando ver.

  ## Retentar, ou não

  A distinção que este job faz é a que separa "não vai dar certo nunca" de "não deu certo agora":

    * `{:cancel, _}` — bytes que não são imagem da allowlist, imagem acima do teto, 4xx do
      Google, usuário que sumiu, storage desligado. Repetir daria o mesmo resultado três vezes.
    * `{:error, _}` — 5xx e falha de transporte. `max_attempts: 3` com o backoff do Oban.

  Em ambos os casos o usuário continua com o avatar de iniciais: a foto é enfeite, e nada aqui
  pode custar o login.

  ## `unique`

  Duas abas fazendo o primeiro login ao mesmo tempo enfileiram o mesmo trabalho duas vezes — a
  guarda de "esta conta já passou pela busca" só vira falsa depois que o primeiro job gravou.
  Cinco minutos de janela de unicidade sobre (worker, args) resolvem sem estado nosso.
  """
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker, :args], states: :incomplete]

  require Logger

  alias Api.Accounts
  alias Api.Accounts.User.Avatar

  # O download é de uma imagem de ~10 KB num CDN. 10 s é folga para conexão ruim e curto o
  # bastante para não segurar um slot da fila enquanto o outro lado não responde.
  @timeout 10_000

  @doc "Enfileira a busca da foto. Best-effort: falhar aqui não pode custar o login."
  def enqueue(%{id: user_id}, url) when is_binary(url) do
    %{"user_id" => user_id, "url" => url}
    |> new(Api.Correlacao.opts())
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "url" => url}}) do
    cond do
      not Api.Storage.configured?() ->
        {:cancel, "storage não configurado"}

      # A allowlist é reconferida aqui, e não só na hora de enfileirar: entre o `INSERT` do job e
      # a execução dele passa a fila inteira, e quem lê `args` é este `GET`. Uma regra de SSRF
      # que só existe no produtor é uma regra que some quando alguém enfileirar de outro lugar.
      not Avatar.origem_valida?(url) ->
        {:cancel, "origem não permitida"}

      true ->
        sincronizar(user_id, url)
    end
  end

  # ---- interno ----

  defp sincronizar(user_id, url) do
    case Accounts.get_user(user_id, authorize?: false) do
      {:ok, user} -> guardar(user, url)
      # A conta sumiu entre o login e o job. Não é falha a repetir.
      {:error, _} -> {:cancel, "usuário não encontrado"}
    end
  end

  defp guardar(user, url) do
    with {:ok, corpo} <- baixar(url),
         {:ok, tipo} <- Avatar.conferir(corpo),
         chave = Avatar.chave(user.id, tipo),
         :ok <- Api.Storage.put(chave, tipo, corpo) do
      gravar(user, chave, url)
    else
      {:error, motivo} when motivo in [:tipo_nao_aceito, :arquivo_grande_demais] ->
        # Sem a URL no log: ela identifica a conta do Google da pessoa.
        Logger.warning("avatar: foto recusada (#{motivo})")
        recusar(user, url)
        {:cancel, to_string(motivo)}

      {:error, {:http, status}} when status in 400..499 ->
        recusar(user, url)
        {:cancel, "google respondeu #{status}"}

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  # Recusa **permanente** carimba a origem sem chave: é o que diz "esta conta já passou pela busca
  # e não vai passar de novo".
  #
  # Sem o carimbo, o gatilho de `SyncGoogleAvatar` ("as duas colunas nulas") continuaria verdadeiro
  # e a conta cujo Google serve algo que não aceitamos enfileiraria um download **a cada login**,
  # para sempre — o trabalho recorrente que a decisão de sincronizar só no cadastro existe para
  # não ter. A chave atual é preservada (não há uma neste caminho, mas escrever `nil` aqui seria
  # uma foto boa apagada por uma recusa futura).
  #
  # Falha transitória (5xx, rede) NÃO carimba: ali o Oban retenta, e carimbar desistiria por ele.
  defp recusar(user, url) do
    _ =
      Accounts.set_user_avatar(user, %{avatar_key: user.avatar_key, avatar_origem: url},
        authorize?: false
      )

    :ok
  end

  defp gravar(user, chave, url) do
    anterior = user.avatar_key

    {:ok, _atualizado} =
      Accounts.set_user_avatar(user, %{avatar_key: chave, avatar_origem: url}, authorize?: false)

    # Chave anterior diferente = objeto antigo sem nenhuma linha apontando para ele. Com o sync
    # só no cadastro isto não acontece pelo caminho normal (não há segunda busca), e é justamente
    # por isso que fica: quem reprocessar uma conta à mão — limpando as colunas, ou quando o
    # upload de foto pelo próprio usuário existir — muda a extensão (`avatar.png` → `avatar.jpg`)
    # e deixaria o órfão. Depois do `UPDATE`, de propósito: o que pode sobrar é objeto sem uso
    # (visível, e sobrescrito no próximo sync), nunca linha apontando para objeto apagado.
    if is_binary(anterior) and anterior != chave do
      _ = Api.Storage.delete(anterior)
    end

    :ok
  end

  # `into:` em vez de baixar tudo e medir depois: o teto tem de valer sobre o que **entra na
  # memória** do job, não sobre o que já entrou. Um corpo de 2 GB derrubaria o nó muito antes de
  # `Avatar.conferir/1` ter chance de recusá-lo.
  #
  # `redirect: false` é a outra metade da allowlist de host: sem isso, `googleusercontent.com`
  # responderia `302` para onde quisesse e o `GET` seguiria — a checagem de origem valeria só
  # para o primeiro salto, que é o mesmo que não valer.
  defp baixar(url) do
    teto = Avatar.max_bytes()

    opcoes = [
      method: :get,
      url: url,
      decode_body: false,
      redirect: false,
      retry: false,
      receive_timeout: @timeout,
      into: coletor(teto)
    ]

    case Req.request(Keyword.merge(opcoes, plug_de_teste())) do
      {:ok, %{status: status, body: corpo}} when status in 200..299 -> {:ok, to_binario(corpo)}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, motivo} -> {:error, motivo}
    end
  end

  @doc """
  O coletor do corpo: acumula os pedaços e **para** no primeiro que estoura o teto.

  Público (e não uma anônima dentro de `baixar/1`) porque é a única parte do download que dá para
  provar sem rede: com o `Req.Test`, o corpo inteiro chega numa chamada só, então o teste do job
  prova a *recusa*, não a *parada*. É contra o adaptador real que a parada importa, e é aqui que
  ela se exercita.
  """
  def coletor(teto) do
    fn {:data, dado}, {req, resp} ->
      corpo = (resp.body || "") <> dado
      resp = %{resp | body: corpo}

      if byte_size(corpo) > teto, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
    end
  end

  # Com `into:`, o corpo pode chegar como iodata dependendo do adaptador.
  defp to_binario(corpo) when is_binary(corpo), do: corpo
  defp to_binario(corpo) when is_list(corpo), do: IO.iodata_to_binary(corpo)
  defp to_binario(nil), do: ""

  # `:plug` só existe em teste (`Req.Test`) — mesmo recurso do `Api.Messaging.Zernio`: é o que
  # permite exercitar ESTE módulo (o que ele aceita, o que recusa, o que retenta) sem rede.
  defp plug_de_teste do
    case Application.get_env(:api, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
