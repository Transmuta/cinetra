defmodule Api.Messaging.OptOutToken do
  @moduledoc """
  O token do link de descadastro que vai no rodapé de todo e-mail ao paciente (doc 52 §10).

  ## Por que existe, se já há o `ReplyToken`

  Porque são duas perguntas diferentes com duas validades diferentes, e misturá-las custa caro
  nas duas pontas:

    * o de resposta vale **30 dias** — depois que a sessão passou, "confirmar" não tem mais uso;
    * o de descadastro vale **um ano**, porque quem procura o link de sair costuma procurá-lo no
      e-mail mais antigo da caixa. Um "link expirado" nessa hora não faz a pessoa desistir de
      sair: faz ela marcar como spam, que é o mesmo opt-out com dano de reputação junto.

  Sal próprio pelo mesmo motivo que o resto: um token assinado para uma finalidade não deve valer
  para outra. Aqui a diferença é pequena (os dois nascem do mesmo `message_id` e vão para a mesma
  pessoa), mas a regra é barata de seguir e cara de reintroduzir depois.

  ## O que ele carrega, e o que ele NÃO faz

  Só o `message_id`. Canal, destino e clínica são relidos do banco a partir dele — é o mesmo
  desenho do `Api.Messaging.ReplyToken`, e pela mesma razão: o que está na URL pode ser
  encaminhado, então nada de identificável viaja nela.

  **Abrir o link não descadastra.** O GET só mostra a página; quem registra é o POST do botão.
  Não é cerimônia: antivírus corporativo e o próprio pré-carregamento do webmail *visitam* todo
  link do e-mail. Com efeito no GET, um paciente seria descadastrado por um scanner que ele nunca
  viu — e o sintoma seria "a clínica parou de me avisar", meses depois, sem ninguém entender.
  """
  @salt "patient opt-out"
  @max_age 60 * 60 * 24 * 365

  @doc """
  Assina o token de descadastro de uma mensagem.

  `opts` vai para `Phoenix.Token.sign/4` — o teste usa `:signed_at` para produzir um token
  vencido sem esperar um ano.
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
  A URL que o paciente abre. Aponta para o **web** (BFF), como o link de resposta e o magic
  link — ADR-005: a página que o paciente vê é do SvelteKit, e é ela que chama a API.
  """
  def url(message_id) when is_binary(message_id) do
    Api.web_app_url() <> "/descadastrar/" <> sign(message_id)
  end
end
