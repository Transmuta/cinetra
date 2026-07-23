defmodule Api.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ApiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:api, :dns_cluster_query) || :ignore},
      Api.Repo,
      # Rate limiter (Hammer/ETS). Sobe em todos os ambientes; a enforcement é gated a prod
      # no plug (auditoria doc 13, causa A).
      {Api.RateLimiter, [clean_period: :timer.minutes(1)]},
      {Phoenix.PubSub, name: Api.PubSub},
      # Cache do fuso da clínica (D-K). Depende do PubSub — é por ele que a invalidação de um
      # nó chega aos outros (`:persistent_term` é por-nó).
      Api.Accounts.ClinicTimezone,
      # Oban — o cron de limpeza dos `SlotHold` vencidos (doc 09 §6.2). Em teste sobe em modo
      # manual (config/test.exs), sem cron nem filas.
      {Oban, Application.fetch_env!(:api, Oban)},
      # Start to serve requests, typically the last entry
      ApiWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :api]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Api.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
