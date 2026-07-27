defmodule Api.Storage.Memory do
  @moduledoc """
  Adaptador de `Api.Storage` em memória — o storage da suíte.

  Existe para a mesma pergunta que todo teste de anexo faz ("o que acontece quando o objeto
  tem 60 MB?", "e quando os magic bytes não batem com o tipo declarado?") poder ser respondida
  sem rede, sem credencial e sem o Cloudflare de pé. Guarda os objetos num `Agent` nomeado,
  iniciado pelo `test_helper.exs`.

  `subir/3` é o que o teste chama no lugar do `PUT` do browser: o servidor nunca vê esses bytes
  em produção, então não há função de produção para reaproveitar aqui.
  """

  @behaviour Api.Storage

  @agente __MODULE__

  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{objetos: %{}, chamadas: []} end, name: @agente)

  @doc """
  A sequência de operações desde o último `limpar/0`, na ordem em que aconteceram.

  Existe para uma asserção que nada mais alcança: **a poda não pode falar com o storage de dentro
  da transação** (`Api.Housekeeping.PruneAttachments`). No sandbox de teste tudo roda dentro de
  uma transação, então `Repo.in_transaction?/0` responde `true` sempre e não serve de prova. O que
  ainda distingue as duas versões é a **ordem**: agrupada (lê tudo → apaga os objetos → apaga as
  linhas) contra intercalada (lê → apaga objeto → apaga linha → lê o próximo).
  """
  def chamadas, do: Agent.get(@agente, & &1.chamadas) |> Enum.reverse()

  defp registrar(op, key) do
    Agent.update(@agente, &Map.update!(&1, :chamadas, fn c -> [{op, key} | c] end))
  end

  @doc "O que o browser faria: põe bytes numa chave. Só teste chama."
  def subir(key, content_type, bytes) when is_binary(bytes) do
    Agent.update(
      @agente,
      &put_in(&1.objetos[key], %{content_type: content_type, bytes: bytes})
    )
  end

  @doc "Todas as chaves guardadas — para o teste provar que a remoção apagou o objeto também."
  def chaves, do: Agent.get(@agente, &Map.keys(&1.objetos))

  @doc "Esvazia entre testes."
  def limpar, do: Agent.update(@agente, fn _ -> %{objetos: %{}, chamadas: []} end)

  @impl true
  def presign_put(key, content_type, _bytes, _opts) do
    # A forma é EXATAMENTE a do behaviour `Api.Storage` — nada a mais. Um adaptador de teste que
    # devolve chave extra ensina o chamador a depender de algo que o adaptador de produção não dá.
    {:ok,
     %{
       url: "https://memoria.test/#{key}?put",
       headers: %{"content-type" => content_type},
       expira_em: 600
     }}
  end

  @impl true
  def presign_get(key, nome, content_type, opts) do
    disposicao = Keyword.get(opts, :disposition, :inline)

    {:ok,
     %{
       url:
         "https://memoria.test/#{key}?get&nome=#{URI.encode(nome)}" <>
           "&tipo=#{URI.encode(content_type)}&disposicao=#{disposicao}",
       expira_em: 300
     }}
  end

  @impl true
  def head(key) do
    registrar(:head, key)

    case objeto(key) do
      nil -> {:error, :not_found}
      %{bytes: bytes} -> {:ok, %{bytes: byte_size(bytes)}}
    end
  end

  @impl true
  def get_range(key, first, last) do
    registrar(:get_range, key)

    case objeto(key) do
      nil ->
        {:error, :not_found}

      %{bytes: bytes} ->
        {:ok, binary_part(bytes, first, min(last - first + 1, byte_size(bytes) - first))}
    end
  end

  @impl true
  def delete(key) do
    registrar(:delete, key)
    Agent.update(@agente, &Map.update!(&1, :objetos, fn o -> Map.delete(o, key) end))
    :ok
  end

  defp objeto(key), do: Agent.get(@agente, &Map.get(&1.objetos, key))
end
