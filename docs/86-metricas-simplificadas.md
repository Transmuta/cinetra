# 86 — Métricas simplificadas: de 755 gráficos para uma tela

> Construído em 2026-07-29, a partir de uma reclamação direta: *"as métricas no Grafana, tem muita
> informação, 755 gráficos, sinceramente não entendo quase nenhum deles."*
>
> O diagnóstico mudou o problema de lugar duas vezes. Os 755 **não eram painéis** — eram métricas
> cruas numa tela que ninguém deveria abrir; e o que de fato incomodava eram **dois problemas
> independentes**, que este doc resolve separado. O §7 tem quatro armadilhas medidas, três delas da
> classe "não dá erro nenhum e mente".

---

## 1. Onde estavam os 755

Não em dashboard. Os doze dashboards dos docs [62](62-plano-de-logs.md),
[73](73-dashboards-do-log-ao-banco.md) e [74](74-metricas-do-servidor.md) somam **115 painéis** —
número grande, mas uma ordem de magnitude abaixo da reclamação.

Os 755 são o total de **nomes de métrica coletados**, e o lugar onde eles aparecem como gráfico é a
tela **Drilldown → Metrics** do Grafana: ela desenha um mini-gráfico por métrica existente, em
grade, sem curadoria nenhuma. Abrir aquilo com 755 métricas produz literalmente 755 gráficos, a
maioria sobre o coletor de lixo do Go.

Vale dizer com clareza porque muda a conclusão: **aquela tela não é um dashboard e não deve ser
usada para monitorar.** Ela é um catálogo, útil para descobrir se uma métrica existe. O efeito
colateral de coletar tudo foi tornar o catálogo inútil — e, de tabela, dar a impressão de que o
projeto tinha 755 gráficos para acompanhar.

### O contraste que decidiu tudo

Medido em 2026-07-29, extraindo cada expressão PromQL dos doze dashboards e das nove regras de
alerta: **eles referenciam 25 métricas.** Coletávamos 755 para desenhar 25.

| Fonte | Nomes | Séries ativas | Usadas |
| --- | --- | --- | --- |
| PromEx (a nossa API) | 98 | 2.908 | 9 |
| cAdvisor (containers) | 69 | 2.466 | 4 |
| node_exporter (máquina) | 266 | 1.266 | 11 |
| Prometheus sobre si mesmo | 311 | 869 | 1 (só o `up`) |
| **Total** | **755** | **7.567** | **25** |

E os maiores desperdícios não eram métricas marginais — eram as **maiores**, todas jamais abertas
por painel algum:

| Métrica | Séries | Painéis que a usam |
| --- | --- | --- |
| `container_fs_*` (21 nomes) | ~1.500 | 0 |
| `api_prom_ex_phoenix_http_response_size_bytes_bucket` | 576 | 0 |
| `api_prom_ex_ecto_repo_query_execution_time_..._bucket` | 336 | 0 |
| `api_prom_ex_ecto_repo_query_results_returned_bucket` | 315 | 0 |

## 2. Dois problemas, não um

O segundo achado separou o trabalho: **as 25 métricas de Prometheus vivem todas num único
dashboard**, o `11-servidor.json`. Os outros onze não tocam Prometheus — são Loki e Postgres.

Então "as métricas estão confusas" e "os dashboards estão confusos" são queixas distintas:

1. **A coleta** carregava 730 métricas que nada lia. Problema de *inventário*, resolvido cortando.
2. **A navegação** oferecia doze portas de entrada e nenhuma indicação de por onde começar.
   Problema de *curadoria*, que cortar métrica não resolveria em nada.

## 3. O que foi decidido

Decisão humana explícita, tomada com os números acima na mesa:

- **Poda generosa, não mínima.** Cortar até as 25 usadas economizaria mais e custaria caro uma vez
  só. Métrica podada não existe nem no histórico: descobrir no meio de um incidente que você quer
  `node_load1` significa religar a coleta e **esperar coletar de novo**, justo quando não há tempo.
  A lista mantém a família inteira quando ela é barata e é o tipo de coisa que se procura numa
  investigação.
- **Uma tela de hábito, os doze preservados.** Nenhum dashboard foi apagado ou fundido — os doze
  ganharam a tag `aprofundamento` e continuam inteiros. O que entrou foi um décimo terceiro, que é
  a única tela que precisa ser aberta por rotina.

## 4. A poda

### 4.1 Lista de manter por job, no `prometheus.yml`

