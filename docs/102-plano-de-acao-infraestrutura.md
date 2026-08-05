# 102 — Plano de ação da análise de infraestrutura

**Data:** 2026-08-04 · **Base:** [doc 95](95-analise-infraestrutura.md) (46 riscos, 30 ações)
· **Acumuladores:** [`00-decisoes.md`](00-decisoes.md), [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md)

Este documento recorta em ondas de execução tudo o que o [doc 95](95-analise-infraestrutura.md)
encontrou. Ele **não** acrescenta achado novo: o escopo é fechado nos 46 riscos (R-C1..C3, R-A1..A10,
R-M1..M23, R-B1..B10) e nas 30 ações do §2 daquele documento. Onde a releitura mudou a avaliação de
alguma coisa, está marcado como **reavaliação**, com o motivo — nunca como novidade.

Toda correção segue a regra do [CLAUDE.md](../CLAUDE.md): **teste vermelho antes do conserto**.

> **NOTA DE 2026-08-05 — três itens deste plano deixaram de ter objeto.** As entregas **1.7**
> (verificação do dump), **2.7** (volume dedicado para o `mktemp`) e a parte de **2.1** que cobria o
> `backup-cron` foram removidas com o backup inteiro pela [ADR-029](00-decisoes.md). O relato
> abaixo — inclusive a lição de que `pg_restore --list` não pega dump truncado — fica como
> **registro medido**, não como descrição do repositório de hoje.

---

## 1. O reenquadramento que muda o corte

O doc 95 foi escrito em **2026-07-30** e organizou as ações em "Faixa 0 — antes do primeiro deploy",
Faixa 1 e Faixa 2. **Esse enquadramento morreu.**

Produção está no ar desde **2026-07-31** numa **Hostinger KVM 2 (8 GB, 2 vCPU)**, com prod + HML +
observabilidade + Dokploy na mesma máquina ([ADR-023](00-decisoes.md),
[doc 87 §2.1](87-servidor-hostinger-riscos-e-cuidados.md)). Hoje é **2026-08-04**. O primeiro deploy
aconteceu **sem nenhum item da Faixa 0**.

Portanto as ondas **não podem** ser a Faixa 0/1/2 renomeada. Elas são recortadas por outra pergunta:
**o que está aberto num sistema que já serve gente?**

### 1.1 O critério de corte

> **Onda 1** é o que já falha hoje **e falha calado**. **Onda 2** é o que tira o freio quando o
> incidente vem. **Onda 3** é o que faz o caminho até produção ser o risco. **Onda 4** é o que faz a
> operação enxergar errado. **Onda 5** é superfície, higiene e o que é decisão, não obra.

Três regras que tornam esse critério operável:

1. **Onda não é severidade.** O doc 95 ordenou por gravidade; aqui ordena-se por *o que está aberto
   agora*. Um **médio** que morde usuário todo dia (R-M3, o 502 intermitente) entra antes de um
   **alto** que precisa de um gatilho externo (R-A9, o socket do Docker). Quem quiser a leitura por
   severidade, ela continua no doc 95 e não foi reescrita.
2. **Desempate: vai para a onda mais cedo apenas o que ocorre sem ninguém fazer nada.** É por isso
   que R-M5 (deploy fire-and-forget) não é onda 1 apesar de falhar em silêncio — ele exige um deploy.
   E é por isso que R-A1 é onda 1: `restart: unless-stopped` reinicia container sozinho.
3. **Onda ordena prioridade; janela ordena agendamento.** Num sistema no ar isso deixa de ser
   filosofia: cada alteração de `compose.dokploy.yml` custa um *recreate* dos containers do produto.
   Ver §3.7.

### 1.2 O que mudou de urgência por causa de "produção no ar"

| Achado | Antes (doc 95) | Agora | Por quê |
| --- | --- | --- | --- |
| **R-C1** alertas sem destino | crítico, "detecção sem notificação" | **crítico, e pior** | Antes não havia o que detectar. Agora há — e os 9 alertas continuam caindo na policy default do Grafana |
| **R-A1** job do Oban órfão | alto, teórico | **alto, exercitado** | Todo deploy é um deploy de verdade, e há cron rodando 6 jobs. `PruneAttachments` às 03:30 UTC com `receive_timeout` de 15 s contra os 10 s do SIGKILL |
| **R-A2** PHI no cache do browser | alto, hipótese | **alto, com usuário** | O cenário do doc 95 (recepção, máquina compartilhada, botão Voltar) deixou de ser cenário |
| **R-M3** 502 por `KEEP_ALIVE_TIMEOUT` | médio | **sobe para onda 1** | Corrida que só existe com tráfego. Agora há tráfego, e o sintoma é 502 sem uma linha no log |
| **R-M11** `pg_dump` no disco do banco | médio | **sobe de faixa** | Antes era disco vazio. Agora `pgdata` tem dado e o dump concorre com ele |
| **R-M22** expand-contract sem gate | médio | **mais caro** | A janela de schema N+1 agora tem usuário dentro dela |
| **R-M4** CI não builda a imagem | médio | **duplo** | O build migrou para a máquina de produção e consome ~90% dos 2 vCPU ([D-21](50-debitos-tecnicos.md)): além de não ser gate, compete com o produto |
| **R-A4** `mem_limit` ausente | alto | **alto, mecanismo intacto, folga maior** | Medido: ≈3,5 GB de 8 GB em uso. O OOM deixou de ser iminente, mas o build que pica é justamente o cenário que a folga não cobre |
| **Ação 11** ensaiar restore | "antes de existir paciente real" | **muda de natureza** | Essa janela fechou. O ensaio agora é num banco separado, com a máquina servindo |
| **Ação 12** rotacionar segredos | livre | **exige janela** | Rotacionar `SECRET_KEY_BASE` derruba toda sessão viva |

### 1.3 O que fechou entre o doc 95 e hoje

Verificado no repositório em 2026-08-04. **Nada disto entra em onda** — está aqui para que o placar
do §5 feche.

| Achado | Estado | Onde |
| --- | --- | --- |
| **R-C2** PII em trace | **parcialmente fechado.** `otelcol.processor.transform "poda"` deixou de ser exemplo comentado e roda: `delete_key` de `url.query`, `url.path` e `db.statement` (`deploy/observability/alloy.alloy:274-289`). Some-se que o exportador está inerte hoje (`OTEL_EXPORTER_OTLP_ENDPOINT` vem vazio). **Deixa de ser crítico.** Sobra o `url.full`, que o próprio R-C2 citava como evidência e não está na lista → **onda 4** | doc 96, S-3 |
| **R-M9** rate limiter em ETS | **fechado por decisão medida.** Migrar para Postgres custaria 0,31 µs → 938 µs por requisição (3.000×), e a análise subestimava o estrago: sem `DNS_CLUSTER_QUERY` em compose nenhum, réplica mata o tempo real antes de dobrar o rate limit. `Api.DeployHorizontalidadeTest` virou a armadilha → **fora de onda** | doc 101 §4.3 |
| **R-B10** documentação obsoleta | **majoritariamente fechado.** ADR-023 substitui a ADR-008 (Fly.io); ADR-027 registra "a API REST é de controllers nomeados"; `docs/04 §12` atualizado. Sobra `docs/17-deploy-fly.md`, que ainda abre sem marca de histórico, e `docs/05 §5` → **onda 5** | doc 101 §2.4 |
| **R-M12** sem limite de CPU | **reenquadrado**, com débito próprio: [D-21](50-debitos-tecnicos.md) mede 90% de CPU no build, só sem carga real. Segue aberto → **onda 2** | doc 98 |

Tudo o mais foi **reconferido e continua aberto**: `mem_limit` 0 ocorrências, `stop_grace_period` 0,
`shm_size` 0, `Lifeline` ausente, `Cache-Control` ausente em `web/src/hooks.server.ts`,
`permissions:` ausente em `.github/workflows/ci.yml`, nenhum `contactPoints` em
`grafana-alertas.yml`, nenhum `logging:` em `compose.obs.yml`, `LOKI_DATA` fora do `.env.exemplo`,
`CADVISOR_MEM_LIMIT=384m` ainda no template, nenhum `HEALTHCHECK` nos Dockerfiles,
`cinetra-prod-age.key` ainda no working tree, `.gitignore:17` ainda por nome exato.

### 1.4 A ferramenta que a onda 4 do doc 101 deixou pronta

`api/test/support/compose_de_producao.ex` (`Api.ComposeDeProducao`) já expõe `ler/0`, `caminho/0`,
`servico/2`, `valor_de/2` e `replicas/1`, e já é consumido por `Api.DeployEnvTest` e
`Api.DeployHorizontalidadeTest`. **É nele que quase toda guarda das ondas 1–3 se apoia** — o custo de
"provar que o compose declara X" caiu para escrever uma asserção. Isso muda o cálculo de vários
itens que o doc 95 estimou como S e aqui aparecem como XS.

---

## 2. Os achados

Não são repetidos aqui. Estão no [doc 95 §1](95-analise-infraestrutura.md), com `arquivo:linha` e
cenário de falha, e as evidências continuam válidas — reconferidas em 2026-08-04 (§1.3). Este
documento trata do **quando** e do **como se prova**.

---

## 3. O plano

Cinco ondas, 45 itens de risco em onda e 1 fora. O critério está no §1.1.

### Onda 1 — O que já falha, e falha calado

**Critério:** a consequência pode ocorrer hoje, sem ninguém fazer nada, e quando ocorrer **não deixa
rastro que alguém vá ver**. É a única onda em que o silêncio é o discriminante.

| # | Fecha | Ação | Esforço | Como se prova · mutação que valida |
| --- | --- | --- | --- | --- |
| 1.1 | **R-C1** | Provisionar contact point + notification policy no Grafana e apontar as 9 regras para ele | S | Seção nova no `deploy/observability/verificar.sh` que dispara uma regra de teste e confere a **entrega**, não o disparo. **Mutação:** apague o contact point → vermelho |
| 1.2 | **R-C3** | Tirar `cinetra-prod-age.key` da máquina; `.gitignore` passa a `*.key` + `!*.pub`. Se já circulou, **gerar par novo** e re-cifrar/descartar os dumps antigos | XS | Teste/script que falha se houver `*.key` no working tree do repositório. **Mutação:** `touch teste.key` → vermelho. **Limite honesto:** isso prova que a chave não está *aqui*; **não** prova que está offline — para onde a cópia foi é inverificável por automação |
| 1.3 | **R-A1** + **R-M1** | `stop_grace_period` nos serviços `api` (≥ 20 s, acima do grace do Oban) e `web` (≥ 35 s, acima do `SHUTDOWN_TIMEOUT` do adapter-node) **e** `Oban.Plugins.Lifeline` na lista de plugins de `api/config/config.exs:96-107` | XS | Teste sobre `Api.ComposeDeProducao` cobrando os dois `stop_grace_period`, no espírito do `Api.DeployHorizontalidadeTest`; e asserção de configuração cobrando `Lifeline`, no espírito do `Api.ObanPoolTest`. **Mutação:** remova o `Lifeline` ou baixe o grace para 5 s → vermelho |
| 1.4 | **R-A2** | `Cache-Control: private, no-store` + `Vary: Cookie` nas respostas do grupo `(app)`, em `web/src/hooks.server.ts:45-47` | XS | Teste Vitest sobre o `handle`: rota de `(app)` traz o header, rota pública não. **Mutação:** remova a linha → vermelho |
| 1.5 | **R-A8** | Contenção: descartar no Alloy as linhas `DETAIL:`/`STATEMENT:` do container `db` (a allowlist completa fica na onda 5) | S | O `verificar.sh` já testa o **falso positivo** da redação (`:181-187`); acrescentar o caso positivo: uma linha `DETAIL: Key (…)=(…)` do `db` não chega ao Loki. **Mutação:** remova o `stage.drop` → vermelho |
| 1.6 | **R-M3** | `KEEP_ALIVE_TIMEOUT` no serviço `web`, maior que o idle do pool do Traefik | XS | Asserção de configuração via `Api.ComposeDeProducao`. **Mutação:** remova a env → vermelho. **Limite honesto:** o gate prova a configuração, **não** a ausência de 502 — a corrida é temporal e só se confirma observando `traefik_service_requests_total{code="502"}` em produção |
| 1.7 | **R-M10** | `pg_restore --list` no `deploy/backup/backup.sh`, entre o `pg_dump` (`:59`) e o sinal de sucesso (`:84`) | XS | Teste de shell com um dump truncado: o script sai != 0 e o `trap` manda `/fail`. **Mutação:** corrompa o dump e confira que o heartbeat **não** manda sucesso → vermelho |
| 1.8 | ação 11 | **Ensaiar o restore** num banco separado, cronometrando, e registrar o número | M | **Inverificável por automação** — é operação contra o bucket real. O que fica de guarda é o **número do RTO registrado** neste documento e no doc 87. Sem o ensaio, "temos backup" segue sendo hipótese |
| 1.9 | ação 12 | **Rotacionar** o que circulou no working tree: R2, client secret do Google e a chave `age` | S | **Inverificável por automação.** Exige janela: rotacionar `SECRET_KEY_BASE` derruba toda sessão viva |

