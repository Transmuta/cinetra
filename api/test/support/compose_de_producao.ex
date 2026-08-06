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

  # Os arquivos moram fora de `api/`, e a suíte roda a partir de `api/`. Duas raízes, duas formas
  # de alcançá-los: no CI o checkout inteiro está ao lado (`../`); no container de dev, onde só
  # `api/` é montado em `/app`, o `docker-compose.yml` monta a raiz do repositório em `/repo`
  # só-leitura. Sem a segunda, o teste pularia justamente onde se desenvolve.
  @raizes ["..", "/repo"]

  @compose_do_produto "compose.dokploy.yml"
  @compose_da_obs "deploy/observability/compose.obs.yml"

  @doc "O conteúdo do compose de produção (o stack do produto)."
  @spec ler() :: String.t()
  def ler, do: File.read!(caminho())

  @doc """
  O conteúdo do compose da observabilidade.

  Mesmo instrumento, segundo arquivo — e não um módulo irmão, pelo motivo do moduledoc: duas
  cópias que fatiam YAML de formas ligeiramente diferentes deixam de significar a mesma coisa. O
  recorte por serviço e as guardas contra vacuidade são exatamente os mesmos nos dois.
  """
  @spec ler_obs() :: String.t()
  def ler_obs, do: File.read!(caminho(@compose_da_obs))

  @doc """
  Falha em vez de pular quando o arquivo não é alcançável: um teste de configuração que some
  sozinho no ambiente errado é pior do que não existir — ele reporta verde sem ter olhado nada.
  """
  @spec caminho(String.t()) :: String.t()
  def caminho(relativo \\ @compose_do_produto) do
    @raizes
    |> Enum.map(&Path.join(&1, relativo))
    |> Enum.find(&File.exists?/1)
    |> Kernel.||(
      flunk("#{relativo} não encontrado a partir de nenhuma raiz: #{Enum.join(@raizes, ", ")}")
    )
  end

  @doc """
  Um arquivo qualquer do repositório, pelas mesmas duas raízes. Para os testes que precisam de
  artefato que não é compose — `.env.exemplo`, `.gitignore`, workflow do CI.
  """
  @spec ler_do_repo(String.t()) :: String.t()
  def ler_do_repo(relativo), do: relativo |> caminho() |> File.read!()

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
  O default de `${NOME:-valor}`, ou a linha inteira quando não há interpolação.

  O default do compose **é o valor de produção**: HML sobrescreve no Environment do stack, prod
  não sobrescreve nada. Então é o default que precisa ser coerente com o resto do serviço — e é
  por isso que os testes de teto leem daqui, e não de um `.env`.
  """
  @spec default_de([String.t()], String.t()) :: String.t()
  def default_de(linhas, chave) do
    valor = linhas |> valor_de(chave) |> String.trim()

    case Regex.run(~r/\$\{[A-Z0-9_]+:-([^}]+)\}/, valor) do
      [_todo, default] -> default
      nil -> valor
    end
  end

  @doc """
  Um tamanho de memória em bytes.

  Aceita as unidades do **Docker** (`512m`, `1g`) e as do **Postgres** (`256MB`, `4GB`), porque
  desde que o `db` ganhou tuning os dois convivem no mesmo serviço — e o ponto de compará-los é
  justamente esse: `mem_limit` é o teto do container, `shared_buffers` é o que o processo pede
  dentro dele. Enquanto as duas unidades não fossem redutíveis a um número, a relação entre elas
  não era testável.
  """
  @spec bytes(String.t()) :: non_neg_integer()
  def bytes(valor) do
    case Regex.run(~r/^(\d+)\s*(kb|mb|gb|b|k|m|g)?$/i, String.trim(valor)) do
      [_todo, n] -> String.to_integer(n)
      [_todo, n, unidade] -> String.to_integer(n) * multiplicador(String.downcase(unidade))
      nil -> flunk("`#{valor}` não é um tamanho que o Docker ou o Postgres aceitem")
    end
  end

  defp multiplicador("b"), do: 1
  defp multiplicador(u) when u in ~w(k kb), do: 1024
  defp multiplicador(u) when u in ~w(m mb), do: 1024 * 1024
  defp multiplicador(u) when u in ~w(g gb), do: 1024 * 1024 * 1024

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
