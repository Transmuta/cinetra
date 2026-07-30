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
SVC_API="${SVC_API:-cinetra-api-1}"
SVC_WEB="${SVC_WEB:-cinetra-web-1}"

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

# `cinetra-obs-` e NÃO `cinetra-` — a app agora também se chama `cinetra`, e o padrão largo
# passaria a casar com `cinetra-api-1`, reprovando um filtro que está correto. A allowlist do
# agente é ancorada (`cinetra` casa só com `cinetra`), então zero aqui é a afirmação.
n=$(linhas '{service=~"cinetra-obs-.*"}')
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
titulo "11. Banco no Grafana — e a barreira que impede o painel de virar visor de prontuário"

# Os dashboards de mensagens, agenda, jobs e auditoria (doc 73) leem o BANCO, não o log. Isso põe
# uma conexão com a base de produção dentro de uma UI web, e a única coisa que separa "painel de
# operação" de "visor de ficha" é privilégio do Postgres: o role só tem SELECT nas views
# `metrics_*`, que listam coluna a coluna o que pode sair.
#
# Esta seção não confere se o painel está bonito. Confere se a barreira existe — e ela é do tipo
# que falha ABERTO se alguém "consertar" um GRANT sem entender.

DS_DB="${DS_DB:-cinetra-db}"

# Roda SQL pelo caminho real do painel (datasource proxy do Grafana). Devolve a 1ª célula, ou
# `ERRO:<mensagem>` — a distinção importa: aqui há asserção que espera SUCESSO e asserção que
# espera ERRO, e confundir as duas é o jeito clássico de passar por vazio.
sql() {
  local q; q=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")
  curl -s -u "$GRAFANA_AUTH" -m 20 -H 'Content-Type: application/json' -X POST \
    "$GRAFANA/api/ds/query" \
    -d "{\"queries\":[{\"refId\":\"A\",\"datasource\":{\"uid\":\"$DS_DB\"},\"rawSql\":$q,\"format\":\"table\"}],\"from\":\"now-1h\",\"to\":\"now\"}" 2>/dev/null |
  python3 -c 'import sys,json
try:
    r=json.load(sys.stdin)["results"]["A"]
    if r.get("error"): print("ERRO:"+str(r["error"])[:120])
    else:
        v=r["frames"][0]["data"]["values"]
        print(v[0][0] if v and v[0] else "")
except Exception as e: print("ERRO:"+type(e).__name__)' 2>/dev/null
}

if ! graf /api/datasources | grep -q "\"uid\":\"$DS_DB\""; then
  printf '  \033[36mi\033[0m datasource "%s" não existe — os painéis de banco estão desligados neste ambiente\n' "$DS_DB"
else
  # 1) Conecta e lê as views.
  r=$(sql "SELECT count(*) FROM metrics_appointments")
  case "$r" in
    ERRO:*) vermelho "datasource do banco não responde: ${r#ERRO:}" ;;
    *)      verde "datasource do banco responde (metrics_appointments: $r linha(s))" ;;
  esac

  # 2) A ASSERÇÃO QUE IMPORTA: a tabela crua tem de ser NEGADA. Se um dia isto virar verde por
  # sucesso, é porque alguém deu GRANT em tabela — e nome, CPF, telefone e observação clínica
  # passaram a estar a um clique de qualquer pessoa com acesso ao Grafana.
  for t in patients messages audit_events appointments; do
    r=$(sql "SELECT count(*) FROM $t")
    case "$r" in
      ERRO:*permission\ denied*) verde "tabela $t negada ao role do Grafana" ;;
      ERRO:*)                    vermelho "tabela $t: erro inesperado (${r#ERRO:}) — inconclusivo" ;;
      *)                         vermelho "PII EXPOSTA: o Grafana LEU $t direto (devolveu '$r')" ;;
    esac
  done

  # 3) `patient_id` é o único identificador que o doc 05 §1.3 proíbe de sair. Nenhuma view pode
  # tê-lo — nem a de mensagens, nem a de presenças, nem a de pacotes.
  r=$(sql "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name LIKE 'metrics\\_%' AND column_name IN ('patient_id','cpf','tel','destino','erro','obs','motivo','label','user_label','diff','args','errors','body','title','cancel_reason')")
  case "$r" in
    0)      verde "nenhuma view metrics_* expõe patient_id nem coluna de texto livre" ;;
    ERRO:*) vermelho "não consegui checar as colunas das views (${r#ERRO:})" ;;
    *)      vermelho "$r coluna(s) PROIBIDA(s) nas views metrics_* — rode a consulta da §11 do verificar.sh" ;;
  esac

  # 4) View criada depois do role fica sem GRANT e o painel morre com "permission denied" numa
  # tela só. O laço do provisionamento existe para isso; esta linha prova que ele rodou.
  r=$(sql "SELECT count(*) FROM pg_views WHERE schemaname='public' AND viewname LIKE 'metrics\\_%' AND NOT has_table_privilege(current_user, 'public.'||viewname, 'SELECT')")
  case "$r" in
    0)      verde "todas as views metrics_* estão concedidas ao role do Grafana" ;;
    ERRO:*) vermelho "não consegui checar os GRANTs (${r#ERRO:})" ;;
    *)      vermelho "$r view(s) metrics_* SEM grant — rode o setup_metrics_role de novo" ;;
  esac

  # 5) Regressão específica, e a única que este verificador ganhou por um bug REAL: somar
  # `appointments.duration_minutos` (que é override e vem NULA no caso comum) desenhava um painel
  # vazio sem erro nenhum. A view passou a derivar a duração de ends_at-starts_at; se um dia ela
  # voltar a ser nula, o painel de horas agendadas mente de novo.
  r=$(sql "SELECT count(*) FROM metrics_appointments WHERE ends_at IS NOT NULL AND duracao_minutos IS NULL")
  case "$r" in
    0)      verde "duração efetiva presente em todo bloco com fim definido" ;;
    ERRO:*) vermelho "não consegui checar a duração efetiva (${r#ERRO:})" ;;
    *)      vermelho "$r bloco(s) com duracao_minutos NULA — o painel de horas agendadas some" ;;
  esac