**Dependências e ordem.**
- **1.1 antes de toda a onda 4.** Não adianta afinar limiar (4.1) nem criar alerta novo (4.3) enquanto
  o alerta não notifica ninguém — seria afinar um instrumento mudo.
- **1.2 antes de 1.8.** O ensaio de restore precisa da chave `age`; movê-la primeiro garante que o
  ensaio já exercite o caminho real ("montar só na hora"), que é o que `restore.sh:10-11` desenha.
- **1.3 é indivisível.** Só o `stop_grace_period` reduz a chance e não resgata; só o `Lifeline`
  resgata e continua matando job no meio. As duas metades entram juntas ou o item não fechou.
- **1.6 e 1.3 tocam o mesmo arquivo** (`compose.dokploy.yml`) — uma edição só. Ver §3.7.

**Janela.** 1.1 e 1.5 são **só na stack de observabilidade** — não tocam o produto. 1.3, 1.4 e 1.6
exigem **deploy** (código + recreate dos containers). 1.2, 1.8 e 1.9 são **operação**. 1.7 recria só
o container de backup.

---

### Onda 2 — O que tira o freio quando o incidente vem

**Critério:** sozinho não causa nada; **remove a contenção** de uma falha que a onda 1 não previne.
Todo item desta onda é invisível enquanto nada dá errado — e é exatamente por isso que ele fica para
depois da onda 1, e não para depois de tudo.

| # | Fecha | Ação | Esforço | Como se prova · mutação que valida |
| --- | --- | --- | --- | --- |
| 2.1 | **R-A4** | `mem_limit` em `db`, `api`, `web` e `backup-cron` de `compose.dokploy.yml` | XS | O teste que o [doc 87 §8](87-servidor-hostinger-riscos-e-cuidados.md:400-412) já especificou, agora barato via `Api.ComposeDeProducao`. **Mutação:** remova um `mem_limit` → vermelho |
| 2.2 | **R-A7** + **R-B8** | `healthcheck` nos serviços de longa duração dos **dois** composes (`api`, `web`; e Grafana, Alloy, cAdvisor, node-exporter na obs — o Tempo fica de fora, com a justificativa de imagem distroless que `compose.obs.yml:426-435` já registra) | XS | Mesma família de asserção, estendida ao `compose.obs.yml`. **Mutação:** remova um `healthcheck` → vermelho |
| 2.3 | **R-M2** | `shm_size: 256m` no serviço `db` | XS | Mesma família. **Mutação:** remova → vermelho |
| 2.4 | **R-A5** | `LOKI_DATA` no `deploy/observability/.env.exemplo`, apontando para o volume limitado, com `criar-volume-limitado.sh` como passo obrigatório do provisionamento | S | `verificar.sh`: o volume do Loki é o limitado (confere mountpoint e tamanho), não o volume nomeado. **Mutação:** aponte para `loki_data` → vermelho |
| 2.5 | **R-A6** | `x-logging` também no `compose.obs.yml` — a âncora já existe em `compose.dokploy.yml:38-42`, é copiar | XS | Asserção de que todo serviço da obs declara `logging`. **Mutação:** remova de um → vermelho |
| 2.6 | **R-M18** | `CADVISOR_MEM_LIMIT` volta a `512m` no `.env.exemplo:70` | XS | Gate genérico e o mais valioso desta onda: um teste que compara o `.env.exemplo` com os **defaults do compose** e falha quando o template **rebaixa** um teto. **Mutação:** volte 384m → vermelho. Pega a classe inteira, não só este caso |
| 2.7 | **R-M11** | Volume dedicado para o `mktemp` do dump (`backup.sh:54`), fora do disco do `pgdata` | S | Asserção de compose (o serviço declara o volume) + `verificar.sh` conferindo que o `TMPDIR` do container aponta para lá. **Mutação:** remova o volume → vermelho |
| 2.8 | **R-M16** | Trocar `depends_on: loki condition: service_healthy` do Grafana (`compose.obs.yml:105-107`) por `service_started`, ou remover | XS | Asserção de compose. **Mutação:** volte o `service_healthy` → vermelho. **E o teste real é operacional:** reiniciar a máquina com o Loki degradado e confirmar que o Grafana sobe |
| 2.9 | **R-M12** | Limite de CPU nos containers de observabilidade (e avaliar no build, [D-21](50-debitos-tecnicos.md)) | XS | Asserção de compose (`cpus` declarado). **Limite honesto:** o gate prova a declaração; a **eficácia** é medição sob carga, que é o que o D-21 diz faltar |

**Dependências e ordem.**
- **`criar-volume-limitado.sh` antes de 2.4.** Apontar `LOKI_DATA` para um volume que não existe
  troca "sem teto" por "Loki não sobe".
- **2.8 antes de qualquer teste de reboot.** Enquanto o Grafana depender do Loki saudável, um reboot
  com o volume cheio (o cenário de `criar-volume-limitado.sh:52-55`) derruba junto os alertas de
  disco e memória — ou seja, o instrumento que mediria o próprio reboot.
- **2.1, 2.2, 2.3 e 2.7 tocam `compose.dokploy.yml`**, junto com 1.3 e 1.6. Ver §3.7.

**Janela.** 2.4, 2.5, 2.6, 2.8 e 2.9 são **só observabilidade**. 2.1, 2.2, 2.3 e 2.7 exigem
**recreate dos containers do produto** — e `mem_limit` e `shm_size` não são aplicáveis a quente:
o container precisa nascer de novo.

---

### Onda 3 — O que faz o caminho até produção ser o risco

**Critério:** o defeito **não está no sistema no ar** — está no processo que o substitui. Nada aqui
melhora a produção de hoje; tudo aqui decide se a produção de amanhã nasce sã.

| # | Fecha | Ação | Esforço | Como se prova · mutação que valida |
| --- | --- | --- | --- | --- |
| 3.1 | **R-A10** + **R-B3** | `permissions: contents: read` no topo de `.github/workflows/ci.yml`, escopo mínimo por job, e `timeout-minutes` em todos | XS | Teste que lê o workflow e cobra as duas chaves, no mesmo espírito do `Api.ComposeDeProducao` (ou `actionlint` no CI). **Mutação:** remova o bloco `permissions` → vermelho |
| 3.2 | **R-M6** | Fixar todas as `uses:` por SHA de 40 caracteres (`ci.yml:40,43,49,134,137,143,186,189`) | S | Mesmo leitor: toda `uses:` casa `@[0-9a-f]{40}`. **Mutação:** volte uma para `@v4` → vermelho |
| 3.3 | **R-M7** | `dependabot.yml` (actions + npm + hex + imagens) e passos de auditoria: `mix hex.audit`/`mix_audit` e `npm audit --audit-level=high` | S | O gate **é** o passo do CI. **Limite honesto:** manter uma dependência vulnerável de propósito para provar a mordida é caro e apodrece; aqui a guarda é a existência do passo, verificada pelo leitor de workflow de 3.1 |
| 3.4 | **R-M4** + **R-M8** | Construir a imagem de produção **no CI** (publicando num registry e mandando o Dokploy consumir por digest, ou ao menos buildando para validar) e fixar as imagens base por digest | M | O gate principal vem de graça: a guarda de sourcemap de `web/Dockerfile.prod:44-48` passa a rodar **antes** do merge. **Mutação:** deixe um `.map` em `build/client` → vermelho no CI, não no painel do Dokploy. **Bônus medido:** tira o build dos 90% de CPU da máquina de produção (D-21) |
| 3.5 | **R-M5** | Verificação pós-deploy: depois do webhook (`ci.yml:229`), aguardar `/ready` do ambiente devolver 200, com timeout, e falhar o job se não subir | S | O próprio passo. **Mutação:** aponte para um host inexistente → o job fica vermelho em vez de verde |
| 3.6 | **R-A3** + **R-M20** | Estender a guarda de boot de `web/src/hooks.server.ts:20-21` para `ORIGIN` e `API_URL`, e trocar a comparação de string de `web/src/lib/csp.js:96` por validação com `new URL()` | S | Teste Vitest: `ORIGIN` ausente → throw; `API_URL` ausente → throw; `API_PUBLIC_ORIGIN` igual a `"https://"` (o caso do R-M20, em que os dois lados concordam e ambos são inválidos) → throw. **Mutação:** remova a validação → vermelho |
| 3.7 | **R-M22** | Gate de expand-contract: script que barra migration nova com `remove(`, `drop table` ou `rename` sem marcação explícita de fase | M | **Mutação:** escreva uma migration com `remove(` sem marcação → vermelho. **Limite honesto:** o gate **não** prova que a mudança é segura; prova que houve **decisão explícita**. É o máximo automatizável — a regra de [`59 §8`](59-deploy-dokploy-oci.md:315-333) é semântica |
| 3.8 | **R-M23** | Cobrir `api/lib/api/release.ex` — em especial que `with_admin_config/1` (`:165-180`) restaura a config no `after`, e que o app não termina conectado como owner | S | Testes diretos. **Mutação:** remova o `after` → vermelho. É o teste que impede a regressão mais cara possível: a API subir bypassando RLS, que a suíte (superusuário) não veria |
| 3.9 | **R-B2** | `web/.dockerignore` ganha `.env*`, `e2e/`, `sourcemaps/`, `playwright-report/`, `a11y-*.json` | XS | **Inverificável de forma útil por automação** — um gate sobre tamanho de contexto de build seria arbitrário e envelheceria. Entra por inspeção, e o risco residual é baixo: o estágio final copia só 4 caminhos (`web/Dockerfile.prod:60-65`) |

**Dependências e ordem.**
- **3.1 primeiro.** Tudo o mais no workflow passa a rodar sob o token restrito; inverter a ordem
  significa adicionar passos que executam código de terceiros (3.3, 3.4) sob o token amplo.
- **3.4 antes de 3.5 faz sentido, mas não é obrigatório.** Verificar `/ready` de uma imagem que o CI
  não construiu ainda vale — só verifica menos.
- **3.6 e 3.7 são independentes de tudo.**

**Janela.** **Nada nesta onda exige deploy nem reinício** — exceto 3.6, que é código do BFF e entra
no próximo deploy normal. É a onda mais segura de executar num sistema no ar, e a razão de ela não
ser a primeira é só que nenhum item dela conserta o que já está aberto.

---

### Onda 4 — O que faz a operação enxergar errado

**Critério:** o instrumento **existe e mente**, ou falta o instrumento para uma falha que já é
alertável. Depende inteiramente de 1.1 — afinar alerta que não notifica é cerimônia.

| # | Fecha | Ação | Esforço | Como se prova · mutação que valida |
| --- | --- | --- | --- | --- |
| 4.1 | **R-M13** | Alerta de disco (`grafana-alertas.yml:250`) ganha `by (mountpoint)` e trata à parte o loop do Loki, cujo enchimento **é** o mecanismo de contenção | S | `verificar.sh`: a expressão tem `by (mountpoint)` e o volume limitado não dispara `critico`. **Mutação:** tire o `by` → vermelho. **E o teste real é encher o volume limitado** e confirmar que o alerta certo dispara |
| 4.2 | **R-M14** | Jobs novos no Prometheus para Loki, Alloy, Tempo e Grafana; e **alerta de descarte de log** (`loki_write_dropped_entries_total`) | S | **O gate mais valioso do documento, e é genérico:** toda métrica citada na anotação de um alerta tem de responder no Prometheus. Hoje `grafana-alertas.yml:82-84` manda o operador comparar três contadores que **nenhum job raspa**. **Mutação:** cite uma métrica inexistente numa anotação → vermelho. É o análogo, para alertas, do que `verificar-paineis.py` já faz para dashboards |
| 4.3 | **R-M15** | Regras para o que já é coletado e não tem alerta: `api_prom_ex_oban_queue_length_count`, `container_health_state`, `container_oom_events_total`, `node_vmstat_oom_kill`, `node_filesystem_readonly`; mais banco fora e **expiração de certificado** | M | Cada regra com o `noDataState` decidido caso a caso, como `grafana-alertas.yml:39,75-76,117,230-232` já faz. **Mutação por regra:** force a condição e confira o disparo. O caso que mais importa é o da fila do Oban: job travado **sem exceção** não gera `job:exception` e por isso não dispara `cinetra-job-falhando` (`:177-208`) |
| 4.4 | **R-C2** (residual) | Acrescentar `delete_key(attributes, "url.full")` à poda de `alloy.alloy:274-289` | XS | `verificar.sh` confere que a lista de `delete_key` contém os quatro atributos. **Mutação:** remova um → vermelho. **Por que aqui e não na onda 1:** com o exportador inerte, o vazamento não pode ocorrer hoje — falha o desempate do §1.1 regra 2 |
| 4.5 | **R-B7** | Renumerar as duas seções "13" do `verificar.sh` (`:481` e `:576`) | XS | Asserção de unicidade dos números de seção. **Mutação:** duplique um número → vermelho. Importa porque `grafana-alertas.yml:85` manda *"rode `verificar.sh`, seção 9"* — runbook que cita por número precisa que o número seja único |

