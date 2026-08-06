defmodule Api.ParidadeEspelhadaTest do
  @moduledoc """
  O lado Elixir do contrato de paridade: as regras que existem **duas vezes** no projeto, uma aqui
  (a autoridade) e uma em TypeScript (a régua que chega antes da viagem).

  Os casos **não moram neste arquivo**. Eles vêm de `contratos/regras-espelhadas.json`, na raiz do
  repositório, e o teste gêmeo em `web/src/lib/paridade-espelhada.test.ts` lê o mesmo arquivo. É
  essa a única propriedade que importa: duas listas de casos, ainda que idênticas hoje, divergem no
  dia em que alguém acrescenta um caso de um lado só — e aí os dois testes ficam verdes sobre
  implementações que discordam.

  `docs/04-arquitetura.md §10` já mandava que "onde há espelho, a paridade é garantida por contrato
  de teste compartilhado, nunca por cópia mantida a olho". O contrato não existia: cada `.ts`
  trazia um comentário dizendo "espelho de X", e a prosa era a verificação inteira (doc 101, A5).

  > **Este teste não substitui os testes de unidade dos dois lados.** Ele prova que os dois
  > concordam nos casos que alguém achou dignos de contrato; a cobertura fina de cada
  > implementação continua onde está.
  """
  use ExUnit.Case, async: true

  # No CI o checkout inteiro está ao lado (`../`); no container de dev, onde só `api/` é montado em
  # `/app`, o `docker-compose.yml` monta a raiz do repositório em `/repo` só-leitura. É a mesma
  # dupla de caminhos de `Api.DeployEnvTest`, e pelo mesmo motivo.
  @contrato ["../contratos/regras-espelhadas.json", "/repo/contratos/regras-espelhadas.json"]

  setup_all do
    {:ok, contrato: ler_contrato()}
  end

  describe "CPF" do
    test "os casos do contrato", %{contrato: contrato} do
      confere(contrato, "cpf", &Api.Cpf.valid?/1)
    end
  end

  describe "CNPJ" do
    test "os casos do contrato", %{contrato: contrato} do
      confere(contrato, "cnpj", &Api.Cnpj.valid?/1)
    end
  end

  describe "telefone canônico" do
    test "os casos do contrato", %{contrato: contrato} do
      confere(contrato, "telefone_canonico", &Api.Messaging.Dispatch.normalizar(:whatsapp, &1))
    end
  end

  describe "e-mail (forma mínima)" do
    test "os casos do contrato", %{contrato: contrato} do
      # A regra mora numa validation Ash, que recebe changeset. O que o contrato prende é o
      # predicado dela — a mesma regex que o BFF repete —, então é ele que se exercita aqui.
      confere(contrato, "email_forma_minima", &email_valido?/1)
    end
  end

  describe "períodos do dia" do
    test "os casos do contrato", %{contrato: contrato} do
      confere(contrato, "periodos_do_dia", &(Api.Scheduling.Periods.validate(&1) == :ok))
    end
  end

  # A metassegurança: se o arquivo mudar de forma (uma seção renomeada, um bloco esvaziado), os
  # testes acima passariam a exercitar zero casos e reportariam verde. Este cobra a forma.
  test "o contrato tem todas as seções, e nenhuma vazia", %{contrato: contrato} do
    esperadas = ~w(cpf cnpj telefone_canonico email_forma_minima periodos_do_dia)

    for secao <- esperadas do
      assert Map.has_key?(contrato, secao), "seção `#{secao}` sumiu do contrato"

      casos = get_in(contrato, [secao, "casos"])

      assert is_list(casos) and length(casos) >= 5,
             "seção `#{secao}` ficou com #{length(casos || [])} casos — um contrato que esvazia " <>
               "reporta verde sem ter olhado nada"
    end
  end

  defp confere(contrato, secao, fun) do
    casos = get_in(contrato, [secao, "casos"])

    for %{"entrada" => entrada, "esperado" => esperado, "porque" => porque} <- casos do
      assert fun.(entrada) === esperado,
             """
             #{secao}: o Elixir discorda do contrato.

               entrada:  #{inspect(entrada)}
               esperado: #{inspect(esperado)}  (#{porque})
               obtido:   #{inspect(fun.(entrada))}

             O gêmeo em `web/src/lib/paridade-espelhada.test.ts` lê os MESMOS casos. Se este lado
             está certo e o contrato está errado, corrija o contrato — e o outro lado vai cobrar.
             """
    end
  end

  defp email_valido?(valor) do
    Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, valor)
  end

  # Falha em vez de pular quando o contrato não é alcançável: um teste de contrato que some sozinho
  # no ambiente errado reporta verde sem ter olhado nada.
  defp ler_contrato do
    caminho =
      Enum.find(@contrato, &File.exists?/1) ||
        flunk("regras-espelhadas.json não encontrado em nenhum de: #{Enum.join(@contrato, ", ")}")

    caminho |> File.read!() |> Jason.decode!()
  end
end
