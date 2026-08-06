defmodule Api.Messaging.ReplyToken do
  @moduledoc """
  O token do link pelo qual o paciente responde (doc 52 §5).

  ## Por que link, e não "responda esta mensagem"

  Porque é **canal-agnóstico**: o mesmo token vai no corpo do e-mail (fase 1) e no botão do
  template HSM (fase 2), e nos dois casos identifica exatamente qual presença de qual clínica. A
  alternativa — interpretar texto livre — é adivinhação com consequência na agenda, e no número
  compartilhado da v1 (§9.1) a frase do paciente nem sequer diz de qual clínica ele fala.

  ## O que ele NÃO é

  Não abre sessão, não é credencial e não dá acesso a nada além de responder **uma** mensagem.
  Carrega só o `message_id`: quem é o paciente, qual a sessão e qual a clínica são relidos do
  banco a partir dele. Um token vazado permite responder por alguém — não ler ficha, não ver
  agenda, não entrar no sistema.

  ## Validade

  30 dias. Longo para um token de sessão e curto para o histórico: o paciente pode abrir o e-mail
  uma semana depois, e depois da sessão passar a resposta não tem mais uso. Vencido devolve
  `{:error, :expired}`, que a tela traduz em "este link expirou" — não em erro técnico.

  Assinado, não cifrado (diferente do magic link, que é `Plug.Crypto.encrypt`): aqui não há
  segredo dentro do token. Um `message_id` visível na URL não conta nada a quem já tem a URL.
  """
  @salt "patient reply"
  @max_age 60 * 60 * 24 * 30

  @doc """
  Assina o token de resposta de uma mensagem.

  `opts` vai para `Phoenix.Token.sign/4` — o teste usa `:signed_at` para produzir um token
  vencido sem esperar trinta dias.
  """
  def sign(message_id, opts \\ []) when is_binary(message_id) do
    Phoenix.Token.sign(ApiWeb.Endpoint, @salt, %{message_id: message_id}, opts)
  end

  @doc "Verifica e devolve `{:ok, message_id}` ou `{:error, :expired | :invalid | :missing}`."
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(ApiWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{message_id: id}} -> {:ok, id}
      {:error, :expired} -> {:error, :expired}
      _ -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :missing}

  @doc """
  A URL que o paciente abre. Aponta para o **web** (BFF), não para a API — ADR-005, a mesma
  escolha do magic link: a página que o paciente vê é do SvelteKit, e é ela que chama a API.
  """
  def url(message_id) when is_binary(message_id) do
    Api.web_app_url() <> "/confirmar/" <> sign(message_id)
  end
end