**Dependências e ordem.** **1.1 antes de tudo nesta onda.** Dentro dela: **4.2 antes de 4.3**, porque
criar alerta novo sobre métrica não raspada reproduz exatamente o defeito que 4.2 conserta.

**Janela.** **Toda a onda 4 é só observabilidade.** Não toca o produto, não exige deploy da aplicação.

---

### Onda 5 — Superfície, higiene e o que é decisão

**Critério:** reduz o **alcance** de um ataque ou de um erro, sem que haja gatilho conhecido hoje —
mais o que é **decisão humana e não obra**. É a onda em que "não fazer" é uma resposta legítima,
desde que registrada.

| # | Fecha | Ação | Esforço | Como se prova · mutação que valida |
| --- | --- | --- | --- | --- |
| 5.1 | **R-A9** | Socket proxy com allowlist (`/containers/json`, `/containers/*/logs`) na frente do Alloy; tirar `/var/run` do cAdvisor (`compose.obs.yml:379`); corrigir os comentários de `:470-473` e `:322-331`, que hoje afirmam que o `:ro` protege | M | `verificar.sh`: nenhum container monta `docker.sock` nem `/var/run` direto. **Mutação:** remonte o socket → vermelho |
| 5.2 | **R-M21** | Decidir a exposição de `/metrics`, Prometheus e Grafana na `dokploy-network`, que é compartilhada por todos os stacks da máquina (`targets/api-prod.yml:31-35`) | M | **Decisão, não obra.** As opções (rede dedicada de scrape, ou autenticação no `/metrics`) têm custo e o gatilho hoje é hipotético. O que fica registrado é que o argumento de `api/lib/api/prom_ex.ex:42-48` — *"quem já está dentro tem o Postgres ao lado"* — **não vale**: o Postgres só existe na rede `data` |
| 5.3 | **R-M17** | Identidade individual no Grafana (SSO / Cloudflare Access) no lugar da conta admin única | M | **Decisão, não obra.** O custo é operacional; o que a decisão compra é resposta para "quem consultou o agregado de todas as clínicas", que hoje não existe — `audit_events` é trilha da aplicação, não do Grafana |
| 5.4 | **R-M19** | Guardar as chamadas a `getClientAddress()` (`web/src/lib/server/api.ts:42`, `routes/api/client-error/+server.ts:75`) e **corrigir o comentário de `compose.dokploy.yml:262-267`**, que afirma o oposto do que o adapter faz | S | Teste Vitest: requisição sem o header configurado não vira 500. **Mutação:** remova a guarda → vermelho. Ligado a [D-16](50-debitos-tecnicos.md), cuja metade operacional (`CLIENT_IP_HEADER=CF-Connecting-IP` no painel) segue pendente desde a onda 1 do doc 101 |
| 5.5 | **R-B5** | `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()` (+ COOP/CORP) em `web/src/hooks.server.ts:45-47` | XS | Teste Vitest de header, igual ao de 1.4. **Mutação:** remova → vermelho |
| 5.6 | **R-B6** | `report-to`/`report-uri` na CSP de `web/svelte.config.js:18-43`, apontando para a tubulação que já existe (`routes/api/client-error`) | S | Teste de que a diretiva está presente. **O ganho concreto:** hoje, se um build sair sem `R2_ACCOUNT_ID`, todo upload de anexo morre e o motivo fica só no console do browser do usuário |
| 5.7 | **R-B9** | Guardar a chave vazia do rate limiter do BFF (`routes/api/client-error/+server.ts:75`) | XS | Teste com XFF presente e vazio: não colapsa todos num balde só. **Mutação:** remova a guarda → vermelho |
| 5.8 | **R-B1** | Corrigir a deriva: `api/lib/api_web/router.ex:33` diz 400/min, `plugs/rate_limit_global.ex:48` diz `@edge_limit 2_000` | XS | **Inverificável por automação de forma barata** (é prosa contra constante). Entra por inspeção — mas é o tipo de comentário que faz alguém dimensionar capacidade errado por 5× |
| 5.9 | **R-B4** | Tirar `admin:cinetra-local` de `deploy/observability/verificar.sh:22` | XS | Inspeção. Não vale em produção (`:?` obrigatório + bind em `127.0.0.1`), mas publica o padrão da senha |
| 5.10 | **R-B10** (residual) | Marcar `docs/17-deploy-fly.md` como histórico no topo e reconciliar `docs/05 §5` | S | Inspeção. A maior parte já fechou (§1.3) |

**Dependências e ordem.** Nenhuma interna. **5.2 e 5.3 são decisões** e podem ser respondidas com
"não, e aqui está o porquê" — o que fecha o item tão bem quanto executá-lo, desde que registrado.

**Janela.** 5.4, 5.5, 5.6 e 5.7 entram no próximo deploy normal do BFF. 5.1 é observabilidade. 5.8,
5.9 e 5.10 não exigem nada.

---

### 3.6 Fora de onda

| Item | Razão |
| --- | --- |
| **R-M9** · rate limiter em ETS | **Fechado por decisão medida** na onda 4 do doc 101: 0,31 µs → 938,2 µs por requisição (3.000×) para corrigir um teto que um nó só não infringe, e o achado subestimava o estrago (sem `DNS_CLUSTER_QUERY`, réplica mata PubSub, presença e cache de fuso antes de dobrar o rate limit). `Api.DeployHorizontalidadeTest` transformou a armadilha em falha na hora. **Não é pendência — é decisão com guarda.** Muda a recomendação do doc 95, ação 29 |
| **Declarar RTO/RPO** | **Decisão humana recorrente, não obra.** O ensaio de restore (1.8) produz o número; declarar o compromisso é decisão de produto, e ela se revisita a cada mudança de porte. Não tem onda, pelo mesmo motivo que o A1 do [doc 101](101-plano-de-acao-analise-arquitetural.md:159-161) não tem |
| **`CLIENT_IP_HEADER=CF-Connecting-IP`** ([D-16](50-debitos-tecnicos.md)) | **Operação, não código** — variável no painel do Dokploy, nos dois stacks. Já era o item 1.9 da onda 1 do doc 101 e segue pendente. Fica registrado aqui porque toca R-M19 (5.4), mas o conserto não é deste plano |

---

### 3.7 A regra de janela

**A onda define prioridade; a janela define agendamento.** Num sistema no ar as duas divergem, e
ignorar isso multiplica reinícios sem necessidade.

| Janela | Itens | Custo |
| --- | --- | --- |
| **Só observabilidade** — não toca o produto | 1.1, 1.5, 2.4, 2.5, 2.6, 2.8, 2.9, toda a onda 4, 5.1 | Nenhum para o usuário. **Pode entrar a qualquer hora** |
| **Repositório/CI** — sem reinício | Toda a onda 3 exceto 3.6; 5.8, 5.9, 5.10 | Nenhum |
| **`compose.dokploy.yml`** — recreate dos containers do produto | 1.3, 1.6, 2.1, 2.2, 2.3, 2.7 | Downtime de deploy. **Devem entrar numa edição só** |
| **Código do BFF/API** — deploy normal | 1.3 (`Lifeline`), 1.4, 3.6, 5.4, 5.5, 5.6, 5.7 | Downtime de deploy |
| **Operação** — painel, máquina, provedor | 1.2, 1.8, 1.9, D-16 | Variável; 1.9 derruba sessões vivas |

**A consequência prática:** os seis itens de `compose.dokploy.yml` estão espalhados entre as ondas 1
e 2, mas **a edição é uma só**. Se as duas ondas não forem no mesmo dia, a alternativa honesta é
levar os quatro itens da onda 2 junto com a janela da onda 1 — eles são XS, e um segundo recreate
para acrescentar `mem_limit` custa mais que executá-lo cedo. **A onda diz o que é urgente; ela não
manda desperdiçar janela.**

---

## 4. Execução

Preenchido conforme as ondas entram. Estado dos gates, o vermelho provado de cada conserto e o que
ficou para decisão humana — mesma estrutura do [doc 101 §4](101-plano-de-acao-analise-arquitetural.md).

### 4.1 Onda 1 — 2026-08-04

Sete dos nove itens entraram. Os dois que faltam (1.8 e 1.9) são operação contra o servidor e o
provedor, não código — seguem com o humano, e o §3.6 já os tratava como tal.

**Duas coisas mudaram o plano no meio da execução, e as duas por medição.** Estão em O que entrou,
mas valem o destaque aqui porque a segunda teria produzido uma proteção decorativa:

1. **A verificação de backup que o doc 95 recomendou não funciona.** `pg_restore --list` sai **0**
   sobre um dump cortado ao meio. Trocado por `pg_restore -f /dev/null`.
2. **O `STATEMENT:` do Postgres é multilinha, e a continuação não repete o rótulo.** Um filtro só
   pelo rótulo mataria a linha vazia e deixaria passar exatamente a que carrega o nome do paciente.

#### Estado dos gates

**Nota de honestidade sobre a coluna "Antes":** ela está vazia porque **não foi medida**. A sessão
começou com o working tree já sujo de outra frente (`api/lib/api/email_layout.ex` e dois testes de
messaging modificados), então um número "antes" colhido aqui não seria o baseline de `develop` —
seria o baseline daquele trabalho em curso, e apresentá-lo como referência desta onda induziria
erro. O que está abaixo é o estado **depois**, medido, mais o delta de testes que esta onda
acrescentou, que é contagem e não medição.

| Gate | Depois (medido em 2026-08-04) |
| --- | --- |
| `mix format --check-formatted` | **ok** |
| `mix compile --force --warnings-as-errors` | **ok** — exit 0, 0 warnings, 272 arquivos |
| `mix test` | **1.989 · 1 falha** (+9 testes nesta onda). A falha é a guarda de 1.2 — ver abaixo |
| `mix test --only rls` (como `cinetra_app`) | **0 falhas** |
| `mix coveralls` (piso 80) | **90,3%** |
| `npm run check` | **0 erros, 0 warnings** |
| `npm run coverage` (pisos 80/80/80/75) | **2.540 testes · 93,07% stmt · 79,54% branch** (+5 testes nesta onda) |
| `deploy/observability/verificar.sh` | **não executado** — o stack `cinetra-obs` não sobe nesta máquina de dev. As §15 e §16 novas são código não exercitado; ver O que NÃO entrou |

> `npm run coverage` emite um `PARSE_ERROR` do `@vitest/coverage-v8` ao remapear **arquivos não
> cobertos**. Não reprova o gate (exit 0) e não toca nenhum arquivo desta onda — os dois que foram
> alterados no `web/` têm teste. Fica registrado por não ter sido investigado, não por ter sido
> descartado.

> **A falha do `mix test` é deliberada e não é regressão.** `Api.SegredoNoWorkingTreeTest`
> reprova enquanto houver `.key`/`.pem` na raiz do repositório, e a chave `age` de produção ainda
> estava lá quando estes gates rodaram. Ela fica verde no momento em que a chave sair da máquina —
> que é o item 1.2 do lado da operação. **No CI a chave nunca esteve** (nunca foi commitada), então
> lá o teste é verde desde já.

#### O que entrou

**1.1 — R-C1, o alerta ganha destino.** `contactPoints` e `policies` provisionados em
`deploy/observability/grafana-alertas.yml`: contato `cinetra-plantao` por e-mail, destinatário vindo
de `${GRAFANA_ALERTA_EMAIL}` (a mesma interpolação já provada em produção pelo
`grafana-datasources.yml`), e uma árvore de roteamento cuja **raiz** é o plantão — de modo que
alerta novo que ninguém roteou falhe para o lado seguro em vez de sumir no `grafana-default-email`.
`severity=critico` repete de hora em hora contra as 4 h do `aviso`; `singleEmail: true` para que um
alerta em 8 clínicas não vire 8 e-mails. O `.env.exemplo` ganhou as cinco `GRAFANA_SMTP_*`, que
**não existiam no template** — quem provisionasse pelo arquivo não via que elas existiam — mais o
aviso de que `GRAFANA_ROOT_URL` em `localhost` produz e-mail de alerta com link que não abre.

Decisões registradas: API key do Resend **separada** da do produto (copiar a do produto amplia o
alcance de um vazamento e impede revogar uma sem derrubar a outra), e a dependência assumida de
olhos abertos — com o Resend nos dois lados, uma queda dele apaga o alerta e o e-mail ao paciente
juntos; quem cobre isso é o monitor externo do doc 62 §12.

**1.2 (metade de código) — R-C3, a regra de ignore deixa de ser um nome.** `.gitignore` passou de
`cinetra-prod-age.key` para `*.key` + `*.pem` + `!*.pub`. Medido antes e depois com
`git check-ignore`: `cinetra-hml-age.key` e `cinetra-prod-age-2.key` **não** casavam antes e casam
agora; `cinetra-prod-age.pub` segue **não** ignorado, que é o certo — a chave pública é o
`recipient` com que o `backup.sh` cifra e precisa ser versionada. `Api.SegredoNoWorkingTreeTest`
prende as duas metades: o padrão no `.gitignore` e a ausência de chave na raiz.

