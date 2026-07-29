-- Role de LEITURA para o Grafana (doc 73). Idempotente; roda como `postgres` (owner), depois
-- das migrations — as views `metrics_*` precisam existir para receber o GRANT.
--
-- Espelho em dev de `Api.Release.setup_metrics_role/0`, que é quem roda em produção (lá a senha
-- vem de `DATABASE_METRICS_PASSWORD`, e sem ela o role simplesmente não é criado).
--
--   docker compose exec -T db psql -U postgres -d movimento_dev -f - < api/priv/sql/setup_metrics_role.sql
--
-- O que este role PODE: `SELECT` nas views `metrics_*`.
-- O que ele NÃO pode, e é o ponto: ler tabela. Sem `GRANT` em `patients`, `messages` ou
-- `audit_events`, um `SELECT * FROM patients` responde `permission denied` — a barreira é
-- privilégio do Postgres, não disciplina de quem escreve o painel.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cinetra_metrics') THEN
    CREATE ROLE cinetra_metrics LOGIN PASSWORD 'cinetra_metrics'
      NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO cinetra_metrics;

-- Laço em vez de lista escrita à mão: view nova entra sozinha, e é o `LIKE` que define o
-- contrato. NADA de `ALTER DEFAULT PRIVILEGES` aqui — tabela nova não deve nascer legível.
DO $$
DECLARE v text;
BEGIN
  FOR v IN SELECT viewname FROM pg_views
            WHERE schemaname = 'public' AND viewname LIKE 'metrics\_%'
  LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO cinetra_metrics', v);
  END LOOP;
END
$$;
