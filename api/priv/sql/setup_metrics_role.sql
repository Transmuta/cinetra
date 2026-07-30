-- Role de LEITURA para o Grafana (doc 73). Idempotente; roda como `postgres` (owner), depois
-- das migrations — as views `metrics_*` precisam existir para receber o GRANT.
--
-- Espelho em dev de `Api.Release.setup_metrics_role/0`, que é quem roda em produção (lá a senha
-- vem de `DATABASE_METRICS_PASSWORD`, e sem ela o role simplesmente não é criado).
--
--   docker compose exec -T db psql -U postgres -d cinetra_dev \
--     -v ON_ERROR_STOP=1 -v senha="$METRICS_DB_PASSWORD" \
--     -f - < api/priv/sql/setup_metrics_role.sql
--
-- O que este role PODE: `SELECT` nas views `metrics_*`.
-- O que ele NÃO pode, e é o ponto: ler tabela. Sem `GRANT` em `patients`, `messages` ou
-- `audit_events`, um `SELECT * FROM patients` responde `permission denied` — a barreira é
-- privilégio do Postgres, não disciplina de quem escreve o painel.
--
-- ## A senha vem de fora, e nem em dev há default (bate-volta doc 77 §5.2)
--
-- Aqui havia `PASSWORD 'cinetra_metrics'` escrito no arquivo. O risco não era o dev: era este
-- arquivo ser aplicado contra PRODUÇÃO — o comando acima é o que se copia e cola —, criando lá um
-- usuário de leitura com senha publicada no repositório. E como as views rodam com os direitos do
-- DONO (ignoram RLS por construção), esse usuário lê o agregado de todas as clínicas.
--
-- Ao lado, o Grafana já exigia a dele com `:?` e recusava subir sem ela. Eram duas posturas para
-- dois segredos do mesmo stack; agora é uma.
--
-- O mínimo de 8 caracteres também cobre o caso em que a variável existe VAZIA: `psql` interpola
-- variável não-definida como `''`, e sem esta guarda o script criaria o role com senha vazia — que
-- é pior que o default, porque ninguém percebe.

-- Variável AUSENTE e variável VAZIA são casos diferentes, e o primeiro precisa desta linha.
--
-- Quando `senha` não foi definida, o `psql` **não** substitui `:'senha'` por nada: ele deixa os
-- caracteres no lugar, e o servidor recebe `:'senha'` como SQL. Medido — o script morria em
-- `ERROR: syntax error at or near ":"`, que aborta e não cria nada (seguro), mas não diz a quem
-- rodou o que fazer. Definindo a variável como vazia aqui, a guarda abaixo é que responde.
\if :{?senha}
\else
  \set senha ''
\endif

-- A guarda vem ANTES de qualquer DDL: com `ON_ERROR_STOP=1` o script sai != 0 e nada é criado nem
-- alterado. O mínimo de 8 pega tanto a ausência (vazia, pela linha acima) quanto o `-v senha=`
-- digitado pela metade.
--
-- O `DO` é GERADO por `format/2` em vez de escrito à mão porque o `psql` não interpola variável
-- dentro de `$$…$$` — o lexer dele trata dollar-quote como literal opaco. Mesmo motivo do `\gexec`
-- nos dois comandos seguintes.
SELECT format(
         'DO $guard$ BEGIN RAISE EXCEPTION %L; END $guard$',
         'senha do role de metricas ausente ou curta: rode com -v senha="$METRICS_DB_PASSWORD" (minimo 8 caracteres)'
       )
 WHERE length(:'senha') < 8
\gexec

-- `CREATE` só quando falta: zero linhas no `SELECT` faz o `\gexec` não executar nada.
SELECT format(
         'CREATE ROLE cinetra_metrics LOGIN PASSWORD %L NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE',
         :'senha'
       )
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cinetra_metrics')
\gexec

-- `ALTER` sempre: rodar de novo com uma senha nova a aplica, em vez de o script virar no-op e
-- deixar o role com a senha antiga sem avisar.
SELECT format('ALTER ROLE cinetra_metrics PASSWORD %L', :'senha')
\gexec

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