**1.3 — R-A1 + R-M1, o job órfão.** `stop_grace_period: 25s` no `api` (acima dos 15 s de drain do
Oban) e `35s` no `web` (acima dos 30 s de `SHUTDOWN_TIMEOUT` do adapter-node), mais
`{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}` em `api/config/config.exs`. Os 60 min
são o default, escritos explicitamente porque o número merece ser lido: o `Lifeline` decide por
tempo e não por saber se o nó está vivo, então um valor curto demais ressuscitaria job em execução
— na fila `notifications`, lembrete duplicado para o paciente.

**1.4 — R-A2, PHI fora do cache do browser.** `Cache-Control: private, no-store` + `Vary: Cookie`
para toda rota do grupo `(app)`, em `web/src/hooks.server.ts`. O `Vary` é `append` e não `set`
porque o `gzipResponse` acrescenta `accept-encoding` logo depois — e há teste que fixa que os dois
convivem, porque um `set` de qualquer um dos lados apagaria o outro sem nenhum teste sem gzip
perceber. Registrado no comentário o que a medida **não** garante: `no-store` fecha o cache HTTP,
que é o caminho do cenário; o bfcache é decisão do browser e vem mudando.

**1.5 — R-A8, contenção do log do Postgres.** `stage.match` por `service` no `alloy.alloy`,
descartando `DETAIL:`/`STATEMENT:`/`CONTEXT:`/`HINT:` **e** as linhas de continuação indentadas. O
`ERROR:` fica de propósito: ele diz que houve violação e em qual constraint, sem dizer de quem.

Provocada uma violação de unicidade real no container `db` para ler o formato, e foi ela que
mostrou o buraco do plano original — o `STATEMENT:` quebra em várias linhas e só a primeira leva o
rótulo:

```
… [33091] ERROR:  duplicate key value violates unique constraint "prova_pii_cpf_key"
… [33091] DETAIL:  Key (cpf)=(11122233344) already exists.
… [33091] STATEMENT:
\tinsert into prova_pii values ('Maria Aparecida da Silva', '11122233344');
```

Os dois regexes foram rodados contra essas linhas capturadas: as três com o nome somem, o `ERROR:`
e os `LOG:` de checkpoint sobrevivem, e `grep -c 'Maria Aparecida'` no que sobra devolve **0**. O
arquivo inteiro foi validado com o binário real (`alloy fmt`, exit 0) — erro de sintaxe ali derruba
o pipeline de log e de trace no deploy, e não haveria teste para pegar.

**1.6 — R-M3, a corrida do keep-alive.** `KEEP_ALIVE_TIMEOUT: "95"` no serviço `web`. Em
**segundos** — o adapter-node multiplica por 1000 —, acima dos 90 s de `idleConnTimeout` do Traefik.

**1.7 — R-M10, o backup deixa de declarar sucesso sem olhar o arquivo.** E aqui a recomendação do
doc 95 caiu. Medido contra o `db`, três arquivos:

| dump | `pg_restore --list` | `pg_restore -f /dev/null` |
| --- | --- | --- |
| íntegro (734 KB) | 0 · 571 entradas | 0 |
| cortado ao meio | **0** ← o buraco | 1 · `could not read from input file: end of file` |
| 512 bytes zerados no meio | **0** ← o buraco | 1 · `could not uncompress data: incorrect data check` |

`--list` lê só o TOC, que no formato custom mora no **início** do arquivo — ele sai 0 sobre um dump
em que todo o dado se perdeu. Quem adotasse a recomendação teria uma verificação decorativa, que é
o mesmo defeito do R-C1 num lugar diferente. Adotado `-f /dev/null`, que converte o arquivo inteiro
em SQL e descarta, obrigando a ler e descomprimir cada bloco. Custo medido: **34 ms** contra 27 ms
do `--list`, ~17% do tempo do próprio `pg_dump`.

**Duas armadilhas de vacuidade nos testes desta onda, pegas na primeira execução.** Em Elixir
`nil >= 1_800_000` e `50 < nil` são **true** — átomo ordena acima de número. Sem um `is_integer`
antes da comparação, o teste do `rescue_after` passava verde com o `Lifeline` ausente, e o da ordem
do `backup.sh` passava verde sem verificação nenhuma no script. É a mesma classe de defeito que o
`Api.ComposeDeProducao` guarda por dentro, e ela reapareceu em código escrito para combatê-la.

#### O que NÃO entrou

- **1.8 — ensaio de restore** e **1.9 — rotação de segredos.** Operação contra o servidor e o
  provedor; nenhum é código. O 1.9 exige janela: rotacionar derruba sessão viva.
- **A metade operacional do 1.2.** A chave `age` sair desta máquina. Enquanto não sair, a guarda
  fica vermelha — e é ela que confirma quando sair.
- **A execução do `verificar.sh`.** As §15 (contenção do log do Postgres) e §16 (o alerta chega)
  foram escritas e passam no `bash -n`, mas **não foram exercitadas contra um stack de pé**: o
  `cinetra-obs` não sobe nesta máquina. Ficam como código não verificado até rodarem em HML ou
  produção. A §16 tem envio real atrás de `PROVAR_ALERTA=1`, no mesmo espírito do `PAUSAR_DB=1` da
  §8 — prova que custa alguma coisa não pode rodar a cada execução.
- **Nenhuma mudança foi implantada.** Tudo aqui é working tree; `compose.dokploy.yml`,
  `alloy.alloy` e `grafana-alertas.yml` só valem depois do deploy. Ver §3.7: as três edições do
  compose (1.3 × 2 e 1.6) são uma recriação só.

#### Placar da onda 1

| Item | Resultado |
| --- | --- |
| 1.1 (R-C1) | ✅ provisionado · ⏳ entrega não provada por script (§16 não executada) |
| 1.2 (R-C3) | ✅ `.gitignore` + guarda · ⏳ a chave ainda está na máquina (guarda vermelha, de propósito) |
| 1.3 (R-A1, R-M1) | ✅ vermelho provado → verde |
| 1.4 (R-A2) | ✅ vermelho provado → verde |
| 1.5 (R-A8) | ✅ regexes medidos contra log real · ⏳ §15 não executada |
| 1.6 (R-M3) | ✅ vermelho provado → verde |
| 1.7 (R-M10) | ✅ **recomendação do doc 95 refutada por medição** e substituída |
| 1.8 (ensaio de restore) | ⬜ não iniciado — operação |
| 1.9 (rotação de segredos) | ⬜ não iniciado — operação, exige janela |

### 4.2 Onda 2 — 2026-08-04

Os nove itens entraram, na mesma sessão da onda 1 e de propósito: o §3.7 já dizia que **seis itens
das duas ondas tocam o `compose.dokploy.yml` e a edição é uma só**. Adiar a onda 2 custaria um
segundo *recreate* dos containers do produto para acrescentar linhas XS.

**O item 1.9 (rotação de segredos) foi fechado pelo operador** — as chaves foram rotacionadas junto
com a subida. A metade operacional do 1.2 (a chave `age` sair da máquina de desenvolvimento) segue
aberta, e a guarda segue vermelha; vale notar que rotacionar não a torna inócua enquanto houver
dump cifrado com o par antigo dentro dos 30 dias de retenção do `daily/`.

**Uma correção de plano e uma extensão declarada**, ambas por medição — o mesmo padrão da onda 1:

1. **O volume dedicado do 2.7 não faz o que o achado pedia.** R-M11 pede o dump "fora do disco do
   `pgdata`"; numa VPS de disco único isso **não existe**. Um volume nomeado continua no mesmo
   dispositivo. O que ele entrega de verdade é tornar o espaço contável e limitável; quem impede o
   dump de encher o disco do banco é um **preflight de espaço livre**, escrito junto.
2. **A imagem do Alloy não tem `wget` nem `curl`** — só `sh` e `bash`. Um healthcheck copiado do
   idioma dos vizinhos teria falhado sempre, deixando o container eternamente `unhealthy`.

#### Estado dos gates

| Gate | Depois (medido em 2026-08-04) |
| --- | --- |
| `mix format --check-formatted` | **ok** |
| `mix compile --force --warnings-as-errors` | **ok** — 0 warnings |
| `mix test` | **2.002 · 1 falha** (+13 nesta onda). A falha é a mesma guarda de 1.2 |
| `mix test --only rls` | **0 falhas** |
| `mix coveralls` (piso 80) | **90,3%** |
| `npm run check` | **0 erros, 0 warnings** |
| `npm run coverage` | **2.540 testes · 93,07% stmt** (o web não mudou nesta onda) |
| `docker compose config` (os **dois** arquivos) | **exit 0**, com env fictício — a estrutura resolvida foi conferida serviço a serviço |
| `deploy/observability/verificar.sh` | **não executado** (mesma razão da onda 1) |

#### O que entrou

**2.1 — R-A4, teto de memória.** `db` 1g, `api` 768m, `web` 512m, `backup-cron` 256m, todos
overridable por env como já se faz na obs. Os números têm piso medido: `docker stats` no dev ocioso
deu **199 MiB** para o Postgres e **232 MiB** para a BEAM. O `db` fica com ~5× e o `api` com ~3× —
folga para `work_mem` × 16 conexões do pool e para as duas filas do Oban.

Registrado no próprio compose o que o teto **não** faz: a soma dos tetos passa da RAM da máquina, e
isso é deliberado — teto é bound de pior caso, não reserva. Ele impede **um** container de comer
tudo; não impede esgotamento agregado. Quem responde por isso é a medição sob carga real
([D-21](50-debitos-tecnicos.md)).

**2.2 — R-A7 + R-B8, healthcheck de Docker.** Aqui a inspeção valeu mais que o código: cada imagem
foi aberta antes de escrever a linha, e as respostas foram diferentes.

| serviço | o que a imagem tem | endpoint | verificação |
| --- | --- | --- | --- |
| `api` | **nada** (`debian:bookworm-slim`, 4 pacotes) | `/api/health` | `curl` acrescentado ao `Dockerfile.prod` |
| `web` | `node` (fetch global) | `/health` | `node -e` |
| grafana | wget, curl, nc, bash | `/api/health` → `"database": "ok"` | ✅ exit 0 ao vivo |
| alloy | **só `bash`** | `/-/ready` → `Alloy is ready.` | ✅ exit 0 ao vivo, via `/dev/tcp` |
| cadvisor | wget | `/healthz` → `ok` | ✅ no container em execução |
| node-exporter | wget | `/metrics` → `node_exporter_build_info` | ✅ 3 linhas casam |

Os comandos foram extraídos do `docker compose config --format json` — o valor **resolvido**, não o
que está escrito no YAML — e rodados contra containers de verdade. O do Alloy precisa de `CMD` com
`bash` explícito: `CMD-SHELL` usaria `/bin/sh`, que é dash e não tem `/dev/tcp`.

O `curl` no `Dockerfile.prod` da API é a única mudança de imagem da onda. A alternativa sem tocar
nela seria `bin/api rpc`, que sobe uma BEAM inteira a cada checagem — caro numa máquina de 2 vCPU
onde o build já mede 90%. E os dois healthchecks apontam para **liveness**, não readiness:
reiniciar a API porque o banco piscou troca uma indisponibilidade curta por uma longa.

**2.3 — R-M2, `shm_size: 256m` no `db`.** Sem ele `/dev/shm` fica nos 64 MB de default do Docker, e
uma query com plano paralelo morre com `could not resize shared memory segment` — sintoma que não
parece disco nem memória.

**2.4 — R-A5, o teto de disco do Loki deixa de ser invisível.** `LOKI_DATA` e `TEMPO_DATA`
documentados no `.env.exemplo`, com o `criar-volume-limitado.sh` como passo **anterior** e a ordem
escrita: apontar para um caminho inexistente troca "sem teto" por "o Loki não sobe".

**2.5 — R-A6, rotação de log na obs.** Âncora `x-logging` copiada do outro compose e aplicada aos 7.
Era onde mais doía: `cinetra-obs` está fora da allowlist de coleta, então esses arquivos cresciam
**invisíveis**, no mesmo disco do `pgdata`.

**2.6 — R-M18, e o gate que vale mais que o item.** `CADVISOR_MEM_LIMIT` de volta a `512m`. O que
importa é o `Api.EnvExemploTest`: ele compara **todo** `*_MEM_LIMIT` do `.env.exemplo` com o default
do compose e reprova qualquer **rebaixamento**. `>=` e não `==`, de propósito — subir um teto é
escolha legítima de quem opera máquina maior; baixá-lo abaixo do que foi medido é a regressão.
Mutação provada nos dois sentidos: repus `384m` e ficou vermelho com a mensagem certa; restaurei e
voltou verde. Um teste que cobrasse `== 512m` pegaria este caso e nenhum outro.