fi

# ---------------------------------------------------------------------------------------------
titulo "13. Métricas: máquina, containers e BEAM (doc 74)"

# Log responde "o que a aplicação fez"; as views `metrics_*` respondem "em que estado o negócio
# está". Esta terceira fonte responde "em que estado a MÁQUINA está" — e ela tem o mesmo modo de
# falha silencioso das outras duas: alvo que parou de ser raspado deixa o painel VAZIO, e vazio
# lê-se como "tudo calmo". As asserções abaixo são sobre a coleta existir, não sobre o valor.

# Consulta o Prometheus PELO Grafana (prova a datasource junto). Devolve o nº de séries, ou -1.
prom() {
  curl -s -u "$GRAFANA_AUTH" -m 20 --get \
    "$GRAFANA/api/datasources/proxy/uid/prometheus/api/v1/query" \
    --data-urlencode "query=$1" 2>/dev/null |
    python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d["data"]["result"]) if d.get("status")=="success" else -1)
except Exception: print(-1)' 2>/dev/null || echo -1
}

if ! graf /api/datasources | grep -q '"uid":"prometheus"'; then
  printf '  \033[36mi\033[0m datasource "prometheus" não existe — a fase de métricas não subiu neste ambiente\n'
else
  # 1) TODOS os alvos respondendo. `up == 0` casando com alguma coisa é alvo morto; e o alerta
  # `cinetra-coleta-de-metrica-parada` cobre o mesmo em tempo real.
  caidos=$(prom 'up == 0')
  case "$caidos" in
    0)  verde "todos os alvos do Prometheus estão sendo raspados" ;;
    -1) vermelho "não consegui consultar o Prometheus pelo Grafana" ;;
    *)  vermelho "$caidos alvo(s) de métrica fora do ar — painel vazio SEM aviso enquanto durar" ;;
  esac

  # 2) A máquina. Três famílias distintas, porque node-exporter meio no ar é um estado real:
  # com `/proc` montado e `/sys` não, CPU sai e disco não.
  for m in node_cpu_seconds_total node_memory_MemAvailable_bytes node_filesystem_avail_bytes; do
    n=$(prom "$m")
    if [ "$n" -gt 0 ] 2>/dev/null; then verde "$m: $n série(s)"
    else vermelho "$m VAZIO — o painel de máquina correspondente fica em branco"; fi
  done

  # 3) Os containers. `container_spec_memory_limit_bytes > 0` é a asserção que importa: é o
  # `mem_limit` do compose chegando ao painel, e é ele que sustenta o argumento do doc 62 §3 de
  # trocar a segunda VM por limite por container. Sem esse número não há como ver o OOM chegando.
  n=$(prom 'count(container_spec_memory_limit_bytes > 0)')
  if [ "$n" -gt 0 ] 2>/dev/null; then verde "cAdvisor reporta o mem_limit dos containers"
  else vermelho "nenhum container com mem_limit visível — o painel de teto de memória fica vazio"; fi

  # 4) A aplicação. Um por plugin do `Api.PromEx`: um plugin que deixe de casar com a versão da
  # biblioteca não levanta exceção, só para de emitir — exatamente o defeito que o
  # `prom_ex_test.exs` cobre do lado do código e que esta seção cobre do lado do ambiente.
  for m in api_prom_ex_beam_memory_allocated_bytes \
           api_prom_ex_phoenix_http_requests_total \
           api_prom_ex_ecto_repo_query_queue_time_milliseconds_bucket \
           api_prom_ex_oban_queue_length_count \
           api_prom_ex_application_uptime_milliseconds_count; do
    n=$(prom "$m")
    if [ "$n" -gt 0 ] 2>/dev/null; then verde "${m#api_prom_ex_}: $n série(s)"
    else vermelho "${m#api_prom_ex_} VAZIO — plugin do PromEx parou de emitir"; fi
  done

  # 5) A ASSERÇÃO DE SEGURANÇA, no mesmo espírito da §11: o `/metrics` e o Prometheus NÃO podem
  # estar publicados no host. O conteúdo é reconhecimento pronto — inventário de rotas, nomes de
  # fila, volume de requisição por rota, versão da OTP. A barreira é o compose não publicar a
  # porta; esta linha é o que percebe se alguém publicar "só para depurar" e esquecer.
  #
  # O casamento é por PREFIXO `000*`, e não por igualdade com `000`. O helper `status()` termina
  # em `|| echo 000`, e quando a conexão é recusada o curl JÁ imprime `000` antes de sair não-zero
  # — o resultado é a string `000000`. Comparar com `"000"` reprova sempre: a primeira versão
  # desta checagem acusou "métrica exposta" com as duas portas fechadas, num ambiente onde
  # `docker ps` mostrava que nada estava publicado.
  #
  # Errou para o lado seguro (alarme falso, não silêncio), mas alarme falso é como se ensina uma
  # equipe a ignorar o verificador.
  for porta in 4021 9090; do
    case "$(status "http://localhost:$porta/metrics")$(status "http://localhost:$porta/-/healthy")" in
      000*000*) verde "porta $porta não está publicada no host" ;;
      *)        vermelho "porta $porta RESPONDE no host — métrica exposta fora da rede interna" ;;
    esac
  done
