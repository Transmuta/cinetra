defmodule Api.ObanPoolTest do
  @moduledoc """
  O **D-R** (doc 30, agravado na Onda 4 — doc 45 §4): o pool do banco contra a concorrência das
  filas do Oban.

  A relação existe e nada no projeto a expressava. Um job em execução **segura uma conexão do
  mesmo pool** que atende HTTP e WebSocket, e os jobs deste projeto são ligados ao banco de ponta
  a ponta (materialização de série, fan-out do sino, podas). Então a soma dos limites das filas é
  um **piso** de conexões que pode estar indisponível para atender gente — e ninguém percebia,
  porque as duas configurações moram em arquivos diferentes (`config.exs` e `runtime.exs`) e nunca
  se olharam.

  Este teste é o olhar. Ele não mede carga: ele **trava a aritmética**, de modo que subir o limite
  de uma fila (ou criar uma fila nova) sem revisitar o `POOL_SIZE` fique vermelho aqui, com o
  número na mensagem.

  O que foi medido para escolher a margem (`pg_stat_activity` no dev, `pool_size: 10`):

    * 11 conexões abertas — 10 do pool + **1** do `LISTEN "public.oban_insert"`, o notifier do
      Oban, que fica **fora** do pool. Ela não disputa checkout, mas conta no `max_connections`
      do servidor;
    * as 10 do pool ficam `idle` em `COMMIT` — o pool as mantém abertas, não abre sob demanda.
  """
  use ExUnit.Case, async: true

  # Quantas conexões o HTTP/WS precisa ter garantidas mesmo com todas as filas cheias. É escolha
  # humana, não medição: é a folga que separa "o sino atrasa" de "a tela não abre".
  @minimo_para_atender 8

  defp limites_das_filas, do: Application.get_env(:api, Oban)[:queues]

  test "a soma dos limites das filas é a que o POOL_SIZE de produção foi dimensionado para" do
    soma = limites_das_filas() |> Keyword.values() |> Enum.sum()

    assert soma == 7, """
    A concorrência total das filas do Oban mudou (#{inspect(limites_das_filas())} soma #{soma}).

    Isto NÃO é um erro — é o alarme do D-R. Cada job em execução segura uma conexão do pool que
    também atende HTTP e WebSocket. Revisite o `POOL_SIZE` em `config/runtime.exs`, que hoje é
    16 = #{soma} (filas) + #{@minimo_para_atender} (HTTP/WS) + 1 (stager/plugins do Oban), e
    atualize este número junto.
    """
  end

  test "nenhuma fila sozinha pode consumir o pool inteiro" do
    for {fila, limite} <- limites_das_filas() do
      assert limite < @minimo_para_atender,
             "a fila #{fila} aceita #{limite} jobs simultâneos — sozinha ela já engole a folga do HTTP"
    end
  end
end
