defmodule Api.CiWorkflowTest do
  @moduledoc """
  O **caminho até produção** como superfície de ataque e de falha silenciosa. Onda 3 do
  [doc 102](../../../docs/102-plano-de-acao-infraestrutura.md) — R-A10, R-M6, R-M7, R-M5 e R-B3 do
  [doc 95](../../../docs/95-analise-infraestrutura.md).

  Nada aqui melhora a produção de hoje. Tudo aqui decide se a produção de amanhã nasce sã.

  ## O token (R-A10)

  Sem bloco `permissions:`, o `GITHUB_TOKEN` recebe o default configurado no repositório — que em
  repositórios mais antigos é **read/write em todos os escopos**. E este workflow executa código de
  terceiros com o token no ambiente: `mix deps.get` e `npm ci` rodam scripts de instalação de toda
  a árvore de dependências. Um pacote comprometido em qualquer ponto dela empurra commit, altera
  workflow ou publica release.

  O agravante específico deste repositório: o job `deploy` tem acesso a
  `DOKPLOY_DEPLOY_WEBHOOK_PROD` — o **gatilho de deploy de produção**.

  ## A tag móvel (R-M6)

  `@v4` é um ponteiro, não um commit. Quem controla `actions/cache` (ou qualquer uma das outras)
  pode mover a tag e executar código arbitrário no runner que tem os secrets de deploy — **sem um
  único commit neste repositório**, e portanto sem nada para revisar.

  SHA de 40 caracteres é imutável. O custo é que atualizar passa a ser um commit — que é
  exatamente o ponto, e é o que o Dependabot automatiza (R-M7).

  ## O deploy que só prova que o POST chegou (R-M5)

  `curl -fsS -X POST "$URL"` retorna assim que o Dokploy **aceita** o webhook. O CI fica verde
  mesmo que o build no servidor falhe, o `migrate` aborte ou o container novo não passe no
  healthcheck. É o sinal que a equipe vai aprender a confiar, e ele mede uma coisa só: que o HTTP
  POST chegou.

  ## O limite honesto

  Este arquivo lê **texto do workflow**. Ele prova que a declaração está lá; não prova que o token
  restrito basta para os passos, nem que o SHA fixado aponta para o que se pensa, nem que o
  `/ready` do ambiente certo foi consultado. O que ele impede é a declaração **sumir** — que é o
  estado em que ela sempre esteve.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Repo

  @workflow ".github/workflows/ci.yml"
  @dependabot ".github/dependabot.yml"

  setup_all do
    {:ok, ci: Repo.ler_do_repo(@workflow)}
  end

  describe "permissão do GITHUB_TOKEN (R-A10)" do
    test "o workflow declara permissions no topo", %{ci: ci} do
      # Recorte até a primeira linha de `jobs:` — `permissions:` dentro de um job também casaria
      # no arquivo inteiro, e o que se cobra aqui é o default do workflow.
      topo = ci |> String.split("\njobs:") |> List.first()

      assert topo =~ ~r/^permissions:/m,
             """
             `.github/workflows/ci.yml` não declara `permissions:` no nível do workflow.

             Sem isso o `GITHUB_TOKEN` herda o default do repositório, que pode ser read/write em \
             TODOS os escopos — enquanto `mix deps.get` e `npm ci` executam código de terceiros no \
             runner, no mesmo workflow que guarda o webhook de deploy de PRODUÇÃO.

             Custo do conserto: duas linhas.
             """

      assert topo =~ ~r/^\s+contents:\s*read/m,
             "o bloco `permissions:` existe mas não reduz `contents` a `read`"
    end
  end

  describe "actions fixadas por SHA (R-M6)" do
    test "toda `uses:` aponta para um commit de 40 caracteres", %{ci: ci} do
      referencias =
        ~r/^\s*(?:-\s+)?uses:\s*(\S+)/m
        |> Regex.scan(ci)
        |> Enum.map(fn [_todo, ref] -> ref end)

      # Anti-vacuidade: se a extração parar de casar, o `for` abaixo não olha nada.
      assert length(referencias) >= 4,
             "a extração achou só #{length(referencias)} `uses:` — a forma do workflow mudou?"

      for ref <- referencias do
        assert ref =~ ~r/@[0-9a-f]{40}$/,
               """
               `uses: #{ref}` não está fixado por SHA.

               Tag é ponteiro MÓVEL: quem controla a action pode movê-la e executar código \
               arbitrário no runner que tem `DOKPLOY_DEPLOY_WEBHOOK_PROD` no ambiente — sem um \
               único commit neste repositório, e portanto sem nada para revisar.

               Ponha o SHA de 40 caracteres e deixe o comentário com a versão ao lado; o \
               Dependabot atualiza os dois.
               """
      end
    end
  end

  describe "varredura de dependência (R-M7)" do
    test "o CI audita as dependências dos dois lados", %{ci: ci} do
      assert ci =~ ~r/mix\s+(hex\.audit|deps\.audit)/,
             "nenhum passo audita as dependências Elixir — CVE conhecida entra e permanece sem sinal"

      assert ci =~ ~r/npm audit/,
             "nenhum passo roda `npm audit` — mesma cegueira do lado do BFF"
    end

    test "existe configuração de Dependabot para os quatro ecossistemas" do
      dependabot = Repo.ler_do_repo(@dependabot)

      for ecossistema <- ~w(github-actions mix npm docker) do
        assert dependabot =~ ecossistema,
               """
               `.github/dependabot.yml` não cobre `#{ecossistema}`.

               Fixar por SHA (R-M6) sem Dependabot troca "atualiza sozinho e sem revisão" por \
               "nunca atualiza" — que é pior para CVE. As duas metades andam juntas.
               """
      end
    end
  end

  describe "o deploy é verificado depois de disparado (R-M5)" do
    test "o job de deploy espera o ambiente responder antes de ficar verde", %{ci: ci} do
      deploy = bloco_do_job(ci, "deploy")
      texto = Enum.join(deploy, "\n")

      assert texto =~ "/api/ready" or texto =~ "/ready",
             """
             O job `deploy` dispara o webhook e termina.

             O `curl -fsS -X POST` retorna assim que o Dokploy ACEITA o webhook. O CI fica verde \
             mesmo que o build no servidor falhe, o `migrate` aborte ou o container novo não passe \
             no healthcheck. O sinal de "deploy ok" mede apenas que o POST chegou.
             """
    end
  end

  describe "job travado não queima o runner (R-B3)" do
    test "todo job declara timeout-minutes", %{ci: ci} do
      jobs = nomes_dos_jobs(ci)

      assert length(jobs) >= 4,
             "achei só #{length(jobs)} jobs (#{inspect(jobs)}) — a extração quebrou?"

      for job <- jobs do
        assert Enum.any?(bloco_do_job(ci, job), &Regex.match?(~r/^\s+timeout-minutes:/, &1)),
               "o job `#{job}` não declara `timeout-minutes` — travado, ele queima até o teto de 6 h do runner"
      end
    end
  end

  # Os nomes de job: duas casas de indentação sob `jobs:`, que é onde o GitHub os põe.
  defp nomes_dos_jobs(ci) do
    ci
    |> String.split("\njobs:", parts: 2)
    |> List.last()
    |> String.split("\n")
    |> Enum.flat_map(fn linha ->
      case Regex.run(~r/^  ([a-z][a-z0-9-]*):$/, linha) do
        [_todo, nome] -> [nome]
        nil -> []
      end
    end)
  end

  # O bloco de um job, do cabeçalho dele até o próximo no mesmo recuo. Mesma técnica do
  # `Api.ComposeDeProducao.servico/2` e **de propósito não é ela**: artefato diferente, mensagem de
  # falha diferente e limiar de vacuidade diferente. O risco que aquele módulo nomeia é fatiar *o
  # mesmo arquivo* de dois jeitos, não usar a mesma ideia em arquivos diferentes.
  defp bloco_do_job(ci, nome) do
    linhas = ci |> String.split("\njobs:", parts: 2) |> List.last() |> String.split("\n")

    inicio =
      Enum.find_index(linhas, &(&1 == "  #{nome}:")) ||
        flunk("job `#{nome}` não encontrado em #{@workflow}")

    bloco =
      linhas
      |> Enum.drop(inicio + 1)
      |> Enum.take_while(&(not Regex.match?(~r/^  \S/, &1)))

    assert length(bloco) > 3, "o recorte do job `#{nome}` devolveu #{length(bloco)} linhas"

    bloco
  end
end
