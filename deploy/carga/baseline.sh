#!/usr/bin/env bash
#
# Fotografa o estado do servidor para comparar antes/depois do teste de carga.
#
#   ./baseline.sh antes      # com a máquina em repouso, ANTES de qualquer carga
#   ./baseline.sh depois     # logo ao fim do teste, ANTES de apagar o dado sintético
#   ./baseline.sh limpeza    # depois de apagar tudo — é o que prova que a limpeza fechou
#
# Por que existe: o Prometheus guarda node/cAdvisor/PromEx sozinho (30 d), mas **não há
# postgres_exporter** nos 4 jobs do `prometheus.yml` — o banco é ponto cego do Grafana. E os
# contadores de `pg_stat_*` são cumulativos: sem a foto do "antes", o "depois" não tem subtraendo.
#
# Variáveis (exporte antes de rodar, no servidor):
#   DB_CONTAINER   nome do container do Postgres de PROD (obrigatório)
#   PGDATABASE     banco (default: cinetra_prod)
#   DEST           onde gravar (default: ./medicoes)

set -euo pipefail

FASE="${1:?uso: $0 antes|depois|limpeza}"
DB_CONTAINER="${DB_CONTAINER:?exporte DB_CONTAINER com o nome do container do Postgres}"
PGDATABASE="${PGDATABASE:-cinetra_prod}"
DEST="${DEST:-$(dirname "$0")/medicoes}"

CARIMBO="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$DEST/$CARIMBO-$FASE"
mkdir -p "$OUT"

# `psql` como superusuário: estas são views globais do cluster, não dado por-tenant — a RLS não
# se aplica e o role do app não enxerga `pg_stat_statements` de outras sessões.
psql() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d "$PGDATABASE" -X -A -F$'\t' --pset=footer=off "$@"
}

echo "→ gravando em $OUT"

# ---------------------------------------------------------------------------
# 1. Marcos de tempo — é o que cola esta foto às janelas do Grafana.
#    O epoch em ms entra direto na URL do painel (?from=...&to=...).
# ---------------------------------------------------------------------------
{
  echo "fase=$FASE"
  echo "utc=$(date -u --iso-8601=seconds)"
  echo "local=$(date --iso-8601=seconds)"
  echo "epoch_ms=$(($(date +%s) * 1000))"
  echo "uptime=$(uptime)"
} > "$OUT/marcos.txt"

# ---------------------------------------------------------------------------
# 2. Postgres — os contadores que somem e os tamanhos que crescem.
# ---------------------------------------------------------------------------

# Quais índices foram de fato usados. O diff antes/depois responde duas perguntas de uma vez:
# quais índices o caminho da aplicação exercita, e quais nunca foram tocados (doc 35, lição D-A).
psql -c "
  select schemaname, relname, indexrelname, idx_scan, idx_tup_read, idx_tup_fetch,
         pg_relation_size(indexrelid) as bytes
  from pg_stat_user_indexes
  order by relname, indexrelname;
" > "$OUT/pg_stat_user_indexes.tsv"

# Seq scan vs index scan por tabela, tuplas mortas e autovacuum. `n_dead_tup` no 'depois' é o que
# diz se o teste deixou bloat, e o 'limpeza' é onde o DELETE em massa aparece.
psql -c "
  select relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
         n_tup_ins, n_tup_upd, n_tup_del, n_live_tup, n_dead_tup,
         last_autovacuum, autovacuum_count, last_autoanalyze
  from pg_stat_user_tables
  order by relname;
" > "$OUT/pg_stat_user_tables.tsv"

# Cache hit ratio, deadlocks, transações. O `blks_hit/(blks_hit+blks_read)` caindo sob carga é o
# sinal de que o working set passou do shared_buffers.
psql -c "
  select numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
         tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
         conflicts, temp_files, temp_bytes, deadlocks,
         blk_read_time, blk_write_time
  from pg_stat_database where datname = current_database();
" > "$OUT/pg_stat_database.tsv"

# Contagem de linhas EXATA por tabela. É o subtraendo que prova a limpeza — `n_live_tup` acima é
# estimativa do autovacuum e não serve para isso.
psql -c "
  select table_name,
         (xpath('/row/c/text()', contagem))[1]::text::bigint as linhas
  from (
    select table_name,
           query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name),
                        false, true, '') as contagem
    from information_schema.tables
    where table_schema = 'public' and table_type = 'BASE TABLE'
  ) t
  order by table_name;
" > "$OUT/contagens.tsv"

# Tamanho em disco, tabela + índices.
psql -c "
  select relname,
         pg_total_relation_size(c.oid) as total_bytes,
         pg_relation_size(c.oid)       as tabela_bytes,
         pg_indexes_size(c.oid)        as indices_bytes
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
  order by pg_total_relation_size(c.oid) desc;
" > "$OUT/tamanhos.tsv"

# Configuração que decide o teto. `max_connections` contra o `pool_size: 16` da API é a primeira
# conta a fechar; `shared_buffers` e `work_mem` explicam o joelho quando ele aparecer.
psql -c "
  select name, setting, unit from pg_settings
  where name in ('max_connections','shared_buffers','work_mem','effective_cache_size',
                 'maintenance_work_mem','max_wal_size','checkpoint_timeout',
                 'random_page_cost','shared_preload_libraries','autovacuum')
  order by name;
" > "$OUT/pg_settings.tsv"

# Conexões abertas agora, por estado e por aplicação. No 'depois' mostra se o pool saturou.
psql -c "
  select coalesce(application_name,'?') as app, usename, state, count(*)
  from pg_stat_activity where datname = current_database()
  group by 1,2,3 order by 4 desc;
" > "$OUT/conexoes.tsv"

# pg_stat_statements só existe se `shared_preload_libraries` o carregar. Sem ele, a pergunta
# "qual query custou o quê" fica sem resposta — e não dá para responder retroativamente.
if psql -t -c "select 1 from pg_extension where extname='pg_stat_statements';" | grep -q 1; then
  psql -c "
    select calls, total_exec_time, mean_exec_time, max_exec_time, rows, query
    from pg_stat_statements
    order by total_exec_time desc limit 100;
  " > "$OUT/pg_stat_statements.tsv"
else
  echo "AUSENTE: pg_stat_statements não está instalado — a pergunta 'qual query custou o quê' \
ficará sem resposta neste teste. Exige shared_preload_libraries + restart do Postgres." \
    > "$OUT/pg_stat_statements.AUSENTE.txt"
fi

# ---------------------------------------------------------------------------
# 3. Host — disco é o modo de falha nº 1 (doc 87 §4.1), e o teste alimenta o Loki.
# ---------------------------------------------------------------------------
{
  echo "===== df -h ====="; df -h
  echo; echo "===== free -m ====="; free -m
  echo; echo "===== docker system df ====="; docker system df -v 2>/dev/null || docker system df
  echo; echo "===== docker stats (instantâneo) ====="
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}'
  echo; echo "===== containers ====="; docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
} > "$OUT/host.txt" 2>&1

echo "✓ $FASE gravado em $OUT"
echo
grep epoch_ms "$OUT/marcos.txt"
echo "  ↑ use este epoch nas URLs do Grafana (?from=<inicio>&to=<fim>)"