**2.7 — R-M11, e a correção do plano.** `TMPDIR=/var/tmp/backup` sobre um volume nomeado montado em
`backup` e `backup-cron`. Mas o ganho real é o **preflight**: `pg_database_size` contra `df` antes
do `pg_dump`, abortando se o livre for menor que o tamanho do banco (teto generoso — o dump não
escreve índices e ainda comprime; `BACKUP_FOLGA_PCT` ajusta). Medido nas duas direções contra o
`db`: com folga de 100% segue (941 GB livres contra banco de 47 MiB); com folga forçada acima do
disco, aborta. Só serve antes de começar — abortar no meio do dump já consumiu o espaço. E o
agravante que o torna mais que higiene: o serviço `backup` roda **antes** do `migrate` e é
fail-closed, então disco cheio no dump vira **deploy travado**, justamente quando o deploy é o
hotfix do incidente.

**2.8 — R-M16, e uma extensão declarada.** O Grafana passou a `condition: service_started` no Loki.
**Estendi para o Alloy**, que o plano não pedia: lá era `service_healthy` pelo mesmo mecanismo, e um
reboot com o volume do Loki cheio parava junto a coleta de **trace**, que não tem relação com o
Loki. O custo de afrouxar é zero — o `loki.write` tem WAL e reenvia. Fica registrado como extensão,
não como item cumprido.

**2.9 — R-M12, teto de CPU.** `cpus` nos 7 da obs, com o Loki no maior (1.0 dos 2 vCPU): é a
consulta LogQL de 30 dias, aberta **durante** um incidente, o cenário em que a ferramenta de
diagnóstico vira a causa.

**A ferramenta.** `Api.ComposeDeProducao` ganhou `ler_obs/0` e `ler_do_repo/1` em vez de um módulo
irmão — o moduledoc dele já dizia por quê: duas cópias que fatiam YAML de formas ligeiramente
diferentes deixam de significar a mesma coisa. Os dois composes e o `.env.exemplo` passam pelo mesmo
recorte e pelas mesmas guardas contra vacuidade.

#### O que NÃO entrou

- **Nada foi implantado.** Tudo é working tree. Os itens de compose das ondas 1 e 2 estão prontos
  para **uma** janela de recreate, como o §3.7 pediu.
- **`docker compose config` não é o servidor.** Ele prova que a estrutura resolve; que o teto
  contenha um vazamento, que o healthcheck reinicie um processo travado e que o Grafana suba com o
  Loki degradado, só o servidor mostra. O 2.8 tem teste operacional próprio — reiniciar a máquina
  com o Loki degradado — que não foi feito.
- **O `verificar.sh` segue não executado**, agora com mais superfície nova acumulada (§15 e §16 da
  onda 1). É a maior dívida de verificação das duas ondas.

#### Placar da onda 2

| Item | Resultado |
| --- | --- |
| 2.1 (R-A4) | ✅ vermelho provado → verde · tetos com piso medido |
| 2.2 (R-A7, R-B8) | ✅ vermelho provado → verde · 4 healthchecks verificados ao vivo · +`curl` na imagem da API |
| 2.3 (R-M2) | ✅ vermelho provado → verde |
| 2.4 (R-A5) | ✅ documentado no template, com a ordem de execução escrita |
| 2.5 (R-A6) | ✅ vermelho provado → verde |
| 2.6 (R-M18) | ✅ **mutação provada nos dois sentidos** · o gate cobre a classe, não o caso |
| 2.7 (R-M11) | ✅ volume + **preflight medido** · a recomendação original não era alcançável em disco único |
| 2.8 (R-M16) | ✅ vermelho provado → verde · **estendido ao Alloy**, declarado |
| 2.9 (R-M12) | ✅ vermelho provado → verde · eficácia depende de medição sob carga (D-21) |

### 4.3 Onda 3 — 2026-08-04

Os nove itens entraram. É a onda que **não exige deploy** — nada aqui melhora a produção de hoje,
tudo aqui decide se a produção de amanhã nasce sã.

**E ela pagou no ato.** Ligar as duas auditorias que não existiam encontrou **três advisories
reais** em dependências que já estavam no repositório, todas corrigidas por atualização dentro do
mesmo major. Não foram achados de análise: foram achados de gate, no primeiro segundo em que o gate
existiu.

#### Estado dos gates

| Gate | Depois (medido em 2026-08-04) |
| --- | --- |
| `mix format --check-formatted` | **ok** |
| `mix compile --force --warnings-as-errors` | **ok** — 0 warnings |
| `mix deps.audit` | **ok** — nenhuma vulnerabilidade |
| `mix hex.audit` | **ok** — nenhum pacote retirado ou com advisory (**era vermelho**, ver abaixo) |
| `mix test` | **2.022 · 1 falha** (+20 nesta onda). A falha é a mesma guarda de 1.2 |
| `mix test --only rls` | **0 falhas** |
| `mix coveralls` (piso 80) | **90,5%** |
| `npm audit --audit-level=high` | **0 vulnerabilidades** (**era 2 HIGH**, ver abaixo) |
| `npm run check` | **0 erros, 0 warnings** |
| `npm run coverage` | **210 arquivos · 93,09% stmt · 79,64% branch** |
| YAML do `ci.yml` e do `dependabot.yml` | **parseia** · 5 jobs, todos com `timeout-minutes` |
| `deploy/observability/verificar.sh` | **não executado** (mesma razão das ondas 1 e 2) |

#### O que entrou

**3.1 — R-A10 + R-B3, o teto do token.** `permissions: contents: read` no nível do workflow, e
`timeout-minutes: 20` (30 no build de imagem) nos cinco jobs. O job `deploy` — o único com o
webhook de produção no ambiente — recebeu `permissions: {}`: ele não faz checkout e não lê o
repositório, então não precisa de token nenhum.

**3.2 — R-M6, tag vira commit.** As seis `uses:` fixadas por SHA de 40 caracteres, com a versão no
comentário ao lado (a forma que o Dependabot entende e atualiza). Fixadas na versão **atual** de
cada uma, não na mais nova: o item é "fixar", não "atualizar" — subir `actions/checkout` de v4 para
v7 é outra decisão, e agora ela chega como PR revisável.

Os seis commits foram **conferidos contra a API do GitHub** um a um (`repos/<org>/<repo>/commits/<sha>`),
porque SHA digitado errado falha só no runner, e falha de um jeito que parece problema de rede.

**3.3 — R-M7, e os três advisories que ele achou na hora.** `mix_audit` como dependência de
`:dev, :test`, os passos `mix deps.audit` + `mix hex.audit` no job `api`, `npm audit
--audit-level=high` no job `web`, e `.github/dependabot.yml` cobrindo cinco ecossistemas
(`github-actions`, `mix`, `npm`, `docker`, `docker-compose`), com agrupamento por família — Ash e
Phoenix têm versões acopladas, e um PR por pacote produz build quebrado e revisão inútil.

O que os gates acusaram no primeiro run, e o que se fez:

| Onde | Achado | Escopo real | Conserto |
| --- | --- | --- | --- |
| `mix hex.audit` | `ymlr 5.1.5` — YAML injection (LOW) | **produção**: `ash → reactor → ymlr` | `mix deps.update ymlr` → 5.1.6 |
| `npm audit` | `postcss ≤8.5.22` — path traversal (HIGH) | dev: `vite → postcss` | `npm audit fix` → 8.5.25 |
| `npm audit` | `undici 7.0.0–7.28.0` — 5 advisories, entre eles **divulgação de informação entre usuários** (HIGH) | dev: `jsdom → undici` | `npm audit fix` → 7.29.0 |

**Uma distinção que evitou alarme falso e merece registro:** o `undici` do `npm audit` **não é** o
que o BFF usa. O `fetch` global do adapter-node é o undici **embutido no Node**, não este pacote —
aqui ele entra por `jsdom`, que é o ambiente de teste do Vitest. Verificado:
`npm ls undici --omit=dev` devolve vazio, então nenhum dos dois vai para a imagem
(`npm prune --omit=dev`). O advisory de "cross-user information disclosure" seria assustador num
BFF de saúde que proxia toda chamada — e não se aplica a ele. Consertado do mesmo jeito, porque
cadeia de build comprometida também é comprometimento.

**Os dois gates ficaram verdes por o problema ter sido consertado, não por terem sido afrouxados.**
Era a alternativa disponível e recusada: `|| true` no passo, ou baixar `--audit-level`. Gate que
nasce vermelho e é contornado no mesmo dia não é gate — é cerimônia.

**3.4 — R-M4 + R-M8, a imagem passa a nascer no CI.** Job `imagem` novo, construindo as duas
imagens de produção com cache do Actions. Fecha o buraco que mais importava: a guarda de sourcemap
de `web/Dockerfile.prod` — a última fronteira contra o código-fonte ir para produção — **nunca
rodava antes do merge**. Erro de Dockerfile aparecia no painel do Dokploy depois do merge em `main`,
com o sintoma "o deploy não subiu" e sem log no GitHub.

As cinco imagens base fixadas por digest de **índice multi-arch** (`application/vnd.oci.image.index.v1+json`,
verificado para as cinco) — e não por digest de plataforma, que quebraria se a máquina mudar de
arquitetura. Mantido o formato `imagem:tag@sha256:…`, que é o que o Dependabot atualiza.

**O que NÃO entrou aqui:** publicar num registry e mandar o Dokploy consumir por digest. Isso
precisa de credencial de registry e de reconfigurar o Dokploy — decisão que não é minha. Enquanto
não for tomada, o build continua acontecendo no servidor e continua consumindo ~90% dos 2 vCPU
(D-21); o que este job entrega é o **gate**, não o alívio de CPU.

**3.5 — R-M5, o deploy deixa de ser fire-and-forget.** Depois do webhook, o job espera o
readiness responder 200, com até 5 min de tolerância (o relógio começa antes do build no
servidor, não depois), e falha se não subir. Readiness e não `/health`: ele toca o banco, então é
o único que distingue "o container subiu" de "o deploy funcionou" — inclusive pega migration que
rodou pela metade.

> **CORREÇÃO DE 2026-08-05.** Esta entrega nasceu batendo em `${BASE}/api/ready`, que **não é
> alcançável de fora**: no desenho BFF-only o Traefik só encaminha `/socket` e `/webhooks` para a
> API, e todo o resto do domínio vai para o BFF — 404 do catch-all. Como os secrets `DEPLOY_URL_*`
> nunca foram configurados, o passo sempre saiu pelo `::warning::` e o defeito ficou invisível;
> configurá-los teria reprovado deploys que funcionaram. Corrigido para `${BASE}/ready` (o
> readiness do BFF, que consulta o `/api/ready` da API pela rede interna) e preso por
> `Api.CiWorkflowTest`, com mutação conferida nos dois sentidos.

Depende de dois secrets novos (`DEPLOY_URL_PROD`, `DEPLOY_URL_HML`). Ausentes, o passo emite
`::warning::` dizendo **explicitamente que o deploy não foi verificado**, em vez de passar calado —
mesmo espírito do webhook ausente, e sem repetir o "silent cap" que o próprio doc 95 critica.

**3.6 — R-A3 + R-M20, a guarda de boot que faltava.** O projeto já tinha o padrão certo para
`API_PUBLIC_ORIGIN` (`hooks.server.ts` derruba o container de propósito, com a justificativa
escrita); três variáveis tinham ficado de fora dele. Agora `lib/server/boot.ts` cobra `ORIGIN`,
`API_URL` e `API_PUBLIC_ORIGIN`, **e valida com `new URL()`**.

A validação é o ponto, não a presença. O furo do R-M20 era este: com `WEB_HOST` indefinido, o
compose deriva a string literal `"https://"` nos dois lados, eles **concordam**, o
`autorizadas.includes(...)` casa, e a guarda devolvia `null` — container no ar, CSP com host
inválido, WebSocket morto, deploy verde. **Concordância não é validade**, e é isso que os testes
prendem.

A presença só é cobrada em produção (`NODE_ENV`), senão a guarda quebraria `vite dev`. E como o
`vite preview` do Playwright roda em production, o `playwright.config.ts` passou a declarar as
envs — o que faz a e2e exercitar a configuração de produção em vez de uma variante mais frouxa.

**3.7 — R-M22, o expand-contract ganha gate.** A regra do doc 59 §8 é boa, está escrita, e não
tinha automação nenhuma. Agora migration nova com `remove(`/`drop table`/`drop constraint`/`rename`
no `up` precisa declarar `# expand-contract: <justificativa>`.

Duas decisões de recorte, ambas medidas:

- **só o `up`.** `remove/1` no `down` é o rollback de um `add` e é normal. Das 84 migrations, 20
  têm operação destrutiva em algum lugar e apenas **4** a têm no `up`. Um gate sobre o arquivo
  inteiro acusaria 20 casos, 16 deles corretos — e gate que grita sobre o certo é gate que alguém
  desliga.
