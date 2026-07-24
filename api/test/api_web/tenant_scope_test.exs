defmodule ApiWeb.TenantScopeTest do
  @moduledoc """
  Os helpers puros da fronteira (`ApiWeb.TenantScope`).

  Aqui só o que dá para exercitar sem `%Plug.Conn{}` — hoje, o `parse_int/1` que os três
  controllers de lista compartilham. O resto do módulo (escopo, escada de erro, janela de datas)
  é exercido pelos testes de controller, onde o pipeline inteiro roda.

  O `parse_int` nasceu duplicado em três lugares, e a terceira cópia já divergia: aceitava
  negativo, enquanto as outras duas o recusavam. É essa divergência que o teste trava.
  """
  use ExUnit.Case, async: true

  doctest ApiWeb.TenantScope, only: [parse_int: 1]

  describe "parse_int/1" do
    test "inteiro em texto vira inteiro" do
      assert ApiWeb.TenantScope.parse_int("0") == 0
      assert ApiWeb.TenantScope.parse_int("50") == 50
    end

    test "negativo é nil — quem aplica o default é o domínio, não a fronteira" do
      assert ApiWeb.TenantScope.parse_int("-1") == nil
    end

    test "lixo e ausência são nil (a lista não quebra por `?limit=abc`)" do
      assert ApiWeb.TenantScope.parse_int("abc") == nil
      assert ApiWeb.TenantScope.parse_int("12abc") == nil
      assert ApiWeb.TenantScope.parse_int("1.5") == nil
      assert ApiWeb.TenantScope.parse_int(nil) == nil
      assert ApiWeb.TenantScope.parse_int(%{}) == nil
    end

    test "inteiro já parseado passa direto (o corpo JSON manda número)" do
      assert ApiWeb.TenantScope.parse_int(7) == 7
      assert ApiWeb.TenantScope.parse_int(-7) == nil
    end
  end
end
