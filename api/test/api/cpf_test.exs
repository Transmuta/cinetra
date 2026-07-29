defmodule Api.CpfTest do
  @moduledoc """
  CPF com dígito verificador (AN-11 / HOM-012, D10 "barra no salvar"). Espelha o desenho do
  `Api.CnpjTest`: normalização para dígitos + módulo 11 clássico, rejeitando as sequências
  repetidas que passam na conta mas não existem.
  """
  use ExUnit.Case, async: true

  alias Api.Cpf

  describe "normalize/1" do
    test "tira a máscara e devolve só os dígitos" do
      assert Cpf.normalize("390.533.447-05") == "39053344705"
    end

    test "nil e vazio viram nil" do
      assert Cpf.normalize(nil) == nil
      assert Cpf.normalize("") == nil
      assert Cpf.normalize("abc") == nil
    end
  end

  describe "valid?/1" do
    test "CPF válido, com ou sem máscara" do
      assert Cpf.valid?("390.533.447-05")
      assert Cpf.valid?("39053344705")
      assert Cpf.valid?("123.456.789-09")
      assert Cpf.valid?("111.444.777-35")
    end

    test "dígito verificador errado reprova" do
      refute Cpf.valid?("123.456.789-00")
      refute Cpf.valid?("390.533.447-06")
    end

    test "sequência repetida reprova mesmo com DV aritmeticamente correto" do
      # 111.111.111-11 fecha a conta do módulo 11, mas não é um CPF emitido.
      refute Cpf.valid?("111.111.111-11")
      refute Cpf.valid?("000.000.000-00")
    end

    test "tamanho errado e não-string reprovam" do
      refute Cpf.valid?("1234567890")
      refute Cpf.valid?("123456789012")
      refute Cpf.valid?(nil)
      refute Cpf.valid?(39_053_344_705)
    end
  end
end
