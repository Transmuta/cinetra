#!/usr/bin/env bash
# Verificador do pipeline de logs e health checks (docs/62 §10.2).
#
# Roda contra QUALQUER ambiente — local, HML ou produção — mudando as variáveis abaixo. Existe
# porque cada peça deste desenho tem um modo de falha silencioso: filtro que come demais, redação
# que não aplica, retenção inerte, health check que responde 200 com o banco fora. Nenhuma delas
# aparece sozinha; todas aparecem aqui.
#
# Uso:
#   ./verificar.sh                       # local (dev)
#   WEB=https://cinetra.com.br \
#   GRAFANA=https://grafana.exemplo \
#   GRAFANA_AUTH=admin:senha ./verificar.sh
#
# O teste 8 é DESTRUTIVO (pausa o banco por segundos) e só roda com PAUSAR_DB=1.

set -uo pipefail

API="${API:-http://localhost:4010}"
WEB="${WEB:-http://localhost:5173}"
GRAFANA="${GRAFANA:-http://localhost:3300}"
GRAFANA_AUTH="${GRAFANA_AUTH:-admin:cinetra-local}"
# Nome do serviço como o Alloy o rotula (nome do container).
SVC_API="${SVC_API:-moving-api-1}"
SVC_WEB="${SVC_WEB:-moving-web-1}"

# Acesso ao compose — definido AQUI, no topo, e não no meio do script. A primeira versão declarava
# estas três variáveis na seção 9; a seção 7, que roda antes, referenciava `$DOCKER` ainda indefinido
# e, sob `set -u`, a substituição falhava devolvendo vazio. O sintoma foi "config do Loki veio
# incompleta (0 bytes)" — um erro de ordem de declaração acusando o software de estar quebrado.
#
# `--env-file` é obrigatório: o compose valida as variáveis `:?` ao resolver o arquivo, e sem ele
# o `exec` aborta.
DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER="${DOCKER_CMD:-docker}"
ENVFILE="${OBS_ENV_FILE:-$DIR/.env.local}"

ok=0; falhou=0
verde() { printf '  \033[32m✓\033[0m %s\n' "$1"; ok=$((ok+1)); }
vermelho() { printf '  \033[31m✗\033[0m %s\n' "$1"; falhou=$((falhou+1)); }
titulo() { printf '\n\033[1m%s\033[0m\n' "$1"; }

status() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$1" 2>/dev/null || echo 000; }
corpo()  { curl -s -m 10 "$1" 2>/dev/null; }
# O Grafana exige autenticação em /api/*: sem o -u, tudo volta 401 e as checagens dariam
# "ausente" para coisa que está lá. Foi o que aconteceu na primeira execução deste script.
graf()   { curl -s -u "$GRAFANA_AUTH" -m 20 "$GRAFANA$1" 2>/dev/null; }

# Consulta o Loki PELO Grafana (prova a datasource junto) e devolve o nº de linhas.
linhas() {
  curl -s -u "$GRAFANA_AUTH" -m 20 --get \
    "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode 'limit=200' 2>/dev/null |
    python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(sum(len(r["values"]) for r in d["data"]["result"]))
except Exception: print(-1)' 2>/dev/null || echo -1
}

# Idem, mas só os últimos 5 minutos. Para asserções sobre o comportamento ATUAL.
recentes() {
  inicio=$(python3 -c 'import time; print(int((time.time()-300)*1e9))')
  curl -s -u "$GRAFANA_AUTH" -m 20 --get \
    "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode 'limit=200' --data-urlencode "start=$inicio" 2>/dev/null |
    python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(sum(len(r["values"]) for r in d["data"]["result"]))
except Exception: print(-1)' 2>/dev/null || echo -1
}

# ---------------------------------------------------------------------------------------------
titulo "1. Health checks da API"

[ "$(status "$API/api/health")" = 200 ] \
  && verde "liveness responde 200" || vermelho "liveness NÃO responde 200"

