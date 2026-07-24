defmodule Api.PaginationTest do
  @moduledoc """
  Os limites de página, num lugar só (`Api.Pagination`).

  Nasceu do bate-volta das Frentes 3/4: três domínios paginavam com **três** cópias da mesma
  regra, e a mais nova já divergia. O que este arquivo protege não é a aritmética — é que os
  três caminhos (pacientes, auditoria, fila) continuem respondendo o mesmo para o mesmo pedido
  torto, que é o que a duplicação silenciosamente deixava de garantir.

  Os `doctest` valem por si: são o exemplo da docstring, executado.
  """
  use ExUnit.Case, async: true

  doctest Api.Pagination

  describe "limit/2" do
    test "sem valor, o padrão" do
      assert Api.Pagination.limit(nil) == 50
      assert Api.Pagination.limit("50") == 50
    end

    test "acima do teto, o teto" do
      assert Api.Pagination.limit(201) == 200
      assert Api.Pagination.limit(10_000_000) == 200
    end

    test "zero e negativo caem no padrão — não em página vazia" do
      assert Api.Pagination.limit(0) == 50
      assert Api.Pagination.limit(-3) == 50
    end

    test "quem tem motivo para divergir, diverge explicitamente" do
      assert Api.Pagination.limit(500, max: 1_000) == 500
      assert Api.Pagination.limit(nil, default: 10) == 10
    end
  end

  describe "offset/2" do
    test "ausente ou negativo é o começo" do
      assert Api.Pagination.offset(nil) == 0
      assert Api.Pagination.offset(-1) == 0
    end

    # O teto existe por robustez, não por performance: um `?page=` gigante chega cru no
    # Postgrex, que recusa qualquer coisa fora do int64 e derruba a request com 500.
    test "acima do teto, o teto" do
      assert Api.Pagination.offset(999_999_999) == 100_000
    end
  end

  test "page_opts/1 monta o que o Ash espera, sempre contável" do
    assert Api.Pagination.page_opts(limit: 10, offset: 20) == [limit: 10, offset: 20, count: true]
    assert Api.Pagination.page_opts([]) == [limit: 50, offset: 0, count: true]
  end
end
