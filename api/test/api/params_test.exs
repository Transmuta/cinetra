defmodule Api.ParamsTest do
  @moduledoc """
  A coerção de valor de fronteira (doc 43 §5e). Os `doctest` valem por si — são os exemplos da
  docstring, executados; aqui ficam os casos que a docstring não deve carregar: a **divergência**
  que motivou a consolidação e as bordas.
  """
  use ExUnit.Case, async: true

  doctest Api.Params

  describe "truthy?/1" do
    test "aceita o conjunto inteiro que a cópia mais permissiva aceitava" do
      for valor <- [true, "true", "1", 1] do
        assert Api.Params.truthy?(valor), "#{inspect(valor)} deveria valer como sim"
      end
    end

    test "o que não é sim é não — inclusive o que parece" do
      for valor <- [false, "false", "0", 0, nil, "", "TRUE", "sim", 2, %{}, []] do
        refute Api.Params.truthy?(valor), "#{inspect(valor)} não deveria valer como sim"
      end
    end

    # O sintoma medido no bate-volta: `forcar: 1` virava `false` calado, e a massa agendava sem o
    # "agendar mesmo assim" que o cliente pediu.
    test "forcar: 1 vale como sim — era o que divergia" do
      assert Api.Params.truthy?(%{"forcar" => 1}, :forcar)
      assert Api.Params.truthy?(%{"aplicar_horario" => "1"}, :aplicar_horario)
      assert Api.Params.truthy?(%{"justificada" => "1"}, :justificada)
    end
  end

  describe "get/2" do
    test "lê por átomo ou string, e o átomo ganha quando os dois existem" do
      assert Api.Params.get(%{"escopo" => "todas"}, :escopo) == "todas"
      assert Api.Params.get(%{escopo: "esta"}, :escopo) == "esta"
      assert Api.Params.get(%{"escopo" => "todas", escopo: :esta}, :escopo) == :esta
      assert Api.Params.get(%{}, :escopo) == nil
    end
  end
end
