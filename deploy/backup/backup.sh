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
  # HEARTBEAT_SLUG_PREFIX (`prod-`, `hml-`) permite que os dois ambientes dividam uma chave de
  # projeto e ainda tenham checks distintos. Vazio quando cada um tem projeto próprio.
  hb_url="${HEARTBEAT_BASE_URL%/}/${HEARTBEAT_SLUG_PREFIX:-}backup"
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

# ---- Preflight de espaço (R-M11, doc 95) ------------------------------------------------------
# O `mktemp -d` agora cai no volume dedicado (`TMPDIR=/var/tmp/backup`, no compose), o que torna o
# espaço do dump contável e limitável. Mas numa VPS de disco único esse volume continua no MESMO
# dispositivo do `pgdata` — o "fora do disco do banco" que o achado pedia não existe aqui. Então
# quem de fato protege é esta conferência, e ela só serve ANTES de começar: abortar no meio do
# `pg_dump` já consumiu o espaço.
#
# Agravante que torna isto mais que higiene: o serviço `backup` roda ANTES do `migrate` e é
# fail-closed. Disco cheio durante o dump vira **deploy travado** por cima de disco cheio — e o
# deploy travado costuma ser justamente o hotfix do incidente.
#
# `pg_database_size` é um teto GENEROSO para o dump: inclui índices, que o `--format=custom` não
# escreve, e o formato ainda comprime. Exigir espaço livre >= tamanho do banco é conservador de
# propósito — o erro que se quer evitar é o otimista.
banco=$(psql -tAc "select pg_database_size(current_database())" | tr -d '[:space:]')
livre=$(( $(df -Pk "$tmp" | awk 'NR==2 {print $4}') * 1024 ))
minimo=$(( banco * ${BACKUP_FOLGA_PCT:-100} / 100 ))

echo "[backup] espaço: livre=$(( livre / 1048576 ))MiB · banco=$(( banco / 1048576 ))MiB · mínimo=$(( minimo / 1048576 ))MiB"

if [ "$livre" -lt "$minimo" ]; then
  echo "[backup] ABORTANDO: espaço livre insuficiente em $tmp" >&2
  echo "[backup] o dump encheria o disco do pgdata — e o deploy trava fail-closed logo atrás" >&2
  exit 1
fi

dump="$tmp/${STACK}-${stamp}.dump"
echo "[backup] pg_dump ${PGDATABASE}@${PGHOST:-db} -> $(basename "$dump")"
pg_dump --format=custom --file="$dump"   # host/user/senha/db via PG* do ambiente

# ---- Verificação de integridade (R-M10, doc 95) ----------------------------------------------
# Entre gerar e declarar sucesso não havia NENHUMA leitura do arquivo. Um dump truncado — disco
# cheio no meio do `pg_dump`, que é o cenário do R-M11, onde este `mktemp` divide disco com o
# `pgdata` — subia inteiro para o R2 e o heartbeat mandava "ok".
#
# Isso é pior que não monitorar: o sinal que existe para responder "o backup está vivo?" passa a
# responder sim para um arquivo que não restaura, e a descoberta fica para o dia do incidente.
# O `restore.sh` já dizia a frase certa ("backup não testado não é backup") e dependia de um
# humano lembrar.
#
# ATENÇÃO ao editar esta linha: `pg_restore --list` NÃO serve, e era o que o doc 95 recomendava.
# Ele lê só o TOC, que no formato custom fica no INÍCIO do arquivo — então ele sai 0 sobre um dump
# em que todo o dado foi perdido. Medido contra o `db` em 2026-08-04, três arquivos:
#
#   dump              | pg_restore --list | pg_restore -f /dev/null
#   íntegro           | 0 (571 entradas)  | 0
#   cortado ao meio   | 0  <-- o buraco   | 1  "could not read from input file: end of file"
#   512 bytes zerados | 0  <-- o buraco   | 1  "could not uncompress data: incorrect data check"
#
# `-f /dev/null` converte o arquivo inteiro em SQL e joga fora: obriga a LER e descomprimir cada
# bloco de dado, que é o que detecta truncamento e corrupção. Não conecta em banco nenhum (sem
# `-d`), então não toca a produção. Custo medido: 34 ms contra 27 ms do `--list`, ~17% do tempo do
# próprio `pg_dump` — proporcional ao tamanho do dump, e barato o bastante para rodar de hora em
# hora.
#
# O que ele NÃO prova: que as LINHAS certas estão lá. É integridade do arquivo, não completude do
# dado — essa é o ensaio de restore (item 1.8 do doc 102), que nenhuma linha de script substitui.
#
# Sob o `set -e` do topo, a saída != 0 aborta o script; e como o `trap ... ERR` já está armado
# acima, a falha vira `/fail` no monitor externo em vez de silêncio.
echo "[backup] verificando integridade do dump"
pg_restore -f /dev/null "$dump"

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
