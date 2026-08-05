defmodule Api.Release do
  @moduledoc """
  Tarefas de release para produção (sem Mix). Rodam a partir do release compilado — no Dokploy
  pelo serviço `migrate` (`bin/api eval Api.Release.setup()`, `compose.dokploy.yml`), que roda até
  o fim antes de a API subir. Conectam como o role **owner** (`DATABASE_ADMIN_URL`): fazem DDL e
  criam o role restrito. O app de longa duração conecta como o role **restrito**
  (`DATABASE_URL` = `cinetra_app`, NOBYPASSRLS) e fica sujeito à RLS (ADR-018).

  - `setup/0`   — roda migrations e provisiona os roles (a ordem importa: tabelas antes
                  dos grants).
  - `migrate/0` — só as migrations.
  - `setup_app_role/0` — cria/garante `DATABASE_APP_USER` (NOBYPASSRLS) + grants (ADR-018).
  - `setup_metrics_role/0` — cria/garante `cinetra_metrics` (só leitura das views `metrics_*`,
                  doc 73). **Ausente a senha, não faz nada** — o painel de banco é opcional.
  """
  @app :api

  def setup do
    migrate()
    setup_app_role()
    setup_metrics_role()
  end

  def migrate do
    load_app()

    with_admin_config(fn ->
      for repo <- repos() do
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
      end
    end)
  end

  @doc """
  Provisiona o role restrito do app (RLS, ADR-018). Idempotente. Roda como owner (o `migrate`
  service usa a `DATABASE_URL` de admin). Espelha `priv/sql/setup_app_role.sql` do dev, mas
  parametriza usuário/senha por env.
  """
  def setup_app_role do
    load_app()
    user = System.fetch_env!("DATABASE_APP_USER")
    pass = System.fetch_env!("DATABASE_APP_PASSWORD")
    validate_identifier!(user)

    with_admin_config(fn ->
      {:ok, _, _} =
        Ecto.Migrator.with_repo(Api.Repo, fn repo ->
          Enum.each(role_statements(user, pass), &Ecto.Adapters.SQL.query!(repo, &1))
          :ok
        end)
    end)

    :ok
  end

  @doc """
  Provisiona o role de **leitura** que o Grafana usa (doc 73). Idempotente, roda como owner.

  Três diferenças em relação ao role do app, e as três são a razão de existir uma função separada:

    * **só `SELECT`**, e só nas views `metrics_*` — nunca em tabela. A view é o allowlist de
      colunas (ver a migration `MetricsViews`); dar `SELECT` na tabela devolveria CPF e texto livre
      para dentro de uma UI web.
    * **sem `ALTER DEFAULT PRIVILEGES`.** É deliberado: tabela nova criada por um `ash.codegen`
      futuro **não** deve nascer legível. Só o que passar por view nova entra, e o `GRANT` roda de
      novo aqui a cada deploy.
    * **ausente = desligado.** Sem `DATABASE_METRICS_PASSWORD` o role não é criado, e os painéis de
      banco ficam com erro de datasource — visível, que é como uma ausência deve se comportar.
  """
  def setup_metrics_role do
    load_app()

    case System.get_env("DATABASE_METRICS_PASSWORD") do
      senha when is_binary(senha) and senha != "" ->
        user = System.get_env("DATABASE_METRICS_USER", "cinetra_metrics")
        validate_identifier!(user)

        with_admin_config(fn ->
          {:ok, _, _} =
            Ecto.Migrator.with_repo(Api.Repo, fn repo ->
              Enum.each(metrics_role_statements(user, senha), &Ecto.Adapters.SQL.query!(repo, &1))
              :ok
            end)
        end)

        :ok

      _ ->
        :desligado
    end
  end

  defp metrics_role_statements(user, pass) do
    quoted_pass = "'" <> String.replace(pass, "'", "''") <> "'"

    [
      """
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{user}') THEN
          CREATE ROLE #{user} LOGIN PASSWORD #{quoted_pass}
            NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
        ELSE
          ALTER ROLE #{user} LOGIN PASSWORD #{quoted_pass}
            NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
        END IF;
      END $$;
      """,
      "GRANT USAGE ON SCHEMA public TO #{user}",
      # O laço substitui uma lista escrita à mão que ficaria desatualizada na primeira view nova.
      # `LIKE 'metrics\\_%'` com o underscore escapado — sem a barra, `_` é curinga de um caractere
      # e o filtro casaria `metricsX...`.
      """
      DO $$
      DECLARE v text;
      BEGIN
        FOR v IN SELECT viewname FROM pg_views
                  WHERE schemaname = 'public' AND viewname LIKE 'metrics\\_%'
        LOOP
          EXECUTE format('GRANT SELECT ON public.%I TO #{user}', v);
        END LOOP;
      END $$;
      """
    ]
  end

  # `user` é validado como identificador SQL; a senha é escapada (aspas dobradas). CREATE ROLE
  # não aceita bind params, então interpolamos com cuidado.
  defp role_statements(user, pass) do
    quoted_pass = "'" <> String.replace(pass, "'", "''") <> "'"

    [
      """
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{user}') THEN
          CREATE ROLE #{user} LOGIN PASSWORD #{quoted_pass}
            NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
        END IF;
      END $$;
      """,
      "GRANT USAGE ON SCHEMA public TO #{user}",
      "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{user}",
      "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{user}",
      "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO #{user}",
      "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO #{user}",
      "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO #{user}",
      "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO #{user}"
    ]
  end

  defp validate_identifier!(user) do
    unless Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/i, user) do
      raise ArgumentError,
            "o usuário do banco deve ser um identificador SQL simples, recebido: #{inspect(user)}"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  # Roda `fun` com o Repo apontado para a conexão de OWNER (`DATABASE_ADMIN_URL`) — migrations/DDL
  # e criação do role restrito. O serviço `migrate` e a API compartilham o mesmo `.env` do stack,
  # então separamos por variável: admin aqui, `DATABASE_URL` (restrito) no runtime do app.
  # Sobrescreve a config **antes** do `with_repo` (o `url:` opt do with_repo não sobrepõe a url do
  # runtime.exs).
  # Sem `DATABASE_ADMIN_URL`, usa a config atual (setups onde a `DATABASE_URL` já é de owner).
  #
  # **Público com `@doc false` só para ser testável** (R-M23, onda 3 do doc 102). Não é API: é o
  # trecho mais perigoso do caminho de deploy, e a regressão que ele guarda não tem sintoma
  # visível. Se o `after` deixar de restaurar a config, o processo segue com o Repo apontando para
  # a conexão de OWNER — e, num setup onde a API subisse no mesmo nó, ela passaria a ler
  # **bypassando a RLS**. A suíte não veria: ela já roda como superusuário, e é justamente essa
  # cegueira que o job `api-rls` existe para compensar em outro lugar.
  @doc false
  def with_admin_config(fun) do
    case System.get_env("DATABASE_ADMIN_URL") do
      nil ->
        fun.()

      admin ->
        original = Application.get_env(@app, Api.Repo, [])
        Application.put_env(@app, Api.Repo, Keyword.put(original, :url, admin))

        try do
          fun.()
        after
          Application.put_env(@app, Api.Repo, original)
        end
    end
  end

  defp load_app, do: Application.load(@app)
end
