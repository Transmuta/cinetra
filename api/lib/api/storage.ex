defmodule Api.Storage do
  @moduledoc """
  A porta de object storage — anexos de paciente vivem em bucket **privado** compatível com S3
  (Cloudflare R2, ADR-008), nunca no Postgres e nunca em disco do container.

  ## Por que existe uma porta, e não chamadas diretas ao R2

  Duas razões concretas, nenhuma delas "arquitetura por arquitetura":

    1. **A suíte não pode falar com bucket de verdade.** Sem porta, todo teste de anexo viraria
       teste de integração com rede, credencial e latência — e o gate de cobertura passaria a
       depender do Cloudflare estar de pé. `Api.Storage.Memory` (em `test/support/`) responde às
       mesmas cinco chamadas guardando os bytes num Agent.
    2. **O provedor é decisão revisável.** O ADR-008 aceita Tigris ou R2; a jurisdição
       ([`05 §9`](../../../docs/05-observabilidade-e-producao.md)) pode obrigar a trocar. Trocar
       de adaptador é uma linha de config; trocar chamadas espalhadas é uma fatia.

  ## Seis operações, e por que não mais

  `presign_put` e `presign_get` são as que o browser usa (os bytes **não** passam pelo BFF nem
  pelo BEAM — [`05 §5.5`](../../../docs/05-observabilidade-e-producao.md)). `head`, `get_range` e
  `delete` são do servidor: conferir tamanho real, farejar magic bytes e apagar.

  `put` é a exceção deliberada ao "os bytes não passam pelo BEAM": o avatar do Google
  (`Api.Accounts.AvatarSyncJob`) não tem browser do outro lado — os bytes vêm de
  `googleusercontent.com` para o servidor, e é o servidor que os guarda. Ela não substitui
  `presign_put` para o que o usuário sobe: um anexo de 50 MB atravessando o BEAM seria memória e
  latência sem nenhum ganho.

  **Não há `list`.** Seria necessária para varrer objeto órfão (objeto sem linha), mas o desenho
  torna esse órfão impossível: a linha nasce **antes** do objeto, e a remoção apaga **primeiro o
  objeto**, só então a linha (`Api.Records.delete_attachment/2`). Se o `delete` do bucket falhar,
  a linha fica e o usuário repete — o que sobra é sempre linha-sem-objeto, que é visível pelo
  banco e podada por `Api.Housekeeping.PruneAttachments`. Objeto invisível guardando laudo seria
  o pior dos dois mundos; este desenho o exclui em vez de o caçar.
  """

  @typedoc "Caminho do objeto no bucket. Nunca contém nome escolhido pelo usuário."
  @type key :: String.t()

  @doc "URL de `PUT` assinada, com o tipo e o tamanho declarados **dentro** da assinatura."
  @callback presign_put(key(), content_type :: String.t(), bytes :: pos_integer(), keyword()) ::
              {:ok,
               %{url: String.t(), headers: %{String.t() => String.t()}, expira_em: pos_integer()}}
              | {:error, term()}

  @doc "URL de `GET` assinada, já com `Content-Disposition`/`Content-Type` na query assinada."
  @callback presign_get(key(), nome_exibicao :: String.t(), content_type :: String.t(), keyword()) ::
              {:ok, %{url: String.t(), expira_em: pos_integer()}} | {:error, term()}

  @doc """
  Escreve bytes numa chave, direto do servidor.

  Só para conteúdo que o **servidor** buscou (avatar do Google). O que o usuário sobe continua
  indo por `presign_put`.
  """
  @callback put(key(), content_type :: String.t(), body :: binary()) :: :ok | {:error, term()}

  @doc "Tamanho real do objeto no bucket, para conferir contra o declarado."
  @callback head(key()) :: {:ok, %{bytes: non_neg_integer()}} | {:error, :not_found | term()}

  @doc "Os primeiros bytes do objeto — o suficiente para farejar a assinatura do formato."
  @callback get_range(key(), first :: non_neg_integer(), last :: non_neg_integer()) ::
              {:ok, binary()} | {:error, :not_found | term()}

  @doc "Apaga o objeto. Idempotente: chave inexistente é `:ok`, não erro."
  @callback delete(key()) :: :ok | {:error, term()}

  @doc """
  Há credencial de storage configurada?

  A fatia inteira depende disso, e o modo de falha sem a checagem é ruim: a tela ofereceria o
  campo de upload e o erro só apareceria depois de o usuário escolher o arquivo. Com ela, o
  controller devolve 503 e a tela diz que o storage não está configurado.
  """
  def configured? do
    config = config()

    Enum.all?([:account_id, :bucket, :access_key_id, :secret_access_key], fn chave ->
      is_binary(config[chave]) and config[chave] != ""
    end)
  end

  @doc "O adaptador ativo (R2 em dev/prod, `Api.Storage.Memory` em teste)."
  def adapter, do: Keyword.get(config(), :adapter, Api.Storage.R2)

  @doc "Config bruta de `config :api, Api.Storage`."
  def config, do: Application.get_env(:api, __MODULE__, [])

  # ---- fachada: é por aqui que o resto do sistema fala com o storage ----

  def presign_put(key, content_type, bytes, opts \\ []),
    do: adapter().presign_put(key, content_type, bytes, opts)

  def presign_get(key, nome, content_type, opts \\ []),
    do: adapter().presign_get(key, nome, content_type, opts)

  def put(key, content_type, body), do: adapter().put(key, content_type, body)

  def head(key), do: adapter().head(key)
  def get_range(key, first, last), do: adapter().get_range(key, first, last)
  def delete(key), do: adapter().delete(key)
end
