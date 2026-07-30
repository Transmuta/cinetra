#!/usr/bin/env python3
"""Roda TODA consulta de TODO dashboard contra a stack e reprova painel a painel (doc 73 §5).

Por que existe: painel quebrado não avisa. Uma consulta com sintaxe errada aparece como um
retângulo com erro pequeno num canto, e uma consulta *certa* sobre a coluna *errada* aparece como
um gráfico vazio — que é indistinguível de "não houve nada nesse período". Abrir onze dashboards
à mão depois de cada mudança não é verificação, é esperança.

Este script manda cada consulta pelo caminho real do Grafana (o mesmo proxy que o painel usa),
substituindo as variáveis do dashboard pelos valores do ambiente.

    ./verificar-paineis.py                      # local
    GRAFANA=https://grafana.exemplo GRAFANA_AUTH=admin:senha \\
    OBS_ENV_TESTE=prod PARSER=json ./verificar-paineis.py

Reprova em três situações, e a terceira é a que pegou o único bug real desta leva:

  1. a consulta devolve erro;
  2. o Loki/Postgres recusa a sintaxe;
  3. a consulta responde com linhas, mas alguma coluna vem **100% NULA** — o sintoma de somar a
     coluna errada (foi assim que `sum(duration_minutos)`, que é um *override* e vem nulo no caso
     comum, desenhava um painel vazio sem erro nenhum).

`nullif(` na consulta desliga a checagem 3 para aquela consulta: é a marca explícita de "este
denominador pode não existir", e taxa sem base é NULA por decisão, não por defeito.

ATENÇÃO ao ler um "0 série(s)": isso é ausência de DADO, não prova de consulta certa. Quando um
painel novo vier vazio, confirme no banco (ou no Explore) que realmente não há o que mostrar —
esse foi o erro que o verificar.sh já cometeu uma vez, passando por vazio.
"""

import base64
import glob
import json
import os
import sys
import time
import urllib.parse
import urllib.request

GRAFANA = os.environ.get("GRAFANA", "http://localhost:3300")
AUTH = os.environ.get("GRAFANA_AUTH", "admin:cinetra-local")
ENV = os.environ.get("OBS_ENV_TESTE", "dev")
PARSER = os.environ.get("PARSER", "logfmt")
DS_DB = os.environ.get("DS_DB", "cinetra-db")
DIR = os.environ.get("DASHBOARDS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards"))

CABECALHO = {
    "Authorization": "Basic " + base64.b64encode(AUTH.encode()).decode(),
    "Content-Type": "application/json",
}


def http(url, data=None):
    req = urllib.request.Request(url, data=data, headers=CABECALHO)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def substitui(s):
    """Troca as variáveis do dashboard pelos valores deste ambiente."""
    for de, para in (
        ("$env", ENV),
        ("$parser", PARSER),
        ("$__auto", "5m"),
        ("$__range", "6h"),
        # O Grafana calcula `$__rate_interval` a partir do intervalo de raspagem e do zoom do
        # painel; aqui basta um valor plausível — o que se verifica é a consulta, não a janela.
        ("$__rate_interval", "5m"),
    ):
        s = s.replace(de, para)
    return s


def loki(expr, instante):
    agora = int(time.time())
    if instante:
        url = (
            f"{GRAFANA}/api/datasources/proxy/uid/loki/loki/api/v1/query"
            f"?query={urllib.parse.quote(expr)}&time={agora}"
        )
    else:
        url = (
            f"{GRAFANA}/api/datasources/proxy/uid/loki/loki/api/v1/query_range"
            f"?query={urllib.parse.quote(expr)}&start={agora - 21600}000000000"
            f"&end={agora}000000000&step=600&limit=10"
        )
    d = http(url)
    if d.get("status") != "success":
        return False, str(d)[:160]
    return True, f"{len(d['data']['result'])} série(s)"