Quatro blocos `metric_relabel_configs`, um por job, cada um com um `keep` sobre `__name__`:

| Job | Nomes antes | Depois | O que sobrou |
| --- | --- | --- | --- |
| `node` | 266 | 47 | carga, CPU, PSI, memória, disco (espaço e I/O), rede, OOM, conntrack, descritores |
| `cadvisor` | 69 | 25 | CPU, memória contra o teto, rede, ciclo de vida, denominadores da máquina |
| `api` | 98 | 38 | HTTP, canais, pool do Ecto, filas do Oban, BEAM, uptime, versão |
| `prometheus` | 311 | 2 | `tsdb_head_series` e `build_info` |

**Por que `keep` e não `drop`.** Uma lista de descartar envelhece contra você: subir a versão do
node_exporter ou ligar um plugin novo do PromEx acrescenta nomes que ninguém previu, e eles entram
calados. A lista de manter falha do lado seguro — o que é novo fica de fora até alguém decidir.

**Por que a poda do PromEx é no Prometheus, e não no `Api.PromEx`.** Os plugins são pacote fechado.
Não existe "ligar o Ecto sem o `results_returned`"; ou o plugin entra inteiro, ou a métrica que
importa — `queue_time`, o aviso que chega antes do timeout — sai junto. Os cinco plugins continuam
ligados; a escolha do que **atravessa** é do `prometheus.yml`.

### 4.2 Corte na fonte, no cAdvisor

`container_fs_*` foi o único caso que valeu cortar **duas** vezes. No `compose.obs.yml`, `disk` e
`diskIO` entraram no `--disable_metrics`: assim o cAdvisor não *calcula* — ele varria estatística de
cgroup de bloco a cada 15 s para ninguém ler. A lista de manter do job `cadvisor` também os deixa
fora, e a duplicação é deliberada: é a rede para quem mexer no flag sem passar pelo outro arquivo.

A troca é consciente: **perde-se disco por container.** A pergunta que importa — "o disco vai
encher?" — é do `node_filesystem_*`, que mede a partição de verdade; e para saber de quem é o
volume, `docker system df -v` responde na hora sem custar série temporal para sempre.

### 4.3 O resultado, medido

Amostras por raspagem, antes → depois:

| Job | Antes | Depois |
| --- | --- | --- |
| `api` | 3.534 | 1.542 |
| `node` | 1.316 | 273 |
| `cadvisor` | 655 (já pós-corte na fonte, de ~2.400) | 261 |
| `prometheus` | 743 | 2 |

E os nomes: **755 → 117** (47 node + 38 api + 25 cadvisor + 2 prometheus + 5 sintéticas). A tela
Drilldown → Metrics passa a caber numa página.

O `api` continua sendo o maior mesmo podado, e por um motivo legítimo: histograma multiplica — cada
`_bucket` rende uma série por faixa × rota × método × status. Os ~1.200 que sobram são quase todos
os buckets de `http_request_duration` e dos dois tempos de Ecto, e eles ficam porque são exatamente
o que desenha p95, o número que se olha primeiro.

## 5. A tela de hábito

`dashboards/12-dia-a-dia.json`, título **Cinetra · Dia a dia**, tag `dia-a-dia`. Ela responde uma
pergunta — *está tudo bem?* — e o princípio de projeto é que **nenhum painel exija interpretação**:

- **oito luzes** de fundo verde/vermelho, todas com `colorMode: background`. Verde é normal,
  vermelho pede ação, e a descrição de cada uma diz **o que fazer** — não só o que ela mede;
- **três gráficos de 24 h**, que existem para responder o que a luz não responde: *isto é novo, ou
  vem acontecendo há dias?*;
- **as linhas de erro cruas**, porque métrica serve para perceber e log serve para entender;
- **uma tabela de encaminhamento**: qual dos doze abrir quando cada luz acender.

As oito luzes, e por que essas:

| Luz | Fonte | Por que ela |
| --- | --- | --- |
| A API está no ar? | Prometheus `up` | quando isto é "NÃO", **todas** as outras luzes mentem calmas por falta de dado |
| Está chegando log? | Loki | mesma cegueira, do outro lado: sem log, "zero erros" é ignorância |
| Erros na última hora | Loki | zero é o normal aqui; qualquer número é alguém que viu algo quebrar |
| A tela está lenta? (p95) | Prometheus | p95, não média — a média esconde a minoria que espera 4 s, e é ela que reclama |
| Paciente sem aviso | Postgres | a mais acionável: prejuízo imediato e do paciente, não do servidor |
| Trabalho parado na fila | Postgres | quase tudo que o paciente recebe passa pelo Oban |
| Disco | Prometheus | aos 90% o Postgres recusa escrita e o sistema para de agendar |
| Memória da máquina | Prometheus | acima de 90% o kernel mata processo, e escolhe o maior |

