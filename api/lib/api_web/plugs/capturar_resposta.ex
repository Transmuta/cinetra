defmodule ApiWeb.Plugs.CapturarResposta do
  @moduledoc """
  Guarda o corpo da resposta das requisições **recusadas**, para o `ApiWeb.RequestLogger` logá-lo.

  ## Por que um plug, e não uma leitura no handler de telemetria

  Porque quando `[:phoenix, :endpoint, :stop]` dispara, `conn.resp_body` **já é `nil`**. O adapter
  do Bandit devolve `{:ok, nil, adapter}` depois de enviar (`Bandit.Adapter.send_resp/4`), e o
  `Plug.Conn.send_resp/1` escreve esse `nil` de volta na conn — de propósito, para não reter o
  corpo em memória depois que ele já saiu pela rede.

  `register_before_send/2` é a única janela em que o corpo ainda existe **e** o status final já
  está decidido. Daí o plug.

  ## Só 4xx e 5xx (ADR-025)

  O corpo do caminho feliz não é guardado, e isso é metade da decisão: um GET de agenda devolve
  dezenas de KB, e retê-los em toda requisição seria custo de memória por requisição **mais**
  volume de log por uma ordem de grandeza — sem contar que poria dado de paciente de toda operação
  bem-sucedida no Loki.
  """

  @behaviour Plug

  @chave :resposta_capturada

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &guardar/1)
  end

  @doc "O corpo guardado, ou `nil` se a requisição não passou pelo plug ou não falhou."
  @spec corpo(Plug.Conn.t()) :: iodata() | nil
  def corpo(%Plug.Conn{private: private}), do: Map.get(private, @chave)

  defp guardar(%Plug.Conn{status: status, resp_body: corpo} = conn)
       when is_integer(status) and status >= 400 and not is_nil(corpo) do
    Plug.Conn.put_private(conn, @chave, corpo)
  end

  defp guardar(conn), do: conn
end
