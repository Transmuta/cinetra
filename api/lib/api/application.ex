defmodule Api.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Log estruturado (doc 62 §7.1). Os dois handlers são anexados antes da árvore subir, para
    # que nenhuma requisição ou job do boot escape sem registro.
    ApiWeb.RequestLogger.attach()

    # O Oban era MUDO — `attach_default_logger/1` nunca havia sido chamado. Com o Pruner apagando
    # `oban_jobs` em 7 dias, "por que o lembrete não saiu na terça" não tinha como ser respondido.
    Oban.Telemetry.attach_default_logger(level: :info, encode: false)

    # Sinal de vida dos crons para um monitor externo (doc 62 §9). No-op quando não há URL
    # configurada, que é o caso de dev e teste.
    Api.Heartbeat.attach()

    children = [
      ApiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:api, :dns_cluster_query) || :ignore},
      Api.Repo,
      # Rate limiters (Hammer/ETS). Sobem em todos os ambientes; a enforcement é gated a prod
      # nos plugs (auditoria doc 13, causa A). São DOIS, com tabelas separadas: janela deslizante
      # para o anti-brute-force de auth (preciso, volume baixo) e janela fixa para o limite global
      # (O(1), tráfego inteiro) — a separação está justificada em cada moduledoc (doc 68, causa A).
      {Api.RateLimiter, [clean_period: :timer.minutes(1)]},
      {Api.RateLimiter.Global, [clean_period: :timer.minutes(1)]},
      {Phoenix.PubSub, name: Api.PubSub},
      # Cache do fuso da clínica (D-K). Depende do PubSub — é por ele que a invalidação de um
      # nó chega aos outros (`:persistent_term` é por-nó).
      Api.Accounts.ClinicTimezone,
      # Presença de sockets (doc 39): quem está oferecendo qual vaga, agora. Depende do PubSub.
      ApiWeb.Presence,
      # Oban — sem cron desde a remoção da reserva de vaga (doc 39); a fila `housekeeping` fica
      # de pé para o trabalho assíncrono da Fatia 3 (Pacotes). Em teste sobe em modo manual.
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
