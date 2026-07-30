# Imagem do backup: pg_dump/pg_restore (casados com o servidor 16) + rclone (R2) + age (cifra).
# Base debian bookworm (postgres:16) tem arm64 e traz rclone/age no apt — roda no A1 ARM.
FROM postgres:16

# `curl` é do heartbeat (docs/62 §9) e NÃO vem na base — medido: `postgres:16` não tem curl nem
# wget. Sem instalar, o `|| true` do `sinal()` engoliria o "command not found", o sinal nunca
# sairia, e o monitor alarmaria "backup não rodou" a cada hora. Alarme falso é pior que monitor
# nenhum: treina a equipe a ignorar o alerta que um dia será verdade.
RUN apt-get update \
 && apt-get install -y --no-install-recommends rclone age ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

COPY backup.sh restore.sh /
RUN chmod +x /backup.sh /restore.sh

# Default: um backup e sai. O agendamento (loop 1h) é o `command` do serviço backup-cron no compose.
CMD ["/backup.sh"]
