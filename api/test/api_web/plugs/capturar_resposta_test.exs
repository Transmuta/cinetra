defmodule ApiWeb.Plugs.CapturarRespostaTest do
  @moduledoc """
  A janela única para ver o corpo da resposta.

  Quando o evento `[:phoenix, :endpoint, :stop]` dispara, `conn.resp_body` **já é `nil`**: o
  adapter do Bandit devolve `{:ok, nil, adapter}` depois de enviar, justamente para não reter o
  corpo em memória. Logo, quem quiser a resposta tem de pegá-la ANTES do envio — é o que
  `register_before_send/2` faz, e é a razão de este plug existir em vez de o `RequestLogger`
  simplesmente ler o campo.
  """

  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ApiWeb.Plugs.CapturarResposta

  defp responder(status, corpo) do
    :get
    |> conn("/api/x")
    |> CapturarResposta.call(CapturarResposta.init([]))
    |> resp(status, corpo)
    |> send_resp()
  end

  test "guarda o corpo quando a requisição falhou" do
    conn = responder(422, ~s({"errors":[{"field":"cpf"}]}))

    assert CapturarResposta.corpo(conn) == ~s({"errors":[{"field":"cpf"}]})
  end

  test "guarda também em 5xx" do
    conn = responder(500, ~s({"error":"boom"}))

    assert CapturarResposta.corpo(conn) == ~s({"error":"boom"})
  end

  test "NÃO guarda quando a requisição deu certo" do
    # O escopo decidido no ADR-025 é 4xx/5xx. Reter o corpo de todo 200 seria o custo de memória
    # e de volume que a decisão evitou de propósito — a agenda devolve dezenas de KB por request.
    conn = responder(200, ~s({"appointments":[]}))

    assert CapturarResposta.corpo(conn) == nil
  end

  test "o corpo continua sendo enviado ao cliente, intacto" do
    # O plug mexe numa resposta em trânsito; um erro aqui não seria log ruim, seria resposta
    # corrompida.
    conn = responder(422, ~s({"errors":[]}))

    assert conn.status == 422
    assert conn.state == :sent
  end

  test "requisição sem o plug não quebra o leitor" do
    conn = :get |> conn("/api/x") |> resp(422, "x") |> send_resp()

    assert CapturarResposta.corpo(conn) == nil
  end
end
