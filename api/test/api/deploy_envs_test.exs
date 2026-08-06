defmodule Api.DeployEnvsTest do
  @moduledoc """
  O compose entrega ao release **tudo** que o `runtime.exs` exige para bootar — senão o container
  morre antes da primeira linha de trabalho.

  ## O bug que trouxe este arquivo (2026-08-06, primeiro deploy real de HML)

  O serviço `migrate` saiu com `exit 1` e derrubou o deploy inteiro. A causa não estava no banco,
  nem na migration: `config/runtime.exs`, no bloco `config_env() == :prod`, **levanta** sem
  `PHX_HOST` e sem `WEB_APP_URL` — e o `migrate` declarava nenhuma das duas. Como
  `bin/api eval Api.Release.setup()` carrega o `runtime.exs` exatamente como o servidor faria, ele
  morria em `runtime.exs:238` antes de abrir conexão.

  Estava **latente desde que o compose foi escrito**. Não apareceu antes porque nenhum deploy
  tinha passado do `pull` — o que também é a lição: um defeito que só o ambiente real exercita
  fica invisível por quanto tempo for preciso, e aparece no pior momento (aqui, com o gate de
  backup já removido).

  ## Por que este teste DERIVA a lista em vez de escrevê-la

  Uma lista fixa envelhece em silêncio: no dia em que alguém acrescentar um `|| raise` no
  `runtime.exs` — que é a prática certa e o próprio doc 96 (C-1) defende — o compose fica devendo
  uma env e nenhum teste percebe. Aqui a fonte da verdade é o **próprio `runtime.exs`**: o teste lê
  o bloco de `:prod`, extrai todo `System.get_env("X") || raise` e cobra cada um dos serviços que
  rodam a imagem da API.

  Ou seja, acrescentar um `|| raise` novo deixa este teste vermelho até o compose acompanhar. É o
  comportamento desejado.

  ## O limite honesto

  Isto lê **texto**: prova que a chave está declarada no serviço, não que o valor chega preenchido.
  `PHX_HOST: ${WEB_HOST}` com `WEB_HOST` vazio no Environment do Dokploy passa neste teste e
  quebra no servidor — é a classe das 14 variáveis silenciosas do compose, que é outro assunto.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Compose

  # Os serviços que rodam a imagem da API e portanto carregam o `runtime.exs` inteiro. O `migrate`
  # entra mesmo sendo one-shot: `bin/api eval` avalia a configuração de runtime igual ao `start`, e
  # foi exatamente essa suposição errada ("é só um eval, não precisa das envs de web") que criou o
  # bug. `db` e `web` ficam de fora — não são o release Elixir.
  @servicos_do_release ~w(migrate api)

  setup_all do
    {:ok, compose: Compose.ler(), runtime: File.read!("config/runtime.exs")}
  end

  test "todo serviço do release declara as envs que o runtime.exs exige em :prod", %{
    compose: compose,
    runtime: runtime
  } do
    exigidas = exigidas_pelo_runtime(runtime)

    # Anti-vacuidade: se a extração parar de casar, o `for` abaixo não olha nada e o teste vira
    # decoração. Em 2026-08-06 eram cinco.
    assert length(exigidas) >= 4,
           "a extração achou só #{length(exigidas)} envs obrigatórias (#{inspect(exigidas)}) — a forma do runtime.exs mudou?"

    for servico <- @servicos_do_release, env <- exigidas do
      linhas = Compose.servico(compose, servico)

      assert Enum.any?(linhas, &Regex.match?(~r/^\s+#{env}:/, &1)),
             """
             O serviço `#{servico}` não declara `#{env}`, e o `config/runtime.exs` LEVANTA sem ela
             no bloco `config_env() == :prod`.

             O container morre no boot, antes da primeira linha de trabalho útil. No `migrate` isso
             derruba o deploy inteiro — ele é `service_completed_successfully` para os outros — e o
             log não fala de banco nem de migration, o que manda quem investiga para o lugar errado.

             Foi exatamente assim que o primeiro deploy real de HML falhou (2026-08-06): faltavam
             `PHX_HOST` e `WEB_APP_URL` no `migrate`, porque se supôs que um `bin/api eval` não
             precisaria das envs de web. Ele carrega o `runtime.exs` igual ao `start`.
             """
    end
  end

  # Todo `System.get_env("X") || raise` do bloco de `:prod`. O `||` seguido de `raise` é o que
  # distingue "obrigatória" de "opcional com default" — e é por isso que o casamento exige os dois,
  # em vez de listar todo `System.get_env` do arquivo.
  defp exigidas_pelo_runtime(runtime) do
    runtime
    |> String.split("if config_env() == :prod do", parts: 2)
    |> List.last()
    |> then(&Regex.scan(~r/System\.get_env\("([A-Z_0-9]+)"\)\s*\|\|\s*raise/, &1))
    |> Enum.map(fn [_todo, nome] -> nome end)
    |> Enum.uniq()
  end
end