[ "$(status "$API/api/ready")" = 200 ] \
  && verde "readiness responde 200" || vermelho "readiness NÃO responde 200"

# Liveness não pode tocar o banco: é o que impede um blip do Postgres de reiniciar máquina sadia.
corpo "$API/api/health" | grep -q '"db"' \
  && vermelho "liveness reporta 'db' — deveria ser SEM I/O" \
  || verde "liveness não toca o banco"

# ---------------------------------------------------------------------------------------------
titulo "2. Health checks do BFF"

[ "$(status "$WEB/health")" = 200 ] \
  && verde "liveness responde 200" || vermelho "liveness NÃO responde 200"

[ "$(status "$WEB/ready")" = 200 ] \
  && verde "readiness responde 200 (alcança a API)" \
  || vermelho "readiness NÃO responde 200 — o BFF não alcança a API"

# O corpo é público: não pode descrever a topologia para quem varre a internet.
corpo "$WEB/ready" | grep -qiE 'internal|vcn|10\.|ECONN|ENOTFOUND' \
  && vermelho "readiness vaza detalhe de infra no corpo" \
  || verde "readiness não descreve a infra"

# ---------------------------------------------------------------------------------------------
titulo "3. Grafana e datasource"

case "$(status "$GRAFANA/login")" in
  200|302) verde "Grafana responde" ;;
  *) vermelho "Grafana não responde em $GRAFANA" ;;
esac

graf /api/datasources | grep -q '"type":"loki"' \
  && verde "datasource Loki provisionada" \
  || vermelho "datasource Loki AUSENTE (o provisionamento não subiu)"

# ---------------------------------------------------------------------------------------------
titulo "4. O log está chegando"

# Marca ALFABÉTICA de propósito: a primeira versão usava epoch+PID, e a redação (guloso demais na
# época) a devorou — o teste reprovava culpando o agente, quando o defeito era o regex. A marca
# não pode depender da correção daquilo que ela verifica.
MARCA="verificar-$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 12)"
# Número operacional plantado junto, para provar o outro lado: 10 dígitos que a redação NÃO pode
# tocar. É a regressão do bug do regex guloso.
OPERACIONAL="1785259312"

curl -s -o /dev/null -m 10 -X POST "$WEB/api/client-error" \
  -H 'content-type: application/json' \
  -d "{\"origem\":\"verificador\",\"message\":\"$MARCA ts=$OPERACIONAL\",\"stack\":\"at Ficha (/pacientes/019f7c5b-1bee-7a32-9fad-c3d6f0a83177) email ana@exemplo.com cpf 111.222.333-44 fone (11) 98765-4321\",\"route\":\"/pacientes/019f7c5b-1bee-7a32-9fad-c3d6f0a83177\"}" 2>/dev/null

# Espera com repetição em vez de `sleep` fixo: o atraso do agente varia com o backlog, e um
# número fixo ou reprova cedo demais ou faz todo mundo esperar o pior caso.
n=0
for _ in $(seq 1 12); do
  sleep 5
  n=$(linhas "{service=\"$SVC_WEB\"} |= \"$MARCA\"")
  [ "$n" -ge 1 ] 2>/dev/null && break
  printf '  … aguardando o agente embarcar\n'
done

achou=0
if [ "$n" -ge 1 ] 2>/dev/null; then
  verde "evento do browser chegou ao Loki"
  achou=1
else
  vermelho "evento do browser NÃO chegou (agente parado? lote rejeitado?)"
fi

# ---------------------------------------------------------------------------------------------
titulo "5. Redação e sanitização (as barreiras de PII)"

# **Só roda se o evento foi encontrado.** Sem esta guarda os quatro greps abaixo passariam por
# VAZIO quando o log não chega — "não achei CPF" num corpo inexistente não é prova de nada, e o
# script diria "tudo verde" no exato cenário em que nada está sendo verificado. Aconteceu na
# primeira execução, e é a mesma classe de erro que o resto deste plano combate: um painel que
# afirma estar bem porque não está olhando.
if [ "$achou" = 0 ]; then
  vermelho "pulado — sem o evento no Loki não há o que verificar (ver teste 4)"
