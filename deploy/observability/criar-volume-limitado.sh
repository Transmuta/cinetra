#!/usr/bin/env bash
# Cria um sistema de arquivos de TAMANHO FIXO para os dados do Loki (doc 62 §3.4).
#
# ## Por que existe
#
# O Loki **não tem limite de armazenamento**. Ele tem retenção por tempo (`retention_period`) e
# limite de taxa (`ingestion_rate_mb`) — nenhum dos dois é um teto de espaço em disco. Com tudo
# numa máquina só e os chunks em disco local (decidido em 2026-07-28), o volume do Loki divide o
# disco com o `pgdata`: um log em laço não enche só o log, **derruba o Postgres junto**.
#
# Quem impõe o teto é o sistema de arquivos. Este script cria um arquivo esparso de tamanho fixo,
# formata, monta e entrega o ponto de montagem para o compose usar como bind mount. A partir daí o
# Loki fisicamente não consegue passar do limite — e o que estoura é o Loki, não o banco.
#
# ## O que acontece quando enche
#
# O Loki passa a falhar ao gravar chunk, o agente acumula erro de entrega e as linhas viram
# descarte. **Isso é detectável**: o `verificar.sh` §9 acusa "descarte EM CURSO" e o alerta
# "Pipeline de log parado" dispara em 10 min. Degradar de forma visível é o objetivo — o que não
# se pode aceitar é o disco cheio derrubando o banco em silêncio.
#
# ## Alternativas descartadas
#
#   * `docker volume create --opt o=size=` — só funciona em tmpfs (volátil) ou XFS com project
#     quota habilitada; depende do sistema de arquivos do host e falha silenciosamente noutros.
#   * Segundo block volume na OCI — reabre a divisão de disco em porta de mão única, que foi
#     justamente o que a consolidação numa máquina só eliminou.
#
# Serve ao **Tempo** pelo mesmo motivo (doc 76): traces também têm retenção por tempo e nenhum
# teto de tamanho. Basta passar outro ponto de montagem — o nome da imagem e o rótulo saem dele.
#
# Uso (precisa de root):
#   sudo ./criar-volume-limitado.sh              # 20G em /var/lib/cinetra/loki
#   sudo ./criar-volume-limitado.sh 40G /dados/loki
#   sudo ./criar-volume-limitado.sh 10G /var/lib/cinetra/tempo   # traces
#
# Depois, no `.env` do stack:
#   LOKI_DATA=/var/lib/cinetra/loki
#   TEMPO_DATA=/var/lib/cinetra/tempo
#
# E recrie o serviço:
#   docker compose -f compose.obs.yml up -d --force-recreate loki

set -euo pipefail

TAMANHO="${1:-20G}"
MONTAGEM="${2:-/var/lib/cinetra/loki}"
# Derivado do ponto de montagem: `/var/lib/cinetra/loki` → `/var/lib/cinetra/loki.img`, que é
# exatamente o caminho fixo que esta linha tinha antes de o script passar a servir dois serviços.
IMAGEM="${FS_IMAGE:-${LOKI_FS_IMAGE:-${MONTAGEM%/}.img}}"
ROTULO="cinetra-$(basename "$MONTAGEM")"
# Loki e Tempo rodam como uid/gid 10001 (verificado em `docker inspect` nas duas imagens). Sem o
# chown o serviço sobe e falha ao gravar — e falha de permissão em disco costuma aparecer como
# "pipeline parado", que manda investigar o lugar errado.
LOKI_UID=10001

[ "$(id -u)" -eq 0 ] || { echo "erro: precisa de root (montar sistema de arquivos)" >&2; exit 1; }

for cmd in fallocate mkfs.ext4 mount findmnt; do
  command -v "$cmd" >/dev/null || { echo "erro: '$cmd' não encontrado" >&2; exit 1; }
done

if findmnt -M "$MONTAGEM" >/dev/null 2>&1; then
  echo "já montado em $MONTAGEM:"
  df -h "$MONTAGEM" | tail -1
  exit 0
fi

if [ -e "$IMAGEM" ]; then
  echo "erro: $IMAGEM já existe. Apague-o à mão se quiser recriar (o log dentro será perdido)." >&2
  exit 1
fi

mkdir -p "$(dirname "$IMAGEM")" "$MONTAGEM"

# Esparso: ocupa disco conforme cresce, mas o sistema de arquivos dentro dele já nasce com o teto.
# É o que dá o limite sem reservar o espaço todo de imediato.
echo "==> criando imagem de $TAMANHO em $IMAGEM"
fallocate -l "$TAMANHO" "$IMAGEM"

# `-m 0`: sem reserva para root. Num sistema de arquivos dedicado a log, os 5% padrão seriam 1 GB
# de 20 GB desperdiçados para um usuário que nunca vai escrever aqui.
echo "==> formatando (ext4)"
mkfs.ext4 -q -m 0 -L "$ROTULO" "$IMAGEM"

echo "==> montando em $MONTAGEM"
mount -o loop,noatime "$IMAGEM" "$MONTAGEM"
chown -R "$LOKI_UID:$LOKI_UID" "$MONTAGEM"

# Persistente no boot. Sem esta linha o teto some no primeiro reboot: o Loki voltaria a gravar no
# disco raiz, silenciosamente, e a proteção estaria desligada sem ninguém perceber.
LINHA="$IMAGEM  $MONTAGEM  ext4  loop,noatime  0 2"
if ! grep -qF "$MONTAGEM" /etc/fstab; then
  echo "==> registrando em /etc/fstab (persiste no reboot)"
  printf '%s\n' "$LINHA" >> /etc/fstab
fi

echo
df -h "$MONTAGEM" | tail -1
cat <<EOF

Pronto. Agora:

  1) no .env do stack:      LOKI_DATA=$MONTAGEM
  2) recrie o serviço:      docker compose -f compose.obs.yml up -d --force-recreate loki
  3) confirme o teto:       ./verificar.sh   (seção 10 mostra o uso deste sistema de arquivos)

Se este volume encher, o Loki degrada e o alerta "Pipeline de log parado" dispara — o banco
segue intacto, que é o motivo de tudo isto.
EOF
