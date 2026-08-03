defmodule Api.ComposeDeProducao do
  @moduledoc """
  Lê `compose.dokploy.yml` — o stack real de produção/HML — para os testes que provam **a
  configuração do deploy**, não o código.

  Existe como módulo compartilhado porque o recorte por serviço nasceu dentro de
  `Api.DeployEnvTest` e o segundo cliente (`Api.DeployHorizontalidadeTest`, doc 101 §4.5) o teria
  copiado. Instrumento de leitura duplicado é o mesmo risco do `Api.QueryCounter`: duas cópias que
  fatiam o YAML de formas ligeiramente diferentes deixam de significar a mesma coisa, e a diferença
  aparece como um teste verde sobre um bloco vazio.

  Não é um parser de YAML e não quer ser: é recorte por linha, e as guardas contra vacuidade
  (`servico/2` exige um bloco com corpo) são o que substitui o rigor que um parser daria.
  """

  import ExUnit.Assertions

  # O compose mora fora de `api/`, e a suíte roda a partir de `api/`. Dois lugares, duas formas de
  # alcançá-lo: no CI o checkout inteiro está ao lado (`../`); no container de dev, onde só `api/`
  # é montado em `/app`, o `docker-compose.yml` monta a raiz do repositório em `/repo` só-leitura.
  # Sem o segundo caminho o teste pularia justamente onde se desenvolve.
  @caminhos ["../compose.dokploy.yml", "/repo/compose.dokploy.yml"]

  @doc "O conteúdo do compose de produção."
  @spec ler() :: String.t()
  def ler, do: File.read!(caminho())

  @doc """
  Falha em vez de pular quando o compose não é alcançável: um teste de configuração que some
  sozinho no ambiente errado é pior do que não existir — ele reporta verde sem ter olhado nada.
  """
  @spec caminho() :: String.t()
  def caminho do
    Enum.find(@caminhos, &File.exists?/1) ||
      flunk("compose.dokploy.yml não encontrado em nenhum de: #{Enum.join(@caminhos, ", ")}")
  end

  @doc """
  As linhas de um serviço, do cabeçalho dele até o próximo serviço no mesmo recuo.

  A asserção de quem chama precisa ser sobre uma **chave YAML dentro deste serviço**, não sobre o
  texto do arquivo. Medido: com `assert compose =~ env` bastava o nome aparecer em qualquer lugar,
  e o compose CITA envs nos comentários que explicam por que elas são obrigatórias — então apagar
  as linhas de `environment:` (exatamente a regressão que aquele teste existe para pegar) deixava
  o teste VERDE. Um comentário nunca casa `^\\s+NOME:`, e o recorte por serviço impede que a env
  passar a viver no `web` conte como se estivesse aqui.
  """
  @spec servico(String.t(), String.t()) :: [String.t()]
  def servico(compose, nome) do
    linhas = String.split(compose, "\n")

    inicio =
      Enum.find_index(linhas, &(&1 == "  #{nome}:")) ||
        flunk("o serviço `#{nome}` não foi encontrado em compose.dokploy.yml")

    bloco =
      linhas
      |> Enum.drop(inicio + 1)
      |> Enum.take_while(&(not Regex.match?(~r/^  \S/, &1)))

    # Guarda contra o recorte virar vacuidade: um bloco vazio (o formato do compose mudou) faria
    # todo `Enum.any?` de quem chama falhar por acidente, ou passar por acidente se a asserção um
    # dia inverter.
    assert length(bloco) > 10, "o recorte do serviço `#{nome}` devolveu #{length(bloco)} linhas"

    bloco
  end

  @doc "O lado direito de `NOME: <valor>` dentro de um serviço."
  @spec valor_de([String.t()], String.t()) :: String.t()
  def valor_de(linhas, chave) do
    linhas
    |> Enum.find(&Regex.match?(~r/^\s+#{Regex.escape(chave)}:/, &1))
    |> case do
      nil -> flunk("`#{chave}` não aparece no serviço")
      linha -> linha |> String.split(":", parts: 2) |> List.last()
    end
  end

  @doc """
  Quantas réplicas o serviço declara. `1` quando não declara nada — que é o default do Compose e
  o estado registrado na ADR-023 / `docs/04 §12`.
  """
  @spec replicas([String.t()]) :: pos_integer()
  def replicas(linhas) do
    linhas
    |> Enum.find_value(fn linha ->
      case Regex.run(~r/^\s+replicas:\s*(\d+)/, linha) do
        [_todo, n] -> String.to_integer(n)
        nil -> nil
      end
    end)
    |> Kernel.||(1)
  end
end
