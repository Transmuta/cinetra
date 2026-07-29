defmodule Api.SwooshFinchTest do
  @moduledoc """
  Regressão do achado da auditoria AN-08 (2026-07-29), encontrado ao vivo: com `RESEND_API_KEY`
  no ambiente, o `runtime.exs` aponta `config :swoosh, :api_client, Swoosh.ApiClient.Finch` — e
  **ninguém subia o pool** na árvore de supervisão. O primeiro magic link morria em
  `(ArgumentError) unknown registry: Swoosh.Finch` (500), ou seja: login inteiro quebrado em
  qualquer ambiente com a chave ligada.

  O teste não manda e-mail (o adapter de teste é `Swoosh.Adapters.Test`): ele prova que o pool
  que o `runtime.exs` referencia EXISTE na árvore, que é a metade que faltava.
  """
  use ExUnit.Case, async: true

  test "o pool Swoosh.Finch está de pé — o Resend (runtime.exs) depende dele" do
    assert is_pid(Process.whereis(Swoosh.Finch))
  end
end