else
  evento=$(curl -s -u "$GRAFANA_AUTH" -m 20 --get \
    "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
    --data-urlencode "query={service=\"$SVC_WEB\"} |= \"$MARCA\"" --data-urlencode 'limit=1' 2>/dev/null)

  # Sanidade: o corpo tem de conter a marca, senão estamos grepando a resposta errada.
  if echo "$evento" | grep -q "$MARCA"; then
    verde "evento localizado para inspeção"
  else
    vermelho "resposta do Loki não contém a marca — inspeção inválida"
  fi

  echo "$evento" | grep -q '019f7c5b' \
    && vermelho "UUID de paciente VAZOU para o log" \
    || verde "UUID de paciente sanitizado (:id)"

  echo "$evento" | grep -q 'ana@exemplo.com' \
    && vermelho "e-mail VAZOU para o log" || verde "e-mail redigido ([EMAIL])"

  echo "$evento" | grep -q '111.222.333-44' \
    && vermelho "CPF VAZOU para o log" || verde "CPF redigido ([CPF])"

  echo "$evento" | grep -q '98765-4321' \
    && vermelho "telefone VAZOU para o log" || verde "telefone redigido ([TELEFONE])"

  # O outro lado da moeda, e ele já falhou uma vez: a redação não pode comer dado OPERACIONAL.
  # A primeira versão do regex de CPF (separadores todos opcionais, sem delimitador) casava com
  # qualquer corrida de 11 dígitos e transformou um timestamp unix em `[CPF]`. Isso é pior que
  # não redigir — destrói o dado E sugere que havia PII onde havia um id.
  echo "$evento" | grep -q "$OPERACIONAL" \
    && verde "número operacional preservado (redação não é gulosa)" \
    || vermelho "a redação comeu um número operacional — regex guloso demais"
fi

# ---------------------------------------------------------------------------------------------
titulo "6. Filtros de ruído"

for i in 1 2 3 4 5 6; do curl -s -o /dev/null -m 5 "$API/api/health"; done
sleep 15

# MESMA guarda do teste 5, pelo mesmo motivo: "0 linhas de health" é indistinguível de "0 linhas
# de tudo". Sem confirmar que HÁ log daquele serviço, um filtro quebrado e um agente parado dão o
# mesmo verde — e o verde do agente parado é o mais perigoso dos dois.
total=$(linhas "{service=\"$SVC_API\"}")
if [ "$total" -lt 1 ] 2>/dev/null; then
  vermelho "sem log nenhum de $SVC_API — não dá para afirmar nada sobre os filtros"
else
  # Conta só EVENTO DE REQUISIÇÃO, não qualquer linha que mencione o caminho: um stack trace que
  # cite `/api/health` reprovaria o filtro sem que o filtro tivesse falhado. Precisão importa nos
  # dois sentidos — o verificador que grita lobo é abandonado tão rápido quanto o que dorme.
  # Janela CURTA (5 min): esta asserção é sobre o comportamento de agora, não sobre o histórico.
  # Com a janela padrão de 1 h, uma linha anterior a um conserto reprova o filtro já corrigido —
  # e um verificador que acusa defeito consertado é abandonado tão rápido quanto um que dorme.
  n=$(recentes "{service=\"$SVC_API\"} |= \"requisição\" |~ \"route=/api/(health|ready)/?\\\\s\"")
  [ "$n" = 0 ] \
    && verde "health check não polui o log ($total linhas do serviço, 0 de health)" \
    || vermelho "health check ESTÁ no log ($n eventos) — o filtro não pegou"
fi

