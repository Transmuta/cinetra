#!/usr/bin/env bash
# Restaura um backup do R2 para um banco ALVO. Runbook: docs/59-deploy-dokploy-oci.md §13.
#
# PRATIQUE isto de tempos em tempos — backup não testado não é backup. Restaure para um banco
# SEPARADO e extraia as linhas; raramente se sobrescreve prod inteiro.
#
# Uso: /restore.sh <objeto-no-bucket> <database-alvo>
#   ex: /restore.sh prod/daily/prod-20260726.dump.age movimento_restore
#
# Se o objeto for .age, precisa da chave PRIVADA age em BACKUP_AGE_IDENTITY (caminho de arquivo),
# que vive FORA do servidor e você monta só na hora do restore.
set -euo pipefail

obj="${1:?objeto no bucket, ex: prod/daily/prod-YYYYMMDD.dump.age}"
target="${2:?database alvo}"
: "${BACKUP_BUCKET:?BACKUP_BUCKET obrigatório}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
f="$tmp/backup"

echo "[restore] baixando R2:${BACKUP_BUCKET}/${obj}"
rclone copyto "R2:${BACKUP_BUCKET}/${obj}" "$f"

if [[ "$obj" == *.age ]]; then
  : "${BACKUP_AGE_IDENTITY:?chave privada age necessária p/ decifrar (fica offline, monte só agora)}"
  echo "[restore] decifrando com age"
  age -d -i "$BACKUP_AGE_IDENTITY" -o "$f.dump" "$f"
  f="$f.dump"
fi

echo "[restore] createdb ${target} (ignora se já existe) + pg_restore"
createdb "$target" 2>/dev/null || true
pg_restore --no-owner --dbname="$target" "$f"
echo "[restore] ok -> ${target}"
