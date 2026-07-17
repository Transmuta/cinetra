defmodule Api.CnpjTest do
  use ExUnit.Case, async: true

  alias Api.Cnpj

  # Vetores de ouro conferidos à mão pelo módulo 11 (ASCII − 48):
  #   12ABC34501DE  → DV 3 e 5   (exemplo canônico do Serpro, alfanumérico)
  #   112223330001  → DV 8 e 1   (11.222.333/0001-81, numérico clássico — retrocompatível)
  @alfanumerico "12ABC34501DE35"
  @numerico "11222333000181"

  describe "normalize/1" do
    test "mantém só [0-9A-Z] e sobe para maiúsculas" do
      assert Cnpj.normalize("12.abc.345/01de-35") == @alfanumerico
      assert Cnpj.normalize(" 11.222.333/0001-81 ") == @numerico
    end

    test "nil ou sem caractere válido viram nil" do
      assert Cnpj.normalize(nil) == nil
      assert Cnpj.normalize("") == nil
      assert Cnpj.normalize("  ./-  ") == nil
    end
  end

  describe "valid?/1" do
    test "aceita CNPJ alfanumérico válido, mascarado ou não" do
      assert Cnpj.valid?(@alfanumerico)
      assert Cnpj.valid?("12.ABC.345/01DE-35")
      assert Cnpj.valid?("12.abc.345/01de-35")
    end

    test "aceita CNPJ numérico clássico (mesma rotina)" do
      assert Cnpj.valid?(@numerico)
      assert Cnpj.valid?("11.222.333/0001-81")
    end

    test "rejeita dígito verificador errado" do
      refute Cnpj.valid?("12ABC34501DE34")
      refute Cnpj.valid?("11222333000182")
    end

    test "rejeita DV alfabético (as duas últimas posições são numéricas)" do
      refute Cnpj.valid?("12ABC34501DE3A")
    end

    test "rejeita tamanho diferente de 14 e entradas degeneradas" do
      refute Cnpj.valid?("")
      refute Cnpj.valid?("12ABC34501DE3")
      refute Cnpj.valid?("12ABC34501DE355")
      refute Cnpj.valid?("00000000000000")
      refute Cnpj.valid?(nil)
      refute Cnpj.valid?(123)
    end
  end
end
