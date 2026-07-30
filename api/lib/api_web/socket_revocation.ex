defmodule ApiWeb.SocketRevocation do
  @moduledoc """
  Derruba os WebSockets abertos de um usuário quando o vínculo dele muda ou some (S1, doc 30 §5).

  ## O buraco que isto fecha

  O `join` do canal relê o vínculo no banco — é o que impede quem já perdeu o acesso de **entrar**
  com um token ainda válido (o token vive 15 min). Mas a conexão **já aberta** não é reavaliada
  nunca mais: o escopo é resolvido uma vez, no join, e o processo do canal vive enquanto a aba
  viver. Revogado às 14h, o ex-membro seguia recebendo a agenda da clínica até fechar o navegador
  — a revogação valia no REST e não valia no tempo real.

  Phoenix resolve isso pelo identificador do socket (`ApiWeb.UserSocket.id/1`): um broadcast de
  `"disconnect"` naquele tópico encerra as conexões correspondentes. O cliente reconecta sozinho,
  e aí passa pelo `join` de novo — que agora nega. Nada aqui decide autorização; quem decide
  continua sendo o join.

  ## Por que também na mudança de papel

  Pelo mesmo motivo: o papel entra no escopo no join. Rebaixar um admin a `profissional` deixaria
  o recorte antigo (a clínica inteira) valendo pelo resto da conexão. Derrubar e deixar o join
  reavaliar é a única forma de o papel novo valer sem reimplementar a policy dentro do canal.

  ## Por que o alvo é o usuário, e não o par usuário×clínica

  O `id/1` do socket é por usuário (é o que permite o mesmo mecanismo servir ao sign-out). Um
  usuário com vínculo em duas clínicas perde as duas conexões quando perde **uma** — e reconecta
  em seguida, porque o join da outra clínica continua passando. Custo: um blip de reconexão em
  quem tem multi-clínica. O erro do outro lado (deixar a conexão errada viva) é o que se está
  consertando; este é o lado seguro de errar.

  Mora em `ApiWeb` porque a decisão é de transporte — quem sabe o que é socket é a fronteira. O
  recurso só o declara como notifier, e o notifier roda **depois do commit**: ninguém é derrubado
  por uma revogação que a transação ainda vai desfazer.
  """
  use Ash.Notifier

  # `accept_invite` é entrada, não perda de acesso — e derrubar o socket ali só provocaria uma
  # reconexão à toa no exato momento em que a pessoa acabou de ganhar acesso.
  @revogam [:revoke_access, :update]

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Api.Accounts.Membership,
        action: %{name: name},
        data: %{user_id: user_id}
      })
      when name in @revogam and is_binary(user_id) do
    ApiWeb.Endpoint.broadcast("user_socket:#{user_id}", "disconnect", %{})
    :ok
  end

  @impl true
  def notify(_notification), do: :ok
end
