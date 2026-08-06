#!/usr/bin/env bash
#
# Teste simples de carga de acesso + prova dos limitadores. Só `curl` e `awk` — sem dependência.
#
#   ./rate-limit.sh externo https://cinetra.com.br    # da SUA máquina: a porta de entrada
#   ./rate-limit.sh interno                           # NO SERVIDOR: prova os limitadores
#
# Por que dois modos, e não um: o BFF **não lê o status** da API ao pedir magic link
# (`web/src/lib/server/auth.ts:96-106` devolve `{sent:true}` sempre), então um 429 da API sai
# como 200 lá fora. O limitador só é observável falando com a API direto — e a API não é pública
# (desenho BFF-only: o Traefik só encaminha `/socket` e `/webhooks`). Daí o modo `interno`.
#
# Nada aqui escreve no banco. O alvo do modo `interno` é o magic link de LOGIN com um e-mail
# inexistente: `register?: false` é o default, e e-mail sem conta "não gera link nem conta"
# (`api/lib/api/accounts/user.ex:155-158`). Confirme com o diff de `contagens.tsv` do baseline.sh.

set -euo pipefail

MODO="${1:?uso: $0 externo <url> | interno}"

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

# Uma requisição → "<status> <segundos>". Nunca falha o script (curl -f desligado de propósito:
# 429 e 503 são resultado, não erro).
sonda() {
  curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 15 "$@" || echo "000 0"
}

# Lê "<status> <segundos>" da entrada e resume: distribuição de status + latências.
resumir() {
  local titulo="$1"
  awk -v titulo="$titulo" '
    { st[$1]++; total++; t[total] = $2; soma += $2 }
    END {
      if (total == 0) { print "  (nenhuma resposta)"; exit }
      printf "\n  %s — %d requisições\n", titulo, total
      printf "  status : "
      for (s in st) printf "%s=%d  ", s, st[s]
      printf "\n"
      n = asort(t)
      printf "  latência: p50=%.0fms  p95=%.0fms  max=%.0fms  média=%.0fms\n",
             t[int(n*0.50)+0 < 1 ? 1 : int(n*0.50)] * 1000,
             t[int(n*0.95)+0 < 1 ? 1 : int(n*0.95)] * 1000,
             t[n] * 1000, (soma/total) * 1000
    }' 2>/dev/null || awk -v titulo="$titulo" '
    # gawk ausente (sem asort): cai para distribuição de status só.
    { st[$1]++; total++; soma += $2 }
    END {
      printf "\n  %s — %d requisições\n  status : ", titulo, total
      for (s in st) printf "%s=%d  ", s, st[s]
      printf "\n  latência média: %.0fms  (sem gawk: p50/p95 indisponíveis)\n", (soma/total)*1000
    }'
}

# ---------------------------------------------------------------------------
# MODO EXTERNO — a porta de entrada, da internet. Nenhum destes alvos passa por limitador:
# `/health` e `/ready` do BFF são públicos, e o `/api/ready` da API está no scope
# `pipe_through :api` puro (router.ex:85-89), fora dos dois estágios de rate limit.
#
# É de propósito: aqui se mede o TETO da porta de entrada, sem o limitador no meio. Se aparecer
# 429 nesta seção, o 429 não veio da aplicação — veio do Traefik ou do provedor.
# ---------------------------------------------------------------------------
externo() {
  local base="${1:?informe a URL, ex: https://cinetra.com.br}"
  local n="${N:-120}" par="${PAR:-10}"

  echo "═══ MODO EXTERNO — $base"
  echo "    $n requisições, $par em paralelo, por alvo"

  # A — controle. `/health` é o liveness do Node: responde sem I/O nenhum
  # (web/src/routes/health/+server.ts). Serve para separar "o servidor está lento" de "o meu
  # gerador de carga é o gargalo". Se ISTO degrada, nada abaixo significa coisa alguma.
  echo
  echo "── A · controle (Traefik → Node, zero I/O)"
  seq "$n" | xargs -P "$par" -I{} bash -c "$(declare -f sonda); sonda '$base/health'" \
    | resumir "GET /health"

  # B — o caminho completo. `/ready` atravessa Traefik → Node → rede interna → API → pool do
  # banco (web/src/routes/ready/+server.ts). É a medida honesta de "carga de acesso": exercita
  # todos os elos que uma requisição real exercita, sem escrever nada.
  echo
  echo "── B · caminho completo (Traefik → Node → API → banco)"
  seq "$n" | xargs -P "$par" -I{} bash -c "$(declare -f sonda); sonda '$base/ready'" \
    | resumir "GET /ready"

  cat <<'FIM'

  Como ler:
    · A e B com 100% de 200 → a porta de entrada aguenta esta taxa. Suba N e PAR e repita.
    · B muito acima de A → o custo está na API ou no pool do banco, não no front.
    · 429 aqui → não é a aplicação (nenhum destes alvos tem limitador): é Traefik ou provedor.
    · 502/503 → algum elo caiu. Pare e olhe o log antes de subir a carga.

  Ajuste com:  N=600 PAR=40 ./rate-limit.sh externo <url>
FIM
}

