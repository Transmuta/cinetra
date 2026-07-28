defmodule Api.Audit.SensiveisTest do
  @moduledoc """
  A lista de campos redigidos da trilha (D-Aud4) — **o teste que o moduledoc de
  `Api.Audit.Sensiveis` prometia e que não existia**.

  O bate-volta mediu o buraco: apagar `rg`, `cnpj`, `banco`, `agencia`, `conta` e `conta_tipo` da
  lista deixava os 54 testes da fatia verdes. Só `cpf` e `pix` tinham cobertura, porque só eles
  apareciam num teste de comportamento. Seis dos oito campos podiam parar de ser redigidos sem
  nada ficar vermelho — e o que isso significa está escrito no `06 §4`: *"a trilha vira a maior
  fuga de dado do sistema"*.

  Aqui a afirmação é sobre a REGRA, não sobre um exemplar: a tabela abaixo é a decisão, e o
  teste a compara com o código nos dois sentidos — nada de fora entra, nada de dentro sai.
  """
  use Api.DataCase, async: false

  alias Api.Audit.Sensiveis

  # A decisão, escrita uma vez. Mudar esta tabela é mudar a política de redação — e é para isso
  # que ela está num teste: a mudança fica visível no diff, com nome e sobrenome.
  @decisao %{
    patient: [:cpf, :rg],
    professional: [:cpf, :rg, :cnpj, :banco, :agencia, :conta, :conta_tipo, :pix]
  }

  describe "a lista de campos redigidos" do
    test "é exatamente a decisão — nem a mais, nem a menos" do
      atual = Map.new(Sensiveis.todos(), fn {r, campos} -> {r, Enum.sort(campos)} end)
      esperado = Map.new(@decisao, fn {r, campos} -> {r, Enum.sort(campos)} end)

      assert atual == esperado
    end

    for {resource, campos} <- @decisao, campo <- campos do
      test "#{resource}.#{campo} é redigido" do
        assert Sensiveis.redigir?(unquote(resource), unquote(campo))
      end
    end

    test "campo fora da lista não é redigido" do
      refute Sensiveis.redigir?(:patient, :nome)
      refute Sensiveis.redigir?(:professional, :crefito)
      refute Sensiveis.redigir?(:appointment, :status)
    end

    test "todo campo da lista existe de verdade no recurso" do
      recursos = %{patient: Api.Records.Patient, professional: Api.Directory.Professional}

      for {chave, campos} <- Sensiveis.todos() do
        modulo = Map.fetch!(recursos, chave)
        atributos = modulo |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

        # Campo renomeado no recurso e esquecido aqui vira redação que não redige nada — o
        # silêncio mais perigoso possível, porque a lista continua "parecendo" completa.
        assert Enum.all?(campos, &(&1 in atributos)),
               "campos inexistentes em #{inspect(modulo)}: #{inspect(campos -- atributos)}"
      end
    end
  end

  describe "a redação de fato acontece na ESCRITA" do
    for campo <- @decisao.professional do
      test "#{campo} do profissional entra sem valor" do
        ctx = clinica()
        campo = unquote(campo)

        {:ok, _} =
          Api.Directory.update_professional(ctx.prof, %{campo => "valor-secreto"},
            scope: ctx.scope
          )

        %{entries: entries} = Api.Audit.list_events(ctx.scope, resource: :professional)
        entry = Enum.find(entries, &(&1.action == "update"))
        linha = Enum.find(entry.diff, &(&1["field"] == to_string(campo)))

        assert linha == %{"field" => to_string(campo), "redacted" => true}
        refute inspect(entry.diff) =~ "valor-secreto"
      end
    end

    test "cpf e rg do paciente entram sem valor" do
      ctx = clinica()

      {:ok, _} =
        Api.Records.update_patient(ctx.paciente, %{cpf: "39053344705", rg: "12.345.678-9"},
          scope: ctx.scope
        )

      %{entries: entries} = Api.Audit.list_events(ctx.scope, resource: :patient)
      entry = Enum.find(entries, &(&1.action == "update"))

      assert Enum.find(entry.diff, &(&1["field"] == "cpf")) ==
               %{"field" => "cpf", "redacted" => true}

      assert Enum.find(entry.diff, &(&1["field"] == "rg")) ==
               %{"field" => "rg", "redacted" => true}

      refute inspect(entry.diff) =~ "39053344705"
      refute inspect(entry.diff) =~ "12.345.678"
    end
  end
end
