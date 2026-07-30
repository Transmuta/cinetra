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
  """

  alias Api.Accounts
  alias Api.Scope

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
         {:ok, scope} <- scope_for(socket.assigns.user_id, clinic_id) do
      {:ok, scope}
    else
      _ -> :error
    end
  end

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
