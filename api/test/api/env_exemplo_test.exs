defmodule Api.EnvExemploTest do
  @moduledoc """
  O template de ambiente da observabilidade não pode **rebaixar** um teto que o compose já
  corrigiu. R-M18 e R-A5 do [doc 95](../../../docs/95-analise-infraestrutura.md), onda 2 do
  [doc 102](../../../docs/102-plano-de-acao-infraestrutura.md).

  ## O bug que originou este arquivo, e por que ele é de uma classe inteira

  `compose.obs.yml:335-340` registra uma correção medida: com `CADVISOR_MEM_LIMIT=384m` o working
  set do cAdvisor ficou em **337 MiB — 87,8% do teto**, a um passo do OOM kill; o default do
  compose foi então subido para `512m`. Mas o `.env.exemplo` continuou trazendo `384m`, e **o
  `.env` vence o default do compose**.

  Consequência: quem seguisse a primeira linha do template (`cp .env.exemplo .env.local`) desfazia
  silenciosamente a correção. O cAdvisor voltava a 88% do limite, morria por OOM, reiniciava e
  sumia do log — levando junto todos os painéis de container **e** o alerta
  `cinetra-container-no-teto`, que é o que avisaria. E nada disso aparece num diff: os dois
  arquivos estão certos quando lidos separadamente.

  Um teste que cobrasse `CADVISOR_MEM_LIMIT == 512m` pegaria este caso e mais nenhum. Por isso a
  asserção é sobre a **relação** entre os dois arquivos: nenhum teto do template pode ser menor que
  o default do compose. Vale para o próximo, que ninguém previu.

  ## A direção da comparação é deliberada

  `>=`, não `==`. Subir um teto no `.env` é escolha legítima de quem opera uma máquina maior;
  baixá-lo abaixo do que foi medido é a regressão. O teste não vigia divergência — vigia
  **rebaixamento**.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Compose

  @template "deploy/observability/.env.exemplo"

  setup_all do
    {:ok, compose: Compose.ler_obs(), template: Compose.ler_do_repo(@template)}
  end

  test "nenhum teto de memória do template é menor que o default do compose", %{
    compose: compose,
    template: template
  } do
    defaults = defaults_do_compose(compose)
    valores = valores_do_template(template)

    comparados =
      for {chave, default} <- defaults,
          String.ends_with?(chave, "_MEM_LIMIT"),
          valor = valores[chave],
          not is_nil(valor) do
        assert bytes(valor) >= bytes(default),
               """
               `#{chave}` no `.env.exemplo` é **#{valor}**, menor que o default do compose (#{default}).

               O `.env` vence o default, então copiar o template desfaz a correção — e o sintoma \
               é o container morrer por OOM, reiniciar e sumir do log, levando junto os painéis \
               que diriam o que aconteceu. Regressão que não aparece em diff nenhum.

               Se o teto PRECISA baixar, o número medido que o justificou tem de mudar junto, no \
               comentário do compose.
               """

        chave
      end

    # Anti-vacuidade: se a extração parar de casar (qualquer um dos dois arquivos muda de forma),
    # a compreensão acima devolve `[]` e o teste passa verde sem ter comparado nada — que é
    # exatamente o modo de falha que ele existe para impedir em outro lugar.
    assert length(comparados) >= 3,
           "a comparação cobriu só #{length(comparados)} tetos (#{inspect(comparados)}) — a extração quebrou?"
  end

  # R-A5. `compose.obs.yml` declara o teto de disco do Loki como uma das três salvaguardas que
  # substituíram a segunda VM, mas a linha é `${LOKI_DATA:-loki_data}` — sem a variável, cai no
  # volume nomeado e o teto não existe. Ela não aparecia no template, então quem provisionava
  # seguindo a instrução subia sem teto, dividindo disco com o `pgdata`.
  test "o template documenta LOKI_DATA e aponta para o script que cria o volume limitado", %{
    template: template
  } do
    assert template =~ ~r/^#?\s*LOKI_DATA=/m,
           """
           `LOKI_DATA` não aparece no `.env.exemplo`.

           Sem ela o compose cai em `loki_data`, o volume nomeado de sempre, e o teto de disco é \
           opcional e INVISÍVEL. `loki.yml:64` permite `ingestion_rate_mb: 4` — ~345 GB/dia, ordens \
           de grandeza acima do disco: um laço de log num deploy ruim enche tudo, o Postgres recusa \
           escrita e o backup falha.
           """

    assert template =~ "criar-volume-limitado.sh",
           "o template cita LOKI_DATA sem dizer como criar o volume — apontar para um caminho inexistente troca 'sem teto' por 'o Loki não sobe'"
  end

  # `${NOME:-default}` no compose.
  defp defaults_do_compose(compose) do
    ~r/\$\{([A-Z0-9_]+):-([^}]+)\}/
    |> Regex.scan(compose)
    |> Map.new(fn [_todo, nome, default] -> {nome, default} end)
  end

  # `NOME=valor` no template, ignorando linha comentada — comentário é documentação, não valor em
  # vigor, e tratá-lo como valor faria o teste reprovar exemplos escritos de propósito.
  defp valores_do_template(template) do
    template
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
    |> Enum.flat_map(fn linha ->
      case Regex.run(~r/^\s*([A-Z0-9_]+)=(.*)$/, linha) do
        [_todo, nome, valor] -> [{nome, String.trim(valor)}]
        nil -> []
      end
    end)
    |> Map.new()
  end

  # `512m`, `1500m`, `1g`, `128m` — as unidades que o Docker aceita em `mem_limit`.
  defp bytes(valor) do
    case Regex.run(~r/^(\d+)\s*([bkmg])?$/i, String.trim(valor)) do
      [_todo, n] -> String.to_integer(n)
      [_todo, n, unidade] -> String.to_integer(n) * multiplicador(String.downcase(unidade))
      nil -> flunk("`#{valor}` não é um tamanho que o Docker aceite em mem_limit")
    end
  end

  defp multiplicador("b"), do: 1
  defp multiplicador("k"), do: 1024
  defp multiplicador("m"), do: 1024 * 1024
  defp multiplicador("g"), do: 1024 * 1024 * 1024
end