- **as 4 existentes ficam de fora**, numa lista fechada, porque já rodaram em produção e anotá-las
  retroativamente seria mexer em artefato aplicado — o que `.claude/rules/migrations.md`
  desaconselha. Um segundo teste cobra que **a lista não cresça**: se crescer, alguém contornou o
  gate em vez de usá-lo.

Mutação provada nos dois sentidos: criei uma migration com `remove(:cpf)` no `up` → vermelho com a
mensagem certa; acrescentei a marca → verde; removi o arquivo.

**O limite, escrito no próprio teste:** ele **não prova que a mudança é segura**. Saber se a coluna
ainda é lida pela versão em execução é semântico e depende de código que não está na migration. O
máximo automatizável é a diferença entre decisão explícita e distração.

**3.8 — R-M23, o `Api.Release` sai de um teste para nove.** Cobertos: a validação de identificador
nas duas funções (a de métricas não tinha), o `:desligado` de `setup_metrics_role/0` com senha
ausente e com senha vazia, e o `with_admin_config/1` inteiro.

O teste que importa é o do **caminho de exceção**: o caminho feliz restauraria a config por
acidente em quase qualquer implementação, e só o de erro distingue um `try/after` de um "restaurei
na última linha". Mutação provada: troquei o `try/after` por restauração sequencial → vermelho com
a mensagem certa; restaurei → verde.

A regressão que isso guarda é a mais cara possível e a que menos dá sintoma: sem o `after`, o
processo segue apontando para a conexão de **owner**, que bypassa RLS — e a suíte não veria, porque
ela já roda como superusuário. `with_admin_config/1` virou público com `@doc false` só para isso,
com o motivo escrito no código.

**3.9 — R-B2, o contexto de build do web.** `.dockerignore` de 4 para 20 linhas: `.env*`, `e2e/`,
`sourcemaps/`, `playwright-report/`, `coverage/`, `a11y-*.json`. Nunca foi vazamento para a imagem
final — o estágio `app` copia só quatro caminhos —, mas o contexto agora é enviado ao daemon **a
cada PR**, e a regra `.env*` previne o dia em que alguém criar um `web/.env` que o `loadEnv` do
`vite.config.ts` leria.

#### O que NÃO entrou

- **A publicação em registry** (metade do R-M4): precisa de credencial e de reconfigurar o Dokploy.
  **Feita depois, em 2026-08-05** — decidido GHCR, por tag, com `pull_policy: always`; ver
  [doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md).
- **Nenhum job novo foi executado de verdade.** `imagem` e a verificação pós-deploy só rodam no
  GitHub; aqui foram validados por parsing do YAML e pela conferência dos SHAs contra a API. **A
  primeira execução real é o próximo PR**, e é onde eles podem falhar por algo que este ambiente
  não mostra.
- **Os dois secrets do 3.5** (`DEPLOY_URL_PROD`, `DEPLOY_URL_HML`) não existem ainda. Sem eles o
  passo avisa e segue — a verificação só começa a valer quando forem criados.
- **O `verificar.sh` segue não executado**, agora com três ondas de superfície nova acumulada.

#### Placar da onda 3

| Item | Resultado |
| --- | --- |
| 3.1 (R-A10, R-B3) | ✅ vermelho provado → verde · `deploy` com `permissions: {}` |
| 3.2 (R-M6) | ✅ vermelho provado → verde · 6 SHAs conferidos contra a API do GitHub |
| 3.3 (R-M7) | ✅ **3 advisories reais achados e corrigidos no primeiro run** |
| 3.4 (R-M4, R-M8) | ✅ job de build + 5 digests multi-arch · ✅ publicação em registry **decidida e feita em 2026-08-05** ([doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md)) |
| 3.5 (R-M5) | ✅ vermelho provado → verde · ⏳ inerte até os secrets existirem |
| 3.6 (R-A3, R-M20) | ✅ vermelho provado → verde · 12 testes novos |
| 3.7 (R-M22) | ✅ **mutação provada nos dois sentidos** · limite semântico declarado |
| 3.8 (R-M23) | ✅ **mutação provada** · 1 → 9 testes |
| 3.9 (R-B2) | ✅ por inspeção (o próprio plano o marcava como inverificável de forma útil) |

### 4.4 Onda 4 — 2026-08-04

Os cinco itens entraram. **Com uma ressalva declarada antes de começar:** o §3 diz que esta onda
depende do **1.1 estar provado**, e ele não está — o contato do Grafana foi provisionado mas nada
foi implantado, e a §17 do `verificar.sh` nunca rodou. Executada assim, a onda 4 é trabalho
**escrito e não medido**: os alertas novos estão certos no arquivo e ninguém viu nenhum deles
disparar. Foi decisão do operador seguir mesmo assim, e fica registrado como tal.

**O que a onda mediu de fato** foi outra coisa, e valeu: os nomes de métrica. Cada um foi
verificado subindo a imagem e lendo `/metrics` — e três descobertas só apareceram assim.

#### Estado dos gates

| Gate | Depois (medido em 2026-08-04) |
| --- | --- |
| `mix format --check-formatted` | **ok** |
| `mix compile --force --warnings-as-errors` | **ok** |
| `mix test` | **2.044 · 1 falha** (+22 nesta onda; a falha é a mesma guarda de 1.2) |
| `mix test --only rls` | **0 falhas** |
| `mix coveralls` (piso 80) | **90,5%** |
| `npm run check` / `npm run coverage` | **0/0** · **214 arquivos · 93,13%** (o web não mudou nesta onda) |
| YAML de `grafana-alertas.yml` | **parseia** — 17 regras em 3 grupos (eram 9 em 2) |
| YAML de `prometheus.yml` | **parseia** — 8 jobs (eram 4) |
| `alloy fmt` | **exit 0** |
| `bash -n verificar.sh` | **ok** — 18 seções, numeração 1..18 sem buraco |
| `verificar.sh` executado | **não** (mesma razão das ondas 1–3) |

#### O que entrou

**4.2 — R-M14, e a medição que ele exigiu.** Quatro jobs novos no Prometheus (`loki`, `alloy`,
`tempo`, `grafana`), cada um com lista de manter própria. Antes disto o runbook do alerta
*"pipeline de log parado"* mandava o operador comparar três contadores às 3h da manhã, e **nenhum
dos três era raspado** — quem seguisse o runbook receberia "No data" três vezes e concluiria,
razoavelmente, que a coleta de métrica também tinha caído.

Os nomes foram verificados subindo cada imagem e lendo `/metrics`, não copiados de documentação.
Três coisas que só aparecem assim:

- **As métricas de componente do Alloy são registradas com preguiça.** Com config vazia — e mesmo
  com um `loki.write` configurado que nunca entregou nada — a família `loki_write_*` **não
  existe**. Foi preciso fazer log de verdade circular, com destino inalcançável, para confirmar que
  `loki_write_dropped_entries_total` existe (existe). Sem essa etapa eu teria concluído o oposto.
- **`loki_distributor_lines_received_total` idem no Loki:** só materializa depois do primeiro push.
- **O Tempo não subiu** com config improvisada nas tentativas feitas aqui, então os nomes dele
  (`tempo_distributor_*`, `tempo_ingester_*`, `tempo_request_*`) vêm da convenção da família e
  **não foram verificados**. Está escrito no `prometheus.yml`, e é justamente o caso que a §18 do
  `verificar.sh` pega no servidor.

Junto veio o **alerta de descarte de log**, que fecha uma lacuna do `cinetra-pipeline-parado`:
aquele dispara quando o total ZERA por 10 min; descarte **parcial** — o agente entregando 60% e
jogando 40% fora — não zera nada, e o que se perde primeiro é a linha da rajada, que é a do
incidente.

**O gate genérico, que vale mais que o item.** `Api.AlertasMetricasTest` extrai toda métrica citada
em `grafana-alertas.yml` (no `expr:` **e** nas anotações do runbook) e cobra que ela esteja numa
lista de manter de algum job. Mutação provada: removi o job `alloy` e o teste apontou
`loki_source_docker_target_entries_total` com a mensagem certa — ou seja, **ele teria pego o R-M14
original**. É o análogo, para alertas, do que o `verificar-paineis.py` já fazia para dashboards.

O detalhe que o faz funcionar: as regexes de `keep` são compiladas **ancoradas nas duas pontas**,
como o Prometheus as aplica. Sem isso o teste afirmaria mais do que o Prometheus faz.

**4.1 — R-M13, o alerta que mais importa deixa de mentir.** Duas correções numa expressão:

- **`by (mountpoint)`.** Sem ele o `max()` colapsava tudo numa série sem rótulo: o alerta dizia
  "disco em 91%" e não dizia onde. E pior que inconveniente — com o volume limitado do Loki (que
  **deve** encher) ao lado da raiz, a partição pequena e cheia **mascarava** a raiz de verdade: o
  `max` já estava em 100% por causa do loop, e uma raiz subindo de 70% para 95% não mudava o número.
- **Excluir `/var/lib/cinetra/*`.** Encher é o mecanismo de contenção funcionando. Alertar
  **crítico** com o texto "o Postgres recusa escrita e o backup falha" com o banco intacto é o
  caminho mais rápido para a equipe aprender a ignorar o alerta que mais importa.

Os volumes contidos ganharam regra própria, `aviso` e limiar de 95% por 30 min: cheio por meia hora
significa que a retenção não cabe no tamanho escolhido, e aí o Loki começa a recusar ingestão —
informação útil, urgência diferente.

**4.3 — R-M15, seis alertas para o que já era pago.** Cinco métricas estavam no
`metric_relabel_configs`, com série de 30 dias, e **nenhuma regra as consultava**. Coletar sem ler é
o meio-termo mais caro: tem o custo e não tem a detecção.

| Regra nova | Fecha o buraco de |
| --- | --- |
| `cinetra-fila-do-oban-parada` | `cinetra-job-falhando` conta `job:exception` — só vê job que ESTOURA. Job travado sem erro (worker sem slot, órfão em `executing` do R-A1) não gera exceção: a fila cresce calada, o lembrete não sai, e o primeiro sinal é o paciente faltar |
| `cinetra-container-morto-por-oom` | com os `mem_limit` da onda 2, OOM passou a significar "este serviço estourou o PRÓPRIO teto" — informação acionável, que antes não existia |
| `cinetra-oom-na-maquina` | o irmão do host: pega o que morreu FORA de container, e o build do release é o candidato natural (D-21) |
| `cinetra-container-unhealthy` | **só faz sentido depois da onda 2**: antes dela `container_health_state` era coletado e sempre vazio, porque não havia healthcheck para reportar estado. Coletar métrica de um mecanismo inexistente é a forma mais discreta de parecer coberto |
| `cinetra-disco-somente-leitura` | `errors=remount-ro` é o default deste sistema de arquivos; é o único alerta da lista em que a ação certa é restaurar noutra máquina |
| `cinetra-alerta-invalido` | o motor vigiando a si mesmo: regra provisionada que o Grafana **recusou** simplesmente não existe, e nada diz isso — exatamente o estado que este arquivo inteiro combate |

**O que NÃO entrou do 4.3: o check de expiração de certificado.** Ele exigiria um `blackbox_exporter`
(container novo) ou raspar o Traefik, que é do Dokploy e não está na topologia de scrape. Nenhum dos
dois é uma linha de configuração, e escolher por conta seria decidir arquitetura de observabilidade
sem mandato. Fica **aberto**, e é o único item da onda 4 que não fechou.

**4.4 — R-C2 residual, `url.full`.** Acrescentado à poda de trace do Alloy — e ele era o **pior dos
quatro**: `url.full` é a URL inteira, ou seja `url.path` **e** `url.query` juntos. Podar os dois e
deixar este é a redação que parece ter funcionado, a mesma classe do regex de telefone. Quem o
escreve é o `@opentelemetry/instrumentation-undici` do BFF, em toda chamada de saída — e a rota
`patients/lookup` leva `?cpf=&tel=&email=&nome=`.

**4.5 — R-B7, a numeração do `verificar.sh`.** Havia duas seções "13" e a ordem estava embaralhada
(11 → 13 → 12 → 13). Renumerado para 1..18 em ordem de execução, com guarda no
`Api.AlertasMetricasTest`. Importa porque runbook cita por **número**: `grafana-alertas.yml` manda
"rode a seção 9" e `criar-volume-limitado.sh` manda "seção 10". Verificado antes de renumerar que
todas as referências existentes apontam para seções ≤ 11 — nenhuma quebrou.

Junto entrou a **§18**, a outra metade do gate: consultar o Prometheus de pé e conferir que cada
métrica citada **responde**. Ela não reprova automaticamente, e a razão está escrita: métrica de
registro preguiçoso (`loki_write_dropped_entries_total`) não ter série é o estado **desejado** —
significa que nada foi descartado. O aviso descreve as duas leituras em vez de escolher uma.

#### O que NÃO entrou

- **O check de expiração de certificado** (parte do 4.3) — ver acima.
- **Nada foi implantado, e nenhum alerta novo foi visto disparar.** Os limiares (50 jobs na fila,
  95% no volume contido, 30 min) são escolhas de primeira ordem, não medições — e o jeito de
  calibrá-los é vê-los em operação.
