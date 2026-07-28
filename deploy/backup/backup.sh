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

# ---- Heartbeat (docs/62 §9) -------------------------------------------------------------------
# O docs/59 §13 nomeou este buraco e o deixou aberto: "alerta se o backup-cron parar — backup que
# morre em silêncio só aparece no dia do incidente". O `set -e` acima faz o script SAIR com código
# != 0, e ninguém fica sabendo: o gatilho pré-deploy trava o deploy (fail-closed, ok), mas o cron
# de 1 em 1 hora morre calado.
#
# Nenhum log resolve isto, porque a falha aqui é AUSÊNCIA de execução — não há linha para ler. Só
# um vigia de fora, que espera o sinal e reclama quando ele não vem.
#
# A URL sai de HEARTBEAT_BASE_URL + "/backup" (mesma raiz que a API usa, uma env por ambiente),
# ou de HEARTBEAT_URL_BACKUP se alguém quiser sobrescrever só este. Nenhuma das duas = desligado,
# que é o caso de dev e de qualquer ambiente sem monitor.
hb_url=""
if [ -n "${HEARTBEAT_URL_BACKUP:-}" ]; then
  hb_url="$HEARTBEAT_URL_BACKUP"
elif [ -n "${HEARTBEAT_BASE_URL:-}" ]; then
  hb_url="${HEARTBEAT_BASE_URL%/}/backup"
fi

sinal() {
  [ -n "$hb_url" ] || return 0
  # `|| true`: o heartbeat NUNCA pode ser o motivo de um backup falhar. -m limita o tempo total,
  # senão um monitor fora do ar seguraria o script.
  curl -fsS -m 10 "${hb_url}${1:-}" -o /dev/null || true
}

# Dispara em QUALQUER saída não-zero, inclusive `set -e` no meio do pg_dump ou do upload. Sem o
# trap, só o caminho feliz avisaria — e o silêncio voltaria a significar as duas coisas ao mesmo
# tempo ("rodou bem" e "nem rodou").
trap 'sinal /fail' ERR

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

# Só aqui: o sinal de sucesso vem DEPOIS do upload confirmado. Sinalizar antes diria "estou vivo"
# para um backup que não subiu — que é o pior resultado possível, pior que não monitorar.
sinal
echo "[backup] ok"