# Este não precisa de guarda: a allowlist do agente é por projeto do compose, e os stacks de
# observabilidade têm nome próprio (`cinetra-obs`, `cinetra-agente`). Zero aqui é a afirmação.
n=$(linhas '{service=~"(observability|cinetra)-.*"}')
[ "$n" = 0 ] \
  && verde "o próprio stack de observabilidade não entra na conta" \
  || vermelho "o stack de obs está sendo coletado ($n linhas)"

# ---------------------------------------------------------------------------------------------
titulo "7. Retenção de 30 dias"

# `retention_period` sem o compactor habilitado é INERTE — é o erro clássico desta config.
#
# A resposta tem ~80 KB e já expirou uma vez com timeout curto, o que fez o script dizer
# "retention NÃO é 30d" quando a config estava certa. **"Não consegui checar" e "checado e errado"
# são fatos diferentes**, e confundi-los é a mesma classe de erro do passe por vazio: um
# verificador que grita lobo é tão inútil quanto um que dorme.
# Lido DIRETO do container, não pelo proxy do Grafana. A resposta tem ~80 KB e, pelo proxy, voltava
# parcial de forma intermitente — o efeito foi esta seção acusar "compactor sem retention_enabled"
# enquanto a seção 10 dizia que ele estava no ar. Duas checagens se contradizendo significam que
# uma está quebrada, e a quebrada era o transporte.
cfg=$($DOCKER compose -f "$DIR/compose.obs.yml" ${ENVFILE:+--env-file "$ENVFILE"} \
  exec -T loki wget -qO- http://localhost:3100/config 2>/dev/null)

# O guarda de tamanho olha para a ordem de grandeza real (~80 KB), não para 1 KB: uma resposta
# truncada em 5 KB passaria no teto antigo e reprovaria o software por falta do trecho certo.
if [ "$(printf %s "$cfg" | wc -c)" -lt 40000 ]; then
  vermelho "config do Loki veio incompleta ($(printf %s "$cfg" | wc -c) bytes) — inconclusivo"
else
  echo "$cfg" | grep -qE 'retention_period: *(720h|30d)' \
    && verde "retention_period = 30d" \
    || vermelho "retention_period NÃO é 30d (encontrado: $(echo "$cfg" | grep -m1 retention_period))"

  echo "$cfg" | grep -q 'retention_enabled: true' \
    && verde "compactor com remoção habilitada (sem isto a retenção é inerte)" \
    || vermelho "compactor SEM retention_enabled — o bucket cresce para sempre"
fi

# ---------------------------------------------------------------------------------------------
titulo "8. Readiness reprova quando o banco cai"

if [ "${PAUSAR_DB:-0}" = 1 ]; then
  docker compose pause db >/dev/null 2>&1
  s=$(status "$API/api/ready")
  t=$(curl -s -o /dev/null -w '%{time_total}' -m 15 "$API/api/ready" 2>/dev/null)
  docker compose unpause db >/dev/null 2>&1

  [ "$s" = 503 ] && verde "readiness devolve 503 com o banco fora" \
                 || vermelho "readiness devolveu $s com o banco fora (esperado 503)"

  # O teto é 2s; sem ele o DBConnection segura a requisição por ~21s e os checks empilham.
  awk -v t="$t" 'BEGIN{exit !(t < 4)}' \
    && verde "e responde em ${t}s (dentro do orçamento)" \
    || vermelho "demorou ${t}s — o teto do pool não está valendo"
else
  printf '  \033[33m–\033[0m pulado (rode com PAUSAR_DB=1; pausa o banco por segundos)\n'
fi

# ---------------------------------------------------------------------------------------------
titulo "9. O Loki está sendo ALIMENTADO?"

# "De pé" e "recebendo" são coisas diferentes, e a diferença já custou duas depurações: Loki
# healthy, /ready verde, Grafana no ar — e nada chegando. Liveness não responde esta pergunta;
# os contadores respondem.
#
# Três números, e a comparação entre eles diz ONDE quebrou:
#   agente LEU        (loki_source_docker_target_entries_total)
#   agente DESCARTOU  (loki_write_dropped_entries_total, por motivo)
#   Loki RECEBEU      (loki_distributor_lines_received_total)
metrica() {
  local args=(-f "$DIR/compose.obs.yml")
  [ -f "$ENVFILE" ] && args+=(--env-file "$ENVFILE")

  $DOCKER compose "${args[@]}" exec -T loki wget -qO- "$1" 2>/dev/null |
    grep -E "$2" | awk '{s+=$NF} END {printf "%.0f", s+0}'
}

lidas=$(metrica http://alloy:12345/metrics '^loki_source_docker_target_entries_total')
descartadas=$(metrica http://alloy:12345/metrics '^loki_write_dropped_entries_total')
recebidas=$(metrica http://localhost:3100/metrics '^loki_distributor_lines_received_total')

if [ -z "$recebidas" ] || [ "$recebidas" = 0 ]; then
  vermelho "o Loki NUNCA recebeu linha nenhuma — o pipeline não está ligado"
else
  verde "Loki recebeu $recebidas linha(s) desde o boot"
fi

[ -n "$lidas" ] && [ "$lidas" != 0 ] \
  && verde "agente leu $lidas linha(s) do daemon do Docker" \
  || vermelho "o agente não leu nada — allowlist (OBS_PROJETOS) errada, ou socket inacessível"

# Descarte é o modo de falha SILENCIOSO: o agente lê, tenta entregar, o Loki recusa o lote, e a
# linha some sem aparecer em consulta nenhuma. Foi assim que 25.577 entradas sumiram hoje, com
# `reject_old_samples_max_age` menor que a retenção.
#
# O contador é CUMULATIVO desde o boot do agente: um descarte antigo já resolvido deixaria esta
# checagem vermelha para sempre. O que interessa é se o descarte está EM CURSO — então mede-se o
# delta numa janela curta. Total é contexto; delta é o alarme.
sleep 10
descartadas_depois=$(metrica http://alloy:12345/metrics '^loki_write_dropped_entries_total')
delta=$((${descartadas_depois:-0} - ${descartadas:-0}))

if [ "$delta" -gt 0 ] 2>/dev/null; then
  vermelho "descarte EM CURSO: +$delta linha(s) em 10s (motivo em loki_write_dropped_entries_total)"
elif [ "${descartadas:-0}" -gt 0 ] 2>/dev/null; then
  verde "sem descarte em curso ($descartadas acumuladas desde o boot do agente — resíduo)"
else
  verde "nenhuma linha descartada no caminho"
fi

# Frescor: o sinal que importa no dia a dia. Contador crescendo não garante que o dado é de AGORA
# — o agente pode estar horas atrás relendo backlog, e a consulta devolve o passado sem avisar.
atraso=$(curl -s -u "$GRAFANA_AUTH" -m 20 --get \
  "$GRAFANA/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode "query={env=\"${OBS_ENV:-dev}\"}" --data-urlencode 'limit=1' \
  --data-urlencode 'direction=backward' 2>/dev/null |
  python3 -c 'import sys,json,time
try:
    d=json.load(sys.stdin)
    ts=[int(v[0]) for r in d["data"]["result"] for v in r["values"]]
    print(int(time.time()-max(ts)/1e9) if ts else -1)
except Exception: print(-1)' 2>/dev/null)

if [ "$atraso" -lt 0 ] 2>/dev/null; then
  vermelho "sem nenhuma linha na janela — não dá para medir frescor"
elif [ "$atraso" -lt 120 ] 2>/dev/null; then
  verde "log mais recente tem ${atraso}s — o pipeline está no presente"
else
  vermelho "log mais recente tem ${atraso}s — o agente está atrasado (relendo backlog?)"
fi

# ---------------------------------------------------------------------------------------------
titulo "10. Disco — o log divide a máquina com o banco"

# Decidido em 2026-07-28: chunks no DISCO LOCAL, não no R2 (doc 62 §3.3). O custo dessa escolha,
# somado ao de rodar tudo numa máquina só, é que o volume do Loki e o `pgdata` disputam o mesmo
# disco. Um log em laço não enche só o log: **derruba o Postgres junto**.
#
# A retenção de 30 dias limita a acumulação e o `ingestion_rate_mb` limita a taxa, mas nenhum dos
# dois é um teto de disco. Enquanto não houver métrica de host (fase de métricas), a checagem é
# esta — e ela existe porque o modo de falha é lento e silencioso até deixar de ser.
uso=$($DOCKER compose -f "$DIR/compose.obs.yml" ${ENVFILE:+--env-file "$ENVFILE"} \
  exec -T loki sh -c 'df /loki | tail -1' 2>/dev/null | awk '{print $(NF-1)}' | tr -d '%')
ocupado=$($DOCKER compose -f "$DIR/compose.obs.yml" ${ENVFILE:+--env-file "$ENVFILE"} \
  exec -T loki sh -c 'du -sh /loki 2>/dev/null | cut -f1' 2>/dev/null)

# O teto de tamanho (`criar-volume-limitado.sh`) só vale se `LOKI_DATA` apontar para o ponto de
# montagem. Criar o sistema de arquivos e esquecer a variável deixa a proteção DESLIGADA sem
# nenhum sintoma — o Loki grava no disco raiz e tudo parece bem até o dia em que não está. Por
# isso o tamanho total do sistema de arquivos é reportado: ele denuncia a diferença.
total=$($DOCKER compose -f "$DIR/compose.obs.yml" ${ENVFILE:+--env-file "$ENVFILE"} \
  exec -T loki sh -c 'df -h /loki | tail -1' 2>/dev/null | awk '{print $2}')
printf '  \033[36mi\033[0m sistema de arquivos de /loki tem %s no total%s\n' "${total:-?}" \
  "$([ -n "${LOKI_DATA:-}" ] && echo ' (teto por LOKI_DATA — ativo)' || echo ' — sem teto dedicado; é o disco da máquina')"

if [ -z "$uso" ]; then
  vermelho "não consegui ler o uso de disco — inconclusivo"
elif [ "$uso" -lt 80 ] 2>/dev/null; then
  verde "disco em ${uso}% (Loki ocupa ${ocupado:-?})"
elif [ "$uso" -lt 90 ] 2>/dev/null; then
  vermelho "disco em ${uso}% — apertando. Loki ocupa ${ocupado:-?}; confira também o build cache do Docker"
else
  vermelho "disco em ${uso}% — CRÍTICO. Postgres e Loki dividem este volume"
fi

# Retenção CONFIGURADA não é retenção FUNCIONANDO (doc 62 §5) — o §7 acima lê a config, este lê a
# execução. `loki_compactor_apply_retention_operation_total{status="success"}` é a prova mais forte
# possível antes do dia 31: conta as vezes que a retenção foi de fato APLICADA.
#
# (O nome importa: `loki_compactor_runs_*`, que eu tinha chutado, não existe — e a checagem
# acusava um defeito inexistente. Métrica inventada reprova software que está certo.)
retencao=$(metrica http://localhost:3100/metrics '^loki_compactor_apply_retention_operation_total\{status="success"\}')
rodando=$(metrica http://localhost:3100/metrics '^loki_boltdb_shipper_compactor_running')

if [ -n "$retencao" ] && [ "$retencao" -gt 0 ] 2>/dev/null; then
  verde "retenção APLICADA $retencao vez(es) — não está inerte"
elif [ "${rodando:-0}" -gt 0 ] 2>/dev/null; then
  verde "compactor no ar; retenção ainda não teve ciclo (normal logo após subir)"
else
  vermelho "compactor não está rodando — a retenção de 30d não apagaria nada"
fi

# ---------------------------------------------------------------------------------------------
printf '\n\033[1m%d ok, %d falhou\033[0m\n' "$ok" "$falhou"
[ "$falhou" -eq 0 ] || exit 1