- **Os nomes de métrica do Tempo** não foram verificados ao vivo.
- **O `verificar.sh` segue não executado**, agora com quatro ondas de superfície acumulada
  (§15, §16, §18, healthchecks, tetos). É de longe a maior dívida de verificação do plano.

#### Placar da onda 4

| Item | Resultado |
| --- | --- |
| 4.1 (R-M13) | ✅ `by (mountpoint)` + volumes contidos em regra própria · ⏳ não visto disparar |
| 4.2 (R-M14) | ✅ 4 jobs + alerta de descarte · **gate genérico com mutação provada** · ⚠️ nomes do Tempo não verificados |
| 4.3 (R-M15) | ✅ 6 regras sobre métrica já paga · ❌ **certificado ficou aberto** (precisa de blackbox exporter — decisão) |
| 4.4 (R-C2 residual) | ✅ `url.full` podado · `alloy fmt` exit 0 |
| 4.5 (R-B7) | ✅ 1..18 sem buraco, com guarda · referências existentes conferidas |

### 4.5 Onda 5 — 2026-08-04

Os **oito itens de obra** entraram. Os dois de **decisão** (5.2 e 5.3) foram levados ao operador
com as opções e o custo de cada uma, que é o que o §3 previa para eles — "não, e aqui está o
porquê" fecha um item de decisão tão bem quanto executá-lo.

**Um achado da onda: o R-B1 já estava fechado.** A deriva "`router.ex` diz 400/min, o código diz
2.000" não existe mais — o texto foi corrigido quando o estágio de borda migrou para o `Endpoint`
(doc 96, L-2). Em vez de marcar como feito e seguir, entrou a **guarda**: fechar não impede voltar,
e o número vive em dois lugares do mesmo arquivo sem nada os ligando.

#### Estado dos gates

| Gate | Depois (medido em 2026-08-04) |
| --- | --- |
| `mix format --check-formatted` | **ok** |
| `mix compile --force --warnings-as-errors` | **ok** |
| `mix test` | **2.048 · 1 falha** (+4; a falha é a mesma guarda de 1.2) |
| `mix test --only rls` | **0 falhas** |
| `mix coveralls` (piso 80) | **90,5%** |
| `npm run check` | **0 erros, 0 warnings** |
| `npm run coverage` | **214 arquivos · 93,16% stmt · 79,81% branch** (+13 testes de web) |
| YAML do `compose.obs.yml` | **parseia** — 8 serviços (era 7) |
| `alloy fmt` | **exit 0** |
| `verificar.sh` executado | **não** (mesma razão das ondas 1–4) |

#### O que entrou

**5.1 — R-A9, o socket do Docker deixa de ser root-equivalente.** O comentário do próprio arquivo
afirmava que `:ro` no `docker.sock` reduzia privilégio. **Não reduz**: o `:ro` é do *bind mount* —
impede apagar o arquivo — e não impede `connect()` seguido de `POST /containers/create`, que cria
um container privilegiado com `/` do host dentro.

Entrou o serviço `docker-proxy` (allowlist de endpoints), e **`POST: 0` é a linha que fecha o
buraco**: sem POST não existe `create`, `start` nem `exec`, e o caminho "RCE no agente → root na
máquina" acaba. Os dois clientes passaram a falar TCP com ele:

- **Alloy** — o bind saiu; `alloy.alloy` lê `DOCKER_HOST_OBS` em vez do literal, para que o
  rollback seja uma linha no `.env.local` e não uma edição de config no meio de um incidente;
- **cAdvisor** — e aqui estava a **metade não registrada** do achado: ele montava `/var/run`, que
  **contém** o `docker.sock`. Eram dois containers root-equivalentes, não um — o que também derruba
  o raciocínio de `compose.obs.yml` que dispensava `privileged` nele comparando-o com "o socket que
  o alloy já monta, e aquele ao menos é `:ro`". As duas pontas eram equivalentes.

O `docker-proxy` nasceu cumprindo as regras da onda 2 (`mem_limit`, `cpus`, `logging`,
`healthcheck`) e foi acrescentado ao `@obs_servicos` do `Api.DeployContencaoTest` — que passou a
cobrá-las dele.

