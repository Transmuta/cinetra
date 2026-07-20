defmodule ApiWeb.ChannelCase do
  @moduledoc """
  Caso de teste dos Phoenix Channels (Entrega 3, doc 25 §9). Irmão do `ApiWeb.ConnCase`:
  mesma sandbox transacional, mesma razão para `shared` fora de `:async` — o processo do
  canal é **outro processo**, e sem o modo compartilhado ele não enxerga a conexão do teste.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ApiWeb.Endpoint

      import Phoenix.ChannelTest
      import ApiWeb.ChannelCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Api.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