Duas escolhas de projeto que merecem registro:

- **as duas luzes de máquina ignoram o seletor de ambiente**, de propósito e como o doc 74 já
  havia decidido para o `11-servidor`: a máquina é uma só, e carimbar `env` ali criaria a ilusão de
  que existe disco de produção separado do de homologação;
- **"A API está no ar?" usa mapeamento de valor** (`1 → Sim`, `0 → NÃO`) em vez de mostrar o número
  cru. É a diferença entre uma luz que qualquer pessoa lê e uma que exige saber o que `up` significa.

### 5.1 Ela é a página inicial do Grafana

`GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH` no `compose.obs.yml`. Sem isso, entrar no Grafana cai
na home dele, que lista treze dashboards em ordem alfabética e não diz por onde começar — e a
resposta honesta é que só um deles deve ser aberto por hábito.

**É caminho de arquivo, não UID.** Apontar para `cinetra-dia-a-dia` ali não dá erro: o Grafana cai
calado na home padrão, e a única pista fica numa linha de log que ninguém procura.

## 6. Verificação

Tudo pelo caminho da aplicação, nunca por SQL ou PromQL digitado à mão — a lição do
[doc 35](35-plano-execucao-backlog.md) e da regra de migrations.

| O que | Como | Resultado |
| --- | --- | --- |
| as 13 telas, painel a painel | `./verificar-paineis.py`, que manda cada consulta pelo proxy real do Grafana | **143 consultas, 0 falhas** |
| a stack inteira | `ENVFILE=.env.local ./verificar.sh` | **54 ok, 0 falhou** |
| a poda de fato aplicada | `scrape_samples_scraped` × `scrape_samples_post_metric_relabeling` por alvo | os quatro pares da tabela do §4.3 |
| os alertas não ficaram cegos | `/api/prometheus/grafana/api/v1/rules` | 9 regras, todas `health=ok`, nenhuma com `lastError` |
| a tela renderiza | Playwright na raiz do Grafana | cai na "Dia a dia"; as 8 luzes, os 3 gráficos, o painel de log e a tabela |

O browser pegou dois defeitos que consulta verde não pega: o texto de topo **cortava** o terceiro
parágrafo (`h: 5`) e a tabela de encaminhamento nascia com **barra de rolagem interna** (`h: 7`).
Corrigidos para 7 e 13, com uma checagem de grade que confirma zero sobreposição e zero buraco nas
52 linhas.

## 7. As quatro armadilhas

### 7.1 Bind mount de arquivo único no Docker Desktop/WSL é um SNAPSHOT

A pior das quatro, porque produziu duas evidências falsas seguidas:

```
promtool check config /etc/prometheus/prometheus.yml   -> SUCCESS
docker kill -s HUP cinetra-obs-prometheus-1           -> "Completed loading of configuration file"
```

Os dois **validaram e recarregaram o arquivo antigo**. O `docker inspect` mostrou o motivo:

```
bind /run/desktop/mnt/host/wsl/docker-desktop-bind-mounts/archlinux/42e0539e... -> /etc/prometheus/prometheus.yml
```

O Docker Desktop copia bind mount de **arquivo único** para um caminho de snapshot no momento em que
o container é criado. Editar no host não propaga. Só `up -d --force-recreate` faz o container ver a
versão nova — e o sintoma de não saber isso é acreditar que a mudança não funcionou.

Vale para o `prometheus.yml`, para os `targets/*.yml` e para o `alloy.alloy`. **Não** vale para os
dashboards, que sobem por diretório e são relidos de 30 em 30 s pelo provisionamento.

> Nota para produção: na VM do Dokploy os mounts são de diretório e propagam normalmente, mas o
> Prometheus ainda precisa de `SIGHUP` ou reinício para reler configuração — `file_sd_configs` é a
> única parte que recarrega sozinha.

### 7.2 `up` e `scrape_*` não passam pelo `metric_relabel_configs`

As cinco sintéticas do raspador — `up`, `scrape_duration_seconds`, `scrape_samples_scraped`,
`scrape_samples_post_metric_relabeling`, `scrape_series_added` — são anexadas pelo laço de raspagem
**depois** do relabel. Elas sobrevivem sem estar em lista nenhuma.