**Não verificado com o stack de pé.** Se algo estiver errado, o sintoma é visível e reversível: o
Alloy para de descobrir containers (o log some e o dead man's switch acusa em 10 min) ou o cAdvisor
perde os rótulos de nome (os painéis por container esvaziam). O rollback é `DOCKER_HOST_OBS` +
remontar o bind.

**5.4 — R-M19, e o comentário que mentia.** `getClientAddress()` do adapter-node **levanta** quando
o header configurado falta, e isso vale para **qualquer** header — não só os de vendor. O comentário
do `compose.dokploy.yml` afirmava que o `x-forwarded-for` do default *"não tem esse risco"*; tinha.
Quem chegasse sem passar pelo Traefik — outro serviço na rede `app`, um `curl` de dentro da
`dokploy-network` — virava **500 em toda página que fale com a API**. O `?.` que existia protegia
contra a função ser `undefined`, não contra ela levantar.

Entrou `ipDoCliente()` em `lib/server/api.ts`, usado pelos dois chamadores, e o comentário do
compose foi corrigido com a razão escrita: **comentário que mente sobre segurança é pior que
comentário ausente**, porque alguém decide com base nele — e este quase decidiu.

**5.7 — R-B9, a chave vazia.** Com o XFF presente e vazio o adapter devolve `''`, e `''` como chave
de rate limit joga **todo mundo no mesmo balde** de 20/min: o teto por-IP vira teto global sem
ninguém perceber. `ipDoCliente()` normaliza vazio para ausente, e quem chega sem IP identificável
cai num balde `sem-ip` **nomeado e separado** — divide teto entre si, não com os usuários reais.

**5.5 — R-B5, superfície.** `Permissions-Policy` com lista vazia (`=()`, que significa "ninguém,
nem eu mesmo") para câmera, microfone, geolocalização, pagamento, USB, MIDI e magnetômetro; mais
COOP e CORP `same-origin`.

Duas decisões registradas junto: **COOP é seguro aqui** porque o login com Google é navegação
completa e não popup (com popup, `same-origin` quebraria o fluxo); e **COEP fica de fora de
propósito** — ele exigiria CORP declarado em todo recurso cross-origin, e o avatar servido por URL
assinada do R2 não declara. Ligar COEP trocaria a foto de perfil por um isolamento que este produto
não usa. Há teste que prende a ausência, para que ela continue sendo decisão e não esquecimento.

**5.6 — R-B6, a violação de CSP passa a ter destino.** `report-uri` + `report-to` na CSP,
`Reporting-Endpoints` no `hooks.server.ts` (sem ele o `report-to` é inerte, e inerte em silêncio) e
— o que o plano não previa — o **endpoint teve de aprender o formato**. `report-uri` posta
`{"csp-report": {...}}` em kebab-case; a Reporting API posta um array com `body` em camelCase. Sem
normalizar, o relatório entraria com todos os campos vazios e viraria linha de log inútil: pior que
não ter relatório, porque parece que tem.

O ganho concreto é o que o doc 95 nomeia: se um build sair sem `R2_ACCOUNT_ID`, o bucket fica fora
do `connect-src`, **todo upload de anexo morre** e o motivo existe só no console do browser da
recepcionista. Agora vira linha com `blocked-uri` e `violated-directive` — e a URL do documento
passa pela mesma sanitização de PII do resto do endpoint, porque ela carrega id de paciente.

**5.8 — R-B1, já fechado, agora com guarda.** Verificado: não há mais "400/min" em `api/lib`, e o
`@moduledoc` diz 2.000 contra `@edge_limit 2_000`. A guarda lê a **fonte** do plug e compara os dois
números (o atributo não é persistido em `__info__`, e persisti-lo só para o teste seria mudar
produção para acomodar a guarda). Mutação provada: repus "400/min" no moduledoc → vermelho com os
dois números na mensagem.

**5.9 — R-B4, a credencial default.** `admin:cinetra-local` saiu do `verificar.sh` rastreado. Não
valia em produção — o compose exige `GRAFANA_ADMIN_PASSWORD` com `:?` e prende o Grafana em
`127.0.0.1` —, mas publicava o padrão `admin:cinetra-<algo>` e convidava ao reuso. O default agora
é só o usuário, e o script **avisa** quando a senha falta, em vez de tentar adivinhar e reportar
"ausente" para coisa que está lá.

**5.10 — R-B10 residual.** `docs/17-deploy-fly.md` e `docs/05 §5` ganharam aviso de documento
histórico no topo, apontando para a ADR-023, o doc 59 e o doc 87. O custo que isso evita é
específico: durante um incidente, alguém abre o doc errado e segue um runbook de um provedor que
saiu.

#### O que NÃO entrou

- **A obra do 5.2**: o operador **aceitou** a exposição, e o item fecha como decisão registrada
  (§4.5.1 abaixo). Nenhuma linha de código.
- **Nada foi verificado com o stack de pé.** O 5.1 é o item com mais risco de execução de todas as
  cinco ondas: ele muda o caminho pelo qual dois containers descobrem os outros.
- **O `verificar.sh` segue não executado.** Cinco ondas de superfície acumulada.


#### 4.5.1 As duas decisões, e o que elas viraram

O §3 previa que 5.2 e 5.3 fossem **respondidas**, não executadas. Foram — e uma delas virou obra.

**5.2 · R-M21 — `/metrics`, Prometheus e Grafana na `dokploy-network`: ACEITO.**

A decisão é aceitar a exposição lateral. O que **não** se aceita é o argumento que estava escrito
em `api/lib/api/prom_ex.ex` — *"quem já está dentro tem o Postgres ao lado, alvo melhor"* — porque
ele é **factualmente falso**: o Postgres só existe na rede `data`, então o atacante lateral **não**
o alcança, mas alcança os dois `/metrics`. O que ele ganha é reconhecimento: rotas, filas do Oban,
taxa de erro de produção, de graça.

O que sustenta o aceite é outra coisa: hoje o único vizinho conhecido na máquina é um projeto do
próprio operador (`educatizzy`), e as duas alternativas custam mais do que fecham. A rede dedicada
de scrape exigiria acertar **três** redes por stack — o Grafana precisa da rede do banco para o
datasource, o Alloy precisa da rede `app` para o OTLP —, e errar ali produz painel vazio em vez de
erro. Autenticar o `/metrics` troca um risco de leitura por um risco de **coleta parada em
silêncio** quando o token divergir.

**A revisão desta decisão tem gatilho**, e ele é o que importa registrar: no dia em que a máquina
hospedar um stack de terceiro — de outro cliente, de outra pessoa —, o aceite deixa de valer,
porque o "vizinho conhecido" some do argumento.

**5.3 · R-M17 — identidade individual no Grafana: a premissa do achado NÃO se aplica.**

O doc 95 descreve o R-M17 como *"três pessoas dividem uma senha"*, e é essa premissa que ele cobra.
Ela não vale nesta instalação: o Zero Trust libera o painel para **um único e-mail**. Com uma
pessoa, a atribuição já é inequívoca — toda consulta foi ela — e a revogação já é individual (tirar
o e-mail da política do Access), não troca coordenada de senha. **O mecanismo que o achado pedia
existe; só não é o Grafana que o provê.**

**Uma precisão que evita a conclusão errada:** nem com `auth.proxy` o Grafana auditaria *consulta*.
Ele registraria quem abriu a **sessão**, não qual query rodou no Explore. Ou seja, "quem consultou o
agregado de todas as clínicas" continua sendo respondido no nível de "quem entrou no painel e
quando" — que é exatamente o que o log do Access já entrega. O que o 5.3 compraria é um usuário do
Grafana por pessoa **no lugar de todo mundo entrar como `admin`**, e com uma pessoa isso é zero.

**O que entrou mesmo assim, e por que fica desligado.** `GF_AUTH_PROXY_*` está no
`compose.obs.yml`, lendo `Cf-Access-Authenticated-User-Email`, com `auto_sign_up` — e
`GRAFANA_AUTH_PROXY=false` por default. É **preparação documentada**, não obra em vigor: inerte
hoje, pronta para o dia do gatilho.

**As duas decisões se cruzam, e é isso que torna a configuração delicada quando for ligada.**
`auth.proxy` faz o Grafana confiar num HEADER; e o 5.2 registrou que o Grafana é alcançável na rede
compartilhada. Sem allowlist de origem, qualquer container da máquina manda
`Cf-Access-Authenticated-User-Email: quem-eu-quiser` e entra como essa pessoa — ligar o 5.3 sem
cuidado transformaria o risco aceito no 5.2 de *reconhecimento* em **admin lateral**. Daí o default
`GF_AUTH_PROXY_WHITELIST=127.0.0.1`: quem ligar sem configurar a origem faz o Access deixar de ser
aceito e cai no formulário de login. Falha para o lado chato, não para o aberto.

**E, no dia de ligar, considere `auth.jwt` em vez de `auth.proxy`.** A proteção do `auth.proxy` é
**posicional** (uma allowlist de IP, que ainda por cima é o IP do Traefik e muda a cada recreate);
a do `auth.jwt` é **criptográfica** — o Grafana valida o `Cf-Access-Jwt-Assertion` contra o JWKS do
tenant e contra o `aud` do app, e a posição de rede deixa de importar. Numa rede compartilhada, a
segunda é estritamente melhor. Não entrou agora porque ligar qualquer uma das duas é prematuro.

**Gatilho de revisão: a segunda pessoa com acesso ao painel.** É nesse dia que o item volta a valer
— e é nesse dia que a escolha entre `auth.proxy` e `auth.jwt` precisa ser feita.

**O que continua de pé, e é independente disto:** a senha do Grafana segue sendo o segundo cadeado
para quem chegue ao painel **sem** passar pelo Access — pelo IP do origin, ou lateralmente pela
`dokploy-network`. E fechar o origin (Cloudflare Tunnel, ou firewall aceitando só as faixas da
Cloudflare) é o que impede contornar o Access de uma vez, para o painel, para o Dokploy e para o
webhook. **Isso não é item de nenhuma das cinco ondas** — não apareceu no doc 95 —, mas é o que
sustenta o aceite do 5.2 e a decisão deste item.

#### Placar da onda 5

| Item | Resultado |
| --- | --- |
| 5.1 (R-A9) | ✅ proxy com `POST: 0` · **a metade do cAdvisor não estava registrada no achado** · ⚠️ não verificado de pé |
| 5.2 (R-M21) | ✅ **decisão: aceitar, registrada com o argumento certo** — ver §4.5.1 |
| 5.3 (R-M17) | ✅ **decisão: a premissa do achado não se aplica** (Access libera um e-mail só) · preparação entrou desligada, gatilho = a 2ª pessoa — ver §4.5.1 |
| 5.4 (R-M19) | ✅ vermelho provado → verde · comentário do compose corrigido |
| 5.5 (R-B5) | ✅ vermelho provado → verde · ausência de COEP prendida por teste |
| 5.6 (R-B6) | ✅ vermelho provado → verde · os **dois** formatos de relatório, com PII sanitizada |
| 5.7 (R-B9) | ✅ vermelho provado → verde · balde `sem-ip` nomeado |
| 5.8 (R-B1) | ✅ **já estava fechado**; entrou a guarda, com mutação provada |
| 5.9 (R-B4) | ✅ default removido, com aviso no lugar |
| 5.10 (R-B10 residual) | ✅ dois documentos marcados como históricos |

---

## 5. Placar de rastreabilidade

### 5.1 Os 46 riscos

Um leitor tem de conseguir conferir que nada sumiu. **46 riscos, 45 em onda, 1 fora.**

| Risco | Severidade (doc 95) | Onda | Item | Nota |
| --- | --- | --- | --- | --- |
| **R-C1** alertas sem contact point | crítico | **1** | 1.1 | Urgência **subiu**: agora há o que detectar |
| **R-C2** PII em trace | crítico | **4** | 4.4 | **Reavaliado.** Poda entrou (doc 96 S-3) + exportador inerte. Sobra `url.full` |
| **R-C3** chave `age` no working tree | crítico | **1** | 1.2 | Reconferido hoje: ainda lá |
| **R-A1** job do Oban órfão | alto | **1** | 1.3 | Urgência **subiu**: deploys reais, cron rodando |
| **R-A2** sem `Cache-Control` | alto | **1** | 1.4 | Urgência **subiu**: há usuário |
| **R-A3** `ORIGIN` sem guarda de boot | alto | **3** | 3.6 | Exige ação humana (edição no painel) → desempate |
| **R-A4** sem `mem_limit` | alto | **2** | 2.1 | Folga maior que a temida; mecanismo intacto |
| **R-A5** teto de disco do Loki opt-in | alto | **2** | 2.4 | `LOKI_DATA` ainda fora do template |
| **R-A6** obs sem rotação de log | alto | **2** | 2.5 | 0 `logging:` em `compose.obs.yml` |
| **R-A7** sem `HEALTHCHECK` | alto | **2** | 2.2 | Agrupado com R-B8 |
| **R-A8** log do Postgres com nome de paciente | alto | **1** + **5** | 1.5 (contenção) + 5.1 (allowlist) | **Dividido**: o drop no Alloy é S; a allowlist completa é M |
| **R-A9** `docker.sock` root-equivalente | alto | **5** | 5.1 | Sem gatilho conhecido; alcance grande |
| **R-A10** CI sem `permissions:` | alto | **3** | 3.1 | Primeiro item da onda 3 |
| **R-M1** `stop_grace_period` do web | médio | **1** | 1.3 | **Carona** no R-A1: mesma edição de YAML |
| **R-M2** sem `shm_size` | médio | **2** | 2.3 | |
| **R-M3** sem `KEEP_ALIVE_TIMEOUT` | médio | **1** | 1.6 | **Subiu de faixa**: 502 com usuário real, sem log |
| **R-M4** CI não builda a imagem | médio | **3** | 3.4 | **Duplo agora**: build compete com produção (D-21) |
| **R-M5** deploy fire-and-forget | médio | **3** | 3.5 | Falha calada, mas exige deploy → desempate |
| **R-M6** actions por tag | médio | **3** | 3.2 | |
| **R-M7** sem varredura de dependência | médio | **3** | 3.3 | |
| **R-M8** sem digest pinning | médio | **3** | 3.4 | Agrupado com R-M4 |
| **R-M9** rate limiter em ETS | médio | **fora** | — | **Fechado por decisão medida** (doc 101 §4.3) |
| **R-M10** dump não verificado | médio | **1** | 1.7 | Ocorre no cron de 1 h, sozinho |
| **R-M11** dump no disco do `pgdata` | médio | **2** | 2.7 | **Subiu de faixa**: `pgdata` agora tem dado |
| **R-M12** sem limite de CPU | médio | **2** | 2.9 | Ganhou [D-21](50-debitos-tecnicos.md) |
| **R-M13** alerta de disco falso | médio | **4** | 4.1 | |
| **R-M14** Prometheus não raspa a obs | médio | **4** | 4.2 | O gate genérico mais valioso |
| **R-M15** buracos de alerta | médio | **4** | 4.3 | |
| **R-M16** Grafana `depends_on` Loki | médio | **2** | 2.8 | |
| **R-M17** admin único no Grafana | médio | **5** | 5.3 | **Decisão, não obra** |
| **R-M18** `.env.exemplo` rebaixa teto | médio | **2** | 2.6 | O gate pega a classe |
| **R-M19** `getClientAddress()` levanta | médio | **5** | 5.4 | Metade é D-16, operação |
| **R-M20** guarda de boot prova concordância | médio | **3** | 3.6 | Agrupado com R-A3 |
| **R-M21** `/metrics` na rede compartilhada | médio | **5** | 5.2 | **Decisão, não obra** |
| **R-M22** expand-contract sem gate | médio | **3** | 3.7 | **Mais caro agora**: janela com usuário |
| **R-M23** `Api.Release` com um teste | médio | **3** | 3.8 | |
| **R-B1** deriva 400 vs 2.000 | baixo | **5** | 5.8 | |
| **R-B2** `.dockerignore` do web | baixo | **3** | 3.9 | Inverificável de forma útil |
| **R-B3** sem `timeout-minutes` | baixo | **3** | 3.1 | Carona no R-A10 |
| **R-B4** credencial default no `verificar.sh` | baixo | **5** | 5.9 | |
| **R-B5** headers faltando | baixo | **5** | 5.5 | |
| **R-B6** CSP sem `report-uri` | baixo | **5** | 5.6 | |
| **R-B7** duas seções "13" | baixo | **4** | 4.5 | Runbook cita por número |
| **R-B8** healthchecks na obs | baixo | **2** | 2.2 | Carona no R-A7 |
| **R-B9** chave vazia no limiter do BFF | baixo | **5** | 5.7 | |
| **R-B10** documentação obsoleta | baixo | **5** | 5.10 | **Majoritariamente fechado** (ADR-023, ADR-027, `docs/04`) |

**Conferência:** onda 1 = 8 riscos · onda 2 = 10 · onda 3 = 12 · onda 4 = 5 · onda 5 = 10 · fora = 1.
**Total 46.** (R-A8 conta uma vez, na onda 1, com a segunda metade anotada na onda 5.)

### 5.2 As 30 ações do doc 95 §2

| Ação (doc 95) | Faixa original | Onde caiu | Mudou? |
| --- | --- | --- | --- |
| 1 · tirar chave `age` + `*.key` | 0 | **1.2** | — |
| 2 · contact point + provar entrega | 0 | **1.1** | — |
| 3 · poda de trace + parar PII na query | 0 | **4.4** (residual) + **5.2**† | **Sim** — a poda foi feita (doc 96 S-3); sobra `url.full` |
| 4 · `mem_limit` + teste | 0 | **2.1** | Esforço cai (o leitor de compose já existe) |
| 5 · `LOKI_DATA` + `CADVISOR_MEM_LIMIT` | 0 | **2.4** + **2.6** | **Dividido** em dois itens com gates diferentes |
| 6 · `stop_grace_period` + `Lifeline` | 0 | **1.3** | Urgência **subiu** |
| 7 · `Cache-Control` | 0 | **1.4** | Urgência **subiu** |
| 8 · guarda de boot `ORIGIN`/`API_URL` | 0 | **3.6** | Desceu para a onda 3 (exige ação humana) |
| 9 · `permissions:` no CI | 0 | **3.1** | — |
| 10 · `x-logging` na obs | 0 | **2.5** | — |
| 11 · ensaiar restore + declarar RTO/RPO | 0 | **1.8** + **fora de onda** | **Sim** — "antes de existir paciente" morreu; e a declaração é decisão recorrente |
| 12 · rotacionar segredos | 0 | **1.9** | **Sim** — agora exige janela (derruba sessões) |
| 13 · `HEALTHCHECK` | 1 | **2.2** | Agrupado com R-B8 |
| 14 · socket proxy do Docker | 1 | **5.1** | Desceu: sem gatilho conhecido |
| 15 · verificação pós-deploy | 1 | **3.5** | — |
| 16 · build da imagem no CI | 1 | **3.4** | Ganhou um segundo motivo (D-21) |
| 17 · SHA + dependabot + audit | 1 | **3.2** + **3.3** | **Dividido** |
| 18 · `shm_size` + `KEEP_ALIVE_TIMEOUT` | 1 | **2.3** + **1.6** | **Dividido** — o `KEEP_ALIVE` sobe para a onda 1 |
| 19 · `pg_restore --list` + volume do dump | 1 | **1.7** + **2.7** | **Dividido** — a verificação sobe para a onda 1 |
| 20 · alerta de disco `by (mountpoint)` | 1 | **4.1** | — |
| 21 · raspar a obs + alerta de descarte | 1 | **4.2** | — |
| 22 · alertas do que já é coletado | 1 | **4.3** | — |
| 23 · tirar `depends_on: loki` do Grafana | 1 | **2.8** | Subiu: é contenção pós-reboot |
| 24 · allowlist de log do `db` | 2 | **1.5** + **5.1** | **Sim, dividido** — a contenção sobe para a onda 1 |
| 25 · SSO no Grafana | 2 | **5.3** | Marcado como **decisão, não obra** |
| 26 · limites de CPU | 2 | **2.9** | Subiu: ganhou D-21 |
| 27 · gate de expand-contract | 2 | **3.7** | Subiu: janela com usuário |
| 28 · cobrir `Api.Release` | 2 | **3.8** | — |
| 29 · sair do rate limiter em ETS | 2 | **fora de onda** | **Sim — recomendação revogada.** Medido e recusado (doc 101 §4.3), com armadilha virada teste |
| 30 · realinhar documentação | 2 | **5.10** | **Sim** — majoritariamente feito (ADR-023, ADR-027, `docs/04`) |

† A metade "parar de mandar PII na query string de `patients/lookup`" fica como defesa em
profundidade dentro de 5.2 (decisão sobre exposição), já que a poda no agente e o exportador inerte
removeram o vazamento agudo.

---

## 6. Uma nota sobre o método

O [doc 101 §4.3](101-plano-de-acao-analise-arquitetural.md:397-401) registrou que **6 dos 26 achados
daquela análise não sobreviveram à verificação**, e concluiu que "medir antes de consertar" é regra,
não zelo. Esta releitura já pagou parte dessa taxa antes de a execução começar: dos 46 riscos do doc
95, **três mudaram de estado em cinco dias** (R-C2 parcialmente fechado, R-M9 fechado por decisão
medida, R-B10 majoritariamente fechado) — e um deles, o R-M9, teve a recomendação **revogada por
medição**, não por opinião.

A consequência prática para quem executar estas ondas: **reconfira antes de consertar.** As
evidências `arquivo:linha` do doc 95 foram reconferidas em 2026-08-04 e estão listadas no §1.3, mas
elas envelhecem — e num repositório com esta velocidade, envelhecem em dias.
