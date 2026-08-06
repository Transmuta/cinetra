defmodule ApiWeb.Telemetry do
  @moduledoc """
  O supervisor do `:telemetry_poller`.

  ## O que saiu daqui, e por quê

  Este módulo veio do `mix phx.new` com um `metrics/0` de 40 linhas e um `periodic_measurements/0`
  vazio. Os dois eram **código morto** (doc 96, M-1): nenhum reporter consumia `metrics/0` — o
  `Telemetry.Metrics.ConsoleReporter` está comentado no `init/1` desde o gerador —, e o poller
  media uma lista vazia.

  Pior que morto, era **enganoso**: as métricas que `metrics/0` declarava
  (`phoenix.endpoint.stop.duration`, `phoenix.router_dispatch.*`, `phoenix.channel_joined.*`,
  `vm.memory.total`) são exatamente as que o `Api.PromEx` de fato exporta, via `Plugins.Phoenix` e
  `Plugins.Beam`. Quem fosse procurar "onde estão definidas as métricas de HTTP" encontrava
  primeiro a lista que não produzia série nenhuma.

  **A fonte de verdade das métricas é `Api.PromEx`.** Este supervisor fica só com o poller, que é
  o que o `Plugins.Beam` do PromEx consome.
  """
  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: [], period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