def prometheus(expr, instante):
    """Métricas (doc 74). Mesma ideia do `loki/`: pelo proxy do Grafana, o caminho real do painel.

    A checagem forte aqui é diferente da do SQL. Coluna 100% nula não existe em PromQL; o modo de
    errar é outro — **seletor que não casa com nada**. `{env="prod"}` num Prometheus que rotula
    `env="dev"`, ou um nome de métrica com um sublinhado a mais, devolvem `success` com resultado
    VAZIO. O `0 série(s)` abaixo é o sinal disso, e vale a mesma advertência do topo deste
    arquivo: confirme no Explore antes de concluir que é ausência de dado.
    """
    agora = int(time.time())
    base = f"{GRAFANA}/api/datasources/proxy/uid/prometheus/api/v1"
    if instante:
        url = f"{base}/query?query={urllib.parse.quote(expr)}&time={agora}"
    else:
        url = (
            f"{base}/query_range?query={urllib.parse.quote(expr)}"
            f"&start={agora - 21600}&end={agora}&step=300"
        )
    d = http(url)
    if d.get("status") != "success":
        return False, str(d)[:160]
    return True, f"{len(d['data']['result'])} série(s)"


def sql(raw):
    tolera_nulo = "nullif(" in raw
    corpo = json.dumps(
        {
            "queries": [
                {
                    "refId": "A",
                    "datasource": {"uid": DS_DB, "type": "grafana-postgresql-datasource"},
                    "rawSql": raw,
                    "format": "table",
                }
            ],
            "from": str((int(time.time()) - 90 * 86400) * 1000),
            "to": str(int(time.time()) * 1000),
        }
    ).encode()
    res = http(f"{GRAFANA}/api/ds/query", corpo).get("results", {}).get("A", {})
    if res.get("error") or res.get("status", 200) >= 400:
        return False, str(res.get("error"))[:200]

    frames = res.get("frames", [])
    linhas, nulas = 0, []
    if frames:
        valores = frames[0].get("data", {}).get("values", [])
        campos = [c.get("name") for c in frames[0].get("schema", {}).get("fields", [])]
        linhas = len(valores[0]) if valores else 0
        for nome, coluna in zip(campos, valores):
            if coluna and all(v is None for v in coluna):
                nulas.append(nome)
    if nulas and not tolera_nulo:
        return False, f"{linhas} linha(s), mas coluna(s) 100% NULA(s): {nulas}"
    return True, f"{linhas} linha(s)"


def fonte(painel, alvo):
    """Tipo do datasource do alvo, com o do painel como fallback.

    Sem isto, TODA consulta que não fosse SQL ia para o Loki — e o dashboard de Servidor, que é
    inteiro PromQL, reprovaria 28 vezes por erro de sintaxe, escondendo qualquer falha real no
    meio do ruído.
    """
    return ((alvo.get("datasource") or painel.get("datasource") or {}).get("type")) or "loki"


def main():
    falhas = total = 0
    arquivos = sorted(glob.glob(os.path.join(DIR, "*.json")))
    if not arquivos:
        print(f"nenhum dashboard em {DIR}")
        return 1

    for arq in arquivos:
        d = json.load(open(arq))
        print(f"\n=== {os.path.basename(arq)} — {d['title']}")
        for painel in d["panels"]:
            if painel["type"] == "row":
                continue
            for alvo in painel.get("targets", []) or []:
                total += 1
                try:
                    if "rawSql" in alvo:
                        ok, msg = sql(substitui(alvo["rawSql"]))
                    elif fonte(painel, alvo) == "prometheus":
                        ok, msg = prometheus(substitui(alvo["expr"]), alvo.get("instant", False))
                    else:
                        ok, msg = loki(substitui(alvo["expr"]), alvo.get("instant", False))
                except Exception as erro:  # noqa: BLE001
                    ok, msg = False, f"{type(erro).__name__}: {erro}"
                if not ok:
                    falhas += 1
                print(f"  [{'ok  ' if ok else 'FALHA'}] {painel['title']} / {alvo['refId']}: {msg}")

    print(f"\n{total} consultas, {falhas} falha(s)")
    return 1 if falhas else 0


if __name__ == "__main__":
    sys.exit(main())