Medido, não deduzido: o job `prometheus` corta 311 nomes para 2, e `up{job="prometheus"}` continua
de pé. Isso importa porque a resposta a *"o painel está vazio porque não há problema, ou porque a
coleta morreu?"* — a pergunta que o doc 62 §11.3 pagou com duas depurações num dia — continua
inteira depois do corte mais radical do arquivo.

Corolário prático: não acrescente `up` à lista de manter "por garantia". Além de inútil, dá a
impressão errada de que ele viria do alvo.

### 7.3 A API de label values mente sobre o que foi podado

Depois de aplicar a poda, `/api/v1/label/__name__/values` continuava devolvendo **755** — inclusive
com `start`/`end` na última hora. Não é a poda que falhou: aquela API lê o **índice do bloco**, e o
bloco em memória cobre 2 h. Nome que apareceu antes do corte continua no índice até o bloco fechar.

Duas medições corretas, então:

- **imediata** — `scrape_samples_post_metric_relabeling` por alvo. É exato e vale no primeiro
  ciclo de raspagem;
- **de nomes** — `count(group by (__name__) ({__name__=~".+"}))`, esperando a janela de
  obsolescência de 5 min. Medido caindo em degrau: 755 → 742 → 730 → **117**.

Mesma família de engano da nota do doc 74 sobre `external_labels`: consulta que responde `success`
com o dado errado é mais caro que consulta que falha.

### 7.4 Todos os 44 painéis de SQL falharam — e nenhum era regressão minha

A primeira rodada do verificador acusou **44 falhas de 143**, das quais 42 em dashboards que eu não
havia tocado. Erro real, atrás de um `HTTP 400` genérico:

```
db query error: pq: database "movimento_dev" does not exist
```

Resíduo do rename Movimento → Cinetra (commit `8865613`): o `.env.exemplo`, que está no repositório,
**já estava correto** com `cinetra_dev`; o `.env.local` da minha máquina, que é gitignored e por
isso nenhum commit podia atualizar, ficou para trás. Nada a corrigir no repo.

Duas lições que ficam:

- **arquivo de ambiente local não versionado não é alcançado por refactor**, e o sintoma aparece
  longe da causa — como 44 painéis quebrados num dashboard recém-escrito;
- o verificador **fez o trabalho dele**: sem ele, o defeito seria descoberto por alguém abrindo o
  dashboard de mensagens num dia ruim. Vale a regra do topo do próprio script: painel quebrado não
  avisa.

## 8. O que ficou para decisão humana

1. **Se uma métrica podada fizer falta**, o conserto é acrescentar o nome à lista de manter do job e
   recriar o container (§7.1) — mas o histórico **não volta**: a série passa a existir dali para
   frente. Se a pergunta for sobre o passado, a resposta está no Loki, não aqui.
2. **`prometheus_tsdb_head_series` ficou de propósito** e é o painel que diz se esta poda segue
   valendo — cardinalidade cresce sozinha quando alguém acrescenta um label. Ele **ainda não está em
   painel nenhum**; vale um no `11-servidor`, e é o único débito que esta leva abre.
3. **O corte no cAdvisor não foi levado ao node_exporter.** As famílias ruidosas da máquina
   (`node_netstat_*`, `node_sockstat_*`, `node_timex_*`) são descartadas no Prometheus, não na
   fonte, porque o node_exporter é barato e concentrar a decisão num arquivo só vale mais que os
   ciclos poupados. Se algum dia a coleta pesar, `--no-collector.*` é o caminho.
4. **A tag `aprofundamento`** organiza a lista do Grafana, mas não impede ninguém de abrir os doze.
   Se a intenção for esconder de verdade, o caminho é pasta separada no provisionamento — mudança
   maior, que não foi feita.

## 9. Arquivos

| Arquivo | O que mudou |
| --- | --- |
| `deploy/observability/prometheus.yml` | quatro listas de manter + o cabeçalho com a medição e o aviso do §7.2 |
| `deploy/observability/compose.obs.yml` | `disk,diskIO` no `--disable_metrics` do cAdvisor; `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH` |
| `deploy/observability/dashboards/12-dia-a-dia.json` | **novo** — 8 luzes, 3 gráficos, log cru, tabela de encaminhamento |
| `deploy/observability/dashboards/0*..11*.json` | só a tag `aprofundamento` (nenhum painel alterado) |
