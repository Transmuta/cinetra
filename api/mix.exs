defmodule Api.MixProject do
  use Mix.Project

  def project do
    [
      app: :api,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      # Cobertura via ExCoveralls. Threshold e arquivos ignorados vivem em coveralls.json;
      # `mix coveralls` falha o build abaixo do mínimo (o gate do CI).
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Api.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:picosat_elixir, "~> 0.2"},
      {:hammer, "~> 7.0"},
      {:ash_authentication, "~> 4.0"},
      {:ash_authentication_phoenix, "~> 2.0"},
      {:swoosh, "~> 1.16"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      # Trilha de auditoria (A-D6c, doc 25 §11): uma linha por escrita em `Appointment` e
      # `Attendance`. Escolhida sobre as duas colunas de autoria porque `updated_by_id`
      # sobrescreve o autor anterior — numa tela operada por 3–4 pessoas, a remarcação some.
      {:ash_paper_trail, "~> 0.6"},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.0"},
      # Backstop de limpeza dos `SlotHold` vencidos (doc 09 §6.2): um cron de 1 min apaga o que
      # ninguém tentou reservar. A garantia da corrida NÃO depende dele — é a exclusion constraint
      # + o `DELETE` in-transaction da própria `offer`; o Oban é só higiene.
      {:oban, "~> 2.18"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.9"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # Métricas Prometheus da BEAM, do Ecto, do Oban e do Phoenix (doc 74). O log já respondia
      # "o que a aplicação fez"; isto responde "em que estado ela está" — fila do pool, memória
      # do processo, latência de fila do Oban. Serve num servidor PRÓPRIO (porta 4021), não pelo
      # router: o `/metrics` não pode passar por rate limit, autenticação de sessão nem
      # RequestLogger, e não pode existir rota que o Traefik possa expor por acidente.
      {:prom_ex, "~> 1.12"},
      # ---- Traces (doc 76) ----------------------------------------------------------------------
      #
      # O terceiro sinal. As métricas acima dizem que o p95 subiu; o trace diz em QUE consulta, de
      # qual requisição, com o span do BFF por cima. São seis pacotes porque o OTel separa API de
      # implementação de propósito: `_api` é o que o código chama, `opentelemetry` é o SDK que
      # coleta, `_exporter` é quem fala OTLP, e os três de instrumentação só pendurram handlers de
      # `:telemetry` que já existiam.
      #
      # Nada disto tem efeito sem `OTEL_EXPORTER_OTLP_ENDPOINT` (ver runtime.exs): sem a variável o
      # exportador é `:none`, os spans nascem e morrem em memória. É o que mantém dev e teste
      # inalterados para quem não subiu o stack de observabilidade.
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"},
      # `_bandit` e `_phoenix` são complementares, não alternativos: o primeiro abre o span do
      # SERVIDOR (chega byte, sai byte, e é ele quem lê o `traceparent` que o BFF mandou); o
      # segundo acrescenta o que só o framework sabe — rota do router, controller, action.
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      # O trace atravessa a fila: o job carrega o contexto de quem o enfileirou. É o mesmo buraco
      # que `Api.Correlacao` fechou com `request_id` no `meta` — aqui ele fecha de novo, agora com
      # a árvore inteira em vez de só o id.
      {:opentelemetry_oban, "~> 1.2"},
      # Log em JSON, uma linha por evento (doc 62 §7.1). É a única dep aqui que poderia ter sido
      # escrita à mão — e não foi, de propósito: o formatter precisa encodar metadata arbitrária
      # (pid, ref, tupla, função) sem estourar, e um formatter que levanta derruba o logger, que
      # é o pior lugar do sistema para ter um bug próprio.
      {:logger_json, "~> 7.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Base de fusos IANA. Sem ela `Clinic.timezone` (ADR-009) é decorativo: converter
      # data+hora local da clínica para o `:utc_datetime` do agendamento (25 §A2) exige
      # `DateTime.new/4`, que precisa de uma time zone database instalada.
      {:tz, "~> 0.28"},
      # Cliente HTTP do adaptador de storage (doc 51). Já estava na árvore como transitiva; entra
      # como direta porque `Api.Storage.R2` a chama. É a ÚNICA dependência que os anexos
      # acrescentam: a assinatura SigV4 é nossa (`Api.Storage.SigV4`), o que dispensou
      # `ex_aws` + `ex_aws_s3` + `sweet_xml` + `hackney`.
      {:req, "~> 0.6"},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      test: [&skippable_ash_setup/1, "test"]
    ]
  end

  # `mix test` normalmente prepara o banco antes (criar + migrar). Isso exige DDL, que só o
  # usuário privilegiado tem.
  #
  # O gate de RLS (`mix test --only rls`, job `api-rls` do CI) roda como `cinetra_app` —
  # NOBYPASSRLS e, por desenho, **sem CREATE no schema**. Ali o setup precisa ter sido feito
  # antes, como `postgres`, e esta etapa tem de sair do caminho: sem isso o alias derruba a
  # suíte com `ERROR 42501 permission denied for schema public` antes de rodar um teste.
  #
  # A alternativa seria conceder CREATE ao role restrito. Não: o gate existe justamente para
  # rodar com os privilégios de produção, e afrouxá-los para o teste passar esvazia o gate.
  defp skippable_ash_setup(_args) do
    if System.get_env("SKIP_DB_SETUP") in ["1", "true"] do
      :ok
    else
      Mix.Task.run("ash.setup", ["--quiet"])
    end
  end
end
