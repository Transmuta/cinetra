#!/usr/bin/env bash
# Backup lógico do Postgres -> R2 (bucket privado, SEPARADO do bucket de anexos).
# Runbook: docs/59-deploy-dokploy-oci.md §13.
#
# - Roda como pg_dump do OWNER (postgres) para capturar TODAS as linhas (bypassa RLS).
# - Retenção em DOIS níveis, self-contained via `rclone --min-age` (NÃO depende de lifecycle do R2):
#     hourly/  -> granularidade fina, mantida HOURLY_RETENTION (default 48h)
#     daily/   -> um objeto por dia (sobrescrito no mesmo dia), mantido DAILY_RETENTION (default 30d)
# - LGPD: se BACKUP_AGE_RECIPIENT (chave PÚBLICA age) estiver setado, cifra antes de subir. O
#   servidor cifra mas NÃO decifra — a chave privada fica offline, usada só no restore.
#
# Uso: /backup.sh   (roda UMA vez). O agendamento fica no compose (serviço backup-cron).
set -euo pipefail

: "${STACK:?STACK obrigatório (prod|hml)}"
: "${BACKUP_BUCKET:?BACKUP_BUCKET obrigatório}"
: "${PGDATABASE:?PGDATABASE obrigatório}"

day="$(date -u +%Y%m%d)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dump="$tmp/${STACK}-${stamp}.dump"
echo "[backup] pg_dump ${PGDATABASE}@${PGHOST:-db} -> $(basename "$dump")"
pg_dump --format=custom --file="$dump"   # host/user/senha/db via PG* do ambiente

upload="$dump"; ext="dump"
if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  echo "[backup] cifrando com age (recipient ${BACKUP_AGE_RECIPIENT})"
  age -r "$BACKUP_AGE_RECIPIENT" -o "$dump.age" "$dump"
  upload="$dump.age"; ext="dump.age"
fi

hourly="R2:${BACKUP_BUCKET}/${STACK}/hourly/${STACK}-${stamp}.${ext}"
daily="R2:${BACKUP_BUCKET}/${STACK}/daily/${STACK}-${day}.${ext}"   # 1 por dia; re-run sobrescreve

echo "[backup] upload -> ${hourly}"
rclone copyto "$upload" "$hourly"
echo "[backup] upload (daily de hoje) -> ${daily}"
rclone copyto "$upload" "$daily"

# Poda: apaga objetos mais velhos que a retenção de cada nível. Não falha o backup se a poda falhar
# (o upload, que é o que importa, já ocorreu).
echo "[backup] poda hourly > ${HOURLY_RETENTION:-48h} · daily > ${DAILY_RETENTION:-30d}"
rclone delete --min-age "${HOURLY_RETENTION:-48h}" "R2:${BACKUP_BUCKET}/${STACK}/hourly" || true
rclone delete --min-age "${DAILY_RETENTION:-30d}"  "R2:${BACKUP_BUCKET}/${STACK}/daily"  || true

echo "[backup] ok"