fi

# ---------------------------------------------------------------------------------------------
titulo "12. Dashboards provisionados"

# Painel montado na UI morre com o container, e a VM obs é descartável de propósito. O que
# garante que ele volte é o arquivo — então o que se verifica é que o ARQUIVO virou dashboard.
arquivos=$(ls "$DIR/dashboards"/*.json 2>/dev/null | wc -l)
carregados=$(graf '/api/search?type=dash-db' | grep -o '"uid":"cinetra-[^"]*"' | wc -l)

if [ "$carregados" -ge "$arquivos" ] && [ "$arquivos" -gt 0 ]; then
  verde "$carregados dashboards carregados para $arquivos arquivo(s) em dashboards/"
else
  vermelho "$arquivos arquivo(s) em dashboards/, mas só $carregados carregado(s) — provisionamento falhou (veja o log do Grafana)"
fi

# ---------------------------------------------------------------------------------------------
titulo "13. Segurança do painel: o Grafana não publica em 0.0.0.0 (A2, doc 86 §3)"

# O Grafana é o único serviço do stack com `ports:`, e o compose o prende em 127.0.0.1 — em
# produção o acesso vem pelo Traefik + Cloudflare Access. Publicá-lo em 0.0.0.0 exporia o login,
# que com o datasource do banco enxerga o agregado de TODAS as clínicas. (O par A3 — `secret_key`
# default — é fail-closed pelo `:?` no compose: o container nem sobe sem `GRAFANA_SECRET_KEY`.)
#
# Esta checagem precisa do docker LOCAL (o bind não se vê por curl: 127.0.0.1 e 0.0.0.0 respondem
# igual de dentro da máquina). De um laptop contra Grafana remoto ela se declara PULADA, em vez de
# mentir — mesma postura do `i` da §11 quando um datasource não existe.
DOCKERBIN=""
command -v docker    >/dev/null 2>&1 && DOCKERBIN=docker
command -v docker.exe >/dev/null 2>&1 && DOCKERBIN=docker.exe
if [ -z "$DOCKERBIN" ]; then
  printf '  \033[36mi\033[0m sem docker local — bind do Grafana só é checável na VM\n'
else
  binds=$("$DOCKERBIN" ps --filter name=grafana --format '{{.Ports}}' 2>/dev/null)
  if [ -z "$binds" ]; then
    printf '  \033[36mi\033[0m nenhum container grafana visível ao docker local\n'
  elif printf '%s' "$binds" | grep -qE '(0\.0\.0\.0|\[::\]):[0-9]+->'; then
    vermelho "Grafana publicado em 0.0.0.0 — login exposto fora da VM ($binds)"
  else
    verde "Grafana não publica em 0.0.0.0 (acesso por Traefik + Access): ${binds:-só expose}"
  fi
fi

# ---------------------------------------------------------------------------------------------
titulo "14. Traces: o terceiro sinal (doc 76)"

# O Tempo NÃO tem healthcheck no compose — a imagem é distroless e todo `test:` falha por falta de
# `/bin/sh`, deixando o container eternamente `unhealthy` com o serviço perfeito. Quem verifica a
# prontidão é este bloco, de fora, pelo proxy do Grafana (que prova o datasource junto).
tempo_pronto=$(graf '/api/datasources/proxy/uid/tempo/ready' | head -c 40)

if printf '%s' "$tempo_pronto" | grep -qi 'ready'; then
  verde "Tempo pronto e datasource respondendo"

  # OS DOIS serviços, e não "algum": um trace com só a API é metade da história — quer dizer que a
  # propagação BFF→API quebrou, ou que o agente não está alcançável a partir da rede do web
  # (`APP_NETWORK_OTLP`). O modo de falhar aqui é silencioso por natureza, porque cada serviço
  # sozinho parece estar funcionando.
  servicos=$(graf '/api/datasources/proxy/uid/tempo/api/v2/search/tag/resource.service.name/values')

  for svc in cinetra-api cinetra-web; do
    if printf '%s' "$servicos" | grep -q "\"$svc\""; then
      verde "$svc está produzindo spans"
    else
      vermelho "$svc SEM span — instrumentação desligada (OTEL_EXPORTER_OTLP_ENDPOINT?) ou agente inalcançável"
    fi
  done
else
  vermelho "Tempo não respondeu /ready pelo Grafana — serviço no ar? datasource provisionado?"
fi

# TraceQL metrics — o que move o **Traces Drilldown** (doc 76 §10). Sai do processador
# `local-blocks` do `metrics_generator`, e a falha é enganosa: a busca de traces continua
# funcionando, então o Tempo parece saudável, e só o app do Drilldown fica com todo painel em erro.
if graf '/api/datasources/proxy/uid/tempo/api/metrics/query_range?q=%7B%7D%20%7C%20rate()' |
   grep -q '"series"'; then
  verde "TraceQL metrics respondendo (Drilldown de traces funciona)"
else
  vermelho "TraceQL metrics FALHOU — processador local-blocks desligado? O Drilldown abre e todo painel dá erro"
fi

# A COSTURA. Os dois bancos só viram uma ferramenta se a linha de log carregar `trace_id`: é o
# campo que o `derivedFields` do datasource do Loki procura para oferecer "Ver trace", e o mesmo
# que o `tracesToLogsV2` usa na volta. Quebrado, nada dá erro — o botão só não aparece.
if [ "$(recentes '{service=~".+"} |= "trace_id"')" -ge 1 ] 2>/dev/null; then
  verde "log recente carrega trace_id (o link log↔trace funciona)"
else
  vermelho "nenhuma linha recente com trace_id — sem isso o botão 'Ver trace' some do Grafana"
fi

# Mesma asserção de segurança das §11 e §13, agora para o receptor OTLP. Ele é ingestão ANÔNIMA:
# o Alloy não autentica, então publicado no host ele aceita span forjado de qualquer origem — e
# span é o sinal mais detalhado que a máquina produz (rota com id, SQL, sequência de chamadas).
#
# Casamento por PREFIXO `000*` pelo mesmo motivo documentado na §13: com conexão recusada o curl
# imprime `000` e o helper acrescenta outro, resultando em `000000`.
for porta in 4317 4318 3200; do
  case "$(status "http://localhost:$porta/")" in
    000*) verde "porta $porta (OTLP/Tempo) não está publicada no host" ;;
    *)    vermelho "porta $porta RESPONDE no host — ingestão de trace exposta, e ela não autentica" ;;
  esac
done

# ---------------------------------------------------------------------------------------------
printf '\n\033[1m%d ok, %d falhou\033[0m\n' "$ok" "$falhou"
[ "$falhou" -eq 0 ] || exit 1
