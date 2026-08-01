defmodule ApiWeb.ChannelScope do
  @moduledoc """
  A guarda de `join` dos canais, numa definição só — o `ApiWeb.TenantScope` do WebSocket.

  Os três canais (agenda, fila, notificações) nasceram cada um com a sua cópia privada de
  `same_clinic/2` (byte-idêntica nos três) e da releitura do vínculo. É o **D7** do
  [doc 29](../../../../docs/29-auditoria-bate-volta-fila-de-espera.md) §5, e ele importa mais que
  uma duplicação comum: o WebSocket **não passa por plug nenhum** — nem `LoadScope`, nem RLS
  (R-D1, doc 28) —, então esta é a fronteira de autorização inteira daquele caminho. Três cópias
  de uma fronteira são três lugares onde a próxima correção pode não chegar.

  A guarda tem duas perguntas, nesta ordem:

    1. **o tópico é da mesma clínica do token?** O `clinic_id` do tópico vem do cliente; o do
       socket vem do token assinado. Sem esta comparação, uma sessão válida assinaria o tópico de
       qualquer clínica;
    2. **o vínculo ainda está ativo?** O token vive 15 min, e um acesso revogado nesse intervalo
       ainda traz token válido — por isso o vínculo é **relido do banco** a cada join, na mesma
       porta que o `LoadScope` usa no HTTP (`Api.Accounts.get_active_membership/3`).

  O que **não** mora aqui: o `parse_topic` de cada canal. O da agenda carrega resolução e data
  (`agenda:<clinic>:day:<iso>`) e não tem forma comum com os outros dois — `parse_topic/2` cobre
  só o caso simples `<prefixo><clinic_id>`, que é o dos outros dois.

  ## Uma query, não duas

  `scope_for/2` devolve um `Api.Scope` completo lendo o vínculo **com o usuário junto**
  (`load: [:user]`). Antes, quem precisava do nome (fila) ou do escopo (agenda) fazia duas idas ao
  banco por join; a caixa de notificações fazia uma só porque não precisava do usuário. Agora as
  três fazem uma.

  ## O teto de `join` mora aqui (doc 96, L-3)

  O transporte do socket é montado no `ApiWeb.Endpoint` **antes** do `plug ApiWeb.Router`, e os
  dois limitadores (`RateLimitGlobal`, `RateLimitAuth`) são plugs de *pipeline do router*. Logo,
  `join` não passava por teto nenhum — e cada join custa a query acima. Com um token válido (15
  min) dava para fazer `join`/`leave` em laço e gerar carga de banco sem estourar limite algum.

  O ponto certo para o teto é este: é por onde os três canais passam, e é antes da query. A chave é
  o **`user_id`** do socket (não o IP), porque o socket é sempre autenticado — o token é assinado, e
  há alguém a quem atribuir o consumo. O balde é o do `Api.RateLimiter.Global`, o mesmo do tráfego
  geral, com prefixo próprio para não dividir contagem com o HTTP.
  """

  require Logger

  alias Api.Accounts
  alias Api.RateLimiter
  alias Api.Scope
  alias ApiWeb.RateLimit

  # Um humano navegando gera join a cada troca de tópico — e o da agenda inclui o DIA
  # (`agenda:<clinic>:day:<iso>`), então clicar por um mês inteiro são ~30 joins. 120/min deixa
  # isso passar com folga e ainda corta um laço, que faz milhares.
  @join_limit 120
  @join_scale :timer.minutes(1)

  @doc """
  O `clinic_id` de um tópico `<prefixo><clinic_id>`.

      iex> ApiWeb.ChannelScope.parse_topic("notifications:abc", "notifications:")
      {:ok, "abc"}
      iex> ApiWeb.ChannelScope.parse_topic("notifications:", "notifications:")
      :invalid_topic
      iex> ApiWeb.ChannelScope.parse_topic("waitlist:abc", "notifications:")
      :invalid_topic
  """
  def parse_topic(topic, prefixo) when is_binary(topic) and is_binary(prefixo) do
    case topic do
      <<^prefixo::binary, clinic_id::binary>> when clinic_id != "" -> {:ok, clinic_id}
      _ -> :invalid_topic
    end
  end

  @doc """
  A guarda inteira: o tópico é desta clínica **e** o vínculo está ativo agora?

  Devolve o `Api.Scope` do assinante — que é o que o canal usa para recortar o que empurra
  (A7/`OwnAgendaOnly`) e para saber o nome de quem está na presença.
  """
  def authorize(clinic_id, socket) do
    with :ok <- same_clinic(clinic_id, socket),
         :ok <- dentro_do_teto(socket.assigns.user_id),
         {:ok, scope} <- scope_for(socket.assigns.user_id, clinic_id) do
      {:ok, scope}
    else
      _ -> :error
    end
  end

  # O teto de join — ver o moduledoc. Vem **antes** do `scope_for/2` de propósito: o que ele
  # protege é justamente a query que o `scope_for/2` faz.
  #
  # Gated por `RateLimit.enabled?(:global)` como os plugs de HTTP, pelo mesmo motivo: em dev e
  # teste o limite é no-op para não atrapalhar fluxo local, e o teste que o exercita liga a flag.
  defp dentro_do_teto(user_id) do
    if RateLimit.enabled?(:global) do
      case RateLimiter.Global.hit("join:user:" <> user_id, scale(), limite()) do
        {:allow, _count} ->
          :ok

        {:deny, retry_after_ms} ->
          # Mesma razão do log do 429 (doc 96, L-5): uma recusa sem rastro é indistinguível, para
          # quem investiga, de uma defesa que não existe. Aqui é ainda mais verdade — o canal
          # responde só `:error`, sem corpo e sem status.
          Logger.warning("rate limit: join de canal recusado",
            user_id: user_id,
            retry_after_s: max(1, ceil(retry_after_ms / 1000))
          )

          :error
      end
    else
      :ok
    end
  end

  defp limite, do: Keyword.get(config(), :join_limit, @join_limit)
  defp scale, do: Keyword.get(config(), :scale, @join_scale)
  defp config, do: Application.get_env(:api, :rate_limit_global, [])

  @doc "O tópico pedido é da mesma clínica do token do socket?"
  def same_clinic(clinic_id, %{assigns: %{clinic_id: clinic_id}}), do: :ok
  def same_clinic(_clinic_id, _socket), do: :error

  @doc """
  O escopo de quem assina, relido agora. `:error` se o vínculo não existe mais ou não está ativo.
  """
  def scope_for(user_id, clinic_id) do
    case Accounts.get_active_membership(user_id, clinic_id, authorize?: false, load: [:user]) do
      {:ok, %{user: %{} = user} = membership} -> {:ok, Scope.with_membership(user, membership)}
      _ -> :error
    end
  end
end