# ---------------------------------------------------------------------------
# MODO INTERNO — no servidor, falando com a API direto pela rede do stack.
#
# Aqui o `x-forwarded-for` é nosso, e é ELE que o limitador usa como chave: a API confia nesse
# header vindo da rede interna (`ApiWeb.ClientIp`, e o BFF o preenche em api.ts:43). Poder
# escolher o IP é o que permite provar as duas metades: que o balde enche, e que baldes de IPs
# diferentes são independentes.
#
# Alvo: POST /api/auth/magic-link — limitador `RateLimitAuth`, 10 por IP a cada 2 min
# (rate_limit_auth.ex:31-33). 12 requisições provam o teto. O limite de borda (2.000/min por IP)
# fica fora deste teste por ser caro: exigiria ~34 req/s sustentados por um minuto.
# ---------------------------------------------------------------------------
interno() {
  local rede="${REDE:?exporte REDE com a rede do stack, ex: REDE=cinetra-prod_app}"
  local api="${API:-http://api:4000}"
  local dominio="${DOMINIO_FALSO:-carga-teste.invalid}"

  echo "═══ MODO INTERNO — $api pela rede $rede"
  echo "    alvo: POST /api/auth/magic-link · limite esperado: 10 por IP / 2 min"
  echo

  # `curl` num container descartável: nem a imagem da API nem a do web trazem curl.
  chamar() {
    local ip="$1" email="$2"
    docker run --rm --network "$rede" curlimages/curl:latest \
      -sS -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 10 \
      -X POST "$api/api/auth/magic-link" \
      -H 'content-type: application/json' \
      -H "x-forwarded-for: $ip" \
      -d "{\"email\":\"$email\"}" 2>/dev/null || echo "000 0"
  }

  # C — o balde enche. Sequencial de propósito: o que se quer ver é a VIRADA (as primeiras
  # passam, as últimas não), e em paralelo a ordem se perde.
  echo "── C · 12 pedidos do MESMO IP (198.51.100.10) — esperado: 10× 200, depois 429"
  local i saida
  for i in $(seq 1 12); do
    saida="$(chamar 198.51.100.10 "c$i@$dominio")"
    printf '   %2d → %s\n' "$i" "$saida"
  done

  # D — baldes independentes. Se o IP não fosse a chave, este bloco já viria barrado, porque o
  # balde de C acabou de estourar. É a metade que a maioria dos testes esquece — e a que pega o
  # modo de falha real: chave errada faz UMA clínica barrada barrar TODAS.
  echo
  echo "── D · 3 pedidos de um IP DIFERENTE (203.0.113.55) — esperado: 3× 200"
  for i in $(seq 1 3); do
    saida="$(chamar 203.0.113.55 "d$i@$dominio")"
    printf '   %2d → %s\n' "$i" "$saida"
  done

  # E — o Retry-After. O header é o contrato com o cliente; sem ele o browser não sabe esperar.
  echo
  echo "── E · cabeçalhos do 429 (mesmo IP de C, já barrado)"
  docker run --rm --network "$rede" curlimages/curl:latest \
    -sS -D - -o /dev/null --max-time 10 \
    -X POST "$api/api/auth/magic-link" \
    -H 'content-type: application/json' \
    -H 'x-forwarded-for: 198.51.100.10' \
    -d "{\"email\":\"e1@$dominio\"}" 2>/dev/null \
    | grep -iE '^(HTTP|retry-after|x-ratelimit)' || echo "   (nenhum cabeçalho de limite)"

  cat <<'FIM'

  Como ler:
    · C vira 429 na 11ª  → limitador de auth de pé, chaveado por IP. É o esperado.
    · C nunca vira 429   → `rate_limit_enabled` está desligado (só liga em prod, RateLimit.enabled?)
                           OU o x-forwarded-for não está sendo lido. Compare com D.
    · D vem 429          → ACHADO GRAVE: a chave não é o IP do cliente. Uma clínica barrada
                           barraria todas — todo o tráfego dividiria um balde só.
    · E sem Retry-After  → o cliente não tem como saber quanto esperar.

  Limpeza: nenhuma. E-mail inexistente com register?=false não cria conta nem token
  (api/lib/api/accounts/user.ex:155-158). Confirme no diff de contagens.tsv do baseline.sh.
FIM
}

case "$MODO" in
  externo) shift; externo "$@" ;;
  interno) shift; interno "$@" ;;
  *) echo "modo desconhecido: $MODO (use 'externo' ou 'interno')" >&2; exit 1 ;;
esac
