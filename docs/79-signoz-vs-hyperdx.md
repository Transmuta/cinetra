# 74 — SigNoz vs HyperDX: comparativo e recurso necessário

> Comparativo, 2026-07-28. Continua o [doc 78](78-sentry-vale-a-pena.md), que descartou o Sentry e
> nomeou o GlitchTip como saída lateral. Aqui estão os dois candidatos a **plataforma unificada**
> — o "Datadog open source" de produto único.
>
> Números colhidos da documentação oficial de cada projeto na data acima; ver Fontes no fim.
> **Confirme antes de provisionar** — requisito de recurso muda por versão.

---

## 1. A resposta curta

| | SigNoz | HyperDX (ClickStack) |
|---|---|---|
| **RAM mínima (nó único)** | **4 GB** (8 GB recomendado) | **4 GB** (2 cores), para *teste* |
| Baseline ocioso | ~1,5–2 GB | não publicado |
| Modo dev/local | — | 1 GB / 1 core (efêmero) |
| Componentes | ClickHouse, core (query+UI), OTel Collector, PostgreSQL, ZooKeeper | ClickHouse, UI, OTel Collector, **MongoDB** |
| Licença | **MIT Expat**; `ee/` e `cmd/enterprise/` proprietários | **MIT** |
| Atrás do enterprise | SSO (SAML/OIDC), RBAC fino, Ingest Guard | — |
| Estrelas no GitHub | ~27.400 | ~9.600 |
| Dono | SigNoz (empresa própria) | **ClickHouse** (absorvido como ClickStack) |
| **Melhor UI/UX** | **APM e dashboards** | **session replay e primeiro uso** |

**Os dois cabem na VM** — diferente do Sentry self-hosted, que pede ~16 GB e foi descartado por
isso no doc 78. A questão aqui não é caber; é se compensa.

---

## 2. Recurso, no contexto da nossa máquina

O que a observabilidade custa hoje, medido no [doc 62 §3.2](62-plano-de-logs.md):

| | Teto | Uso real |
|---|---|---|
| Loki | 1,5 GB | ~200 MB |
| Grafana | 512 MB | ~340 MB |
| Alloy | 256 MB | ~210 MB |
| **Hoje** | **2,2 GB** | **~750 MB** |
| SigNoz (nó único) | — | **4–8 GB** |
| HyperDX (all-in-one) | — | **4 GB+** (mais MongoDB) |

Numa VM de 24 GB que ainda carrega Postgres, **dois ambientes** da aplicação e o pico do build do
release Elixir — o maior consumidor da caixa —, trocar 750 MB por 4–8 GB é multiplicar por 5–10 a
fatia da ferramenta. Cabe, mas deixa de ser os 3% que a §3.2 celebrou.

**Sobre o número de 56 cores / 160 GiB** que aparece na página de capacity planning do SigNoz: é a
recomendação de **cluster de produção** (3 réplicas de collector, ClickHouse em 2 shards, 3 nós de
ZooKeeper). Não é o mínimo de nó único, e citá-lo fora de contexto descartaria o SigNoz por engano
— foi o que quase aconteceu na primeira leitura desta pesquisa.

---

## 3. O que decide para NÓS, e não aparece em comparativo genérico

### 3.1 O diferencial do HyperDX é justamente o que não podemos usar

O que distingue o HyperDX é **session replay correlacionado** com log, trace e métrica: pular da
sessão quebrada de um usuário para o span que a causou. É genuinamente bom, e é o motivo pelo qual
ele existe.

E é exatamente o que o [doc 05 §1.2](05-observabilidade-e-producao.md) recusa, por dois motivos
independentes:

1. **Session replay grava a tela.** Numa clínica, essa tela tem nome de paciente, CPF, telefone e
   o texto livre da observação. É a categoria de dado que o projeto inteiro se organiza para não
   deixar sair — três camadas de redação, `sanitizarRota`, `sanitizarTexto`, o `RequestLogger`
   trocando `/api/patients/<uuid>` por `:id`.
2. **Exige SDK de terceiro na página**, que o ADR-007 proíbe e que o `hooks.client.ts` documenta
   como decisão consciente.

Ou seja: adotaríamos a ferramenta e desligaríamos a razão de ela ser escolhida. O que sobra é um
backend de log/trace competente — e aí ela compete sem o trunfo.

### 3.2 Dashboards são o nosso ativo, não os traces

São **11 dashboards, 97 painéis**, e a maioria não é APM: *Uso e clínicas*, *Mensagens ao paciente*,
*Agenda e fila*, *Auditoria e acesso*, *Atrito (4xx)*. São perguntas de **produto e operação** feitas
sobre log agregado.

Nisso o comparativo é claro: o dashboarding do SigNoz é mais flexível que o do HyperDX. Mas o do
**Grafana é mais flexível que os dois**, e já está construído — os 97 painéis são 5.471 linhas de
JSON em LogQL. Migrar significa reescrevê-los em SQL do ClickHouse (SigNoz) ou na busca do HyperDX.

### 3.3 A redação de PII teria de ser refeita

O [`alloy.alloy`](../deploy/observability/alloy.alloy) tem os `stage.replace` de CPF, e-mail e
telefone — cada um com um comentário explicando um erro medido e corrigido (o regex de CPF que
comia timestamp; o de telefone que redigia só o DDD). Esse conhecimento está codificado ali.

Nos dois candidatos o equivalente existe (processadores do OTel Collector — `transform`,
`attributes`), então é factível. Mas é reescrita de código de segurança, que é onde erro sai caro,
e os testes que o protegem hoje (`verificar.sh` §5) assumem o formato do Loki.

### 3.4 SSO e RBAC finos são pagos no SigNoz

`ee/` e `cmd/enterprise/` são proprietários; SAML/OIDC e RBAC granular ficam ali. Para um produto
de saúde com múltiplas clínicas, controlar quem vê o quê na ferramenta de observabilidade pode
deixar de ser conforto. O HyperDX é MIT inteiro.

---

## 4. Qual tem a melhor UI/UX

Depende do que se vai fazer, e vale separar em três perguntas.

**Primeiro uso e curva de aprendizado → HyperDX.** É consenso nos comparativos: sobe mais rápido,
a busca é imediata (estilo Kibana), e o all-in-one é um comando. Se o critério fosse "ter
observabilidade rodando esta semana", ele ganha.

**Investigar produção com APM → SigNoz.** É descrito como a UI de APM mais polida do espaço open
source: service map, RED por serviço, navegação estruturada entre trace → span → log. Mais perto
do que se espera ao dizer "Datadog".

**Construir e manter dashboards → SigNoz entre os dois, Grafana acima dos dois.** É o eixo que mais
importa para nós, pelo §3.2.

**Veredito, se fosse obrigatório escolher um: SigNoz.** Três razões: o dashboarding é o que usamos
de fato; a comunidade é ~3× maior (importa quando se trava às 23h); e o diferencial do HyperDX é
inutilizável aqui. A ressalva honesta é o SSO/RBAC pago — e o fato de que "melhor UI" é, em parte,
gosto, e ninguém deveria decidir isso sem rodar os dois por uma tarde.

---

## 5. Recomendação

> **Como terminou (2026-07-29):** o caminho incremental foi seguido até o fim. As métricas subiram
> com Prometheus + node_exporter + cAdvisor + PromEx, e os traces com **Grafana Tempo** recebendo
> pelo Alloy ([doc 76](76-traces.md)) — os três sinais no mesmo Grafana, com os 97 painéis e o
> pipeline de redação intactos, e a fatia de memória da ferramenta ainda abaixo do que qualquer
> plataforma unificada pediria. A conclusão abaixo se sustentou.

**Nenhum dos dois agora.**

O ganho real deles seria **métricas e traces numa UI só, sem montar Prometheus e Tempo**. Mas o
[doc 62](62-plano-de-logs.md) já reservou memória para o Prometheus na §3.2 e escreveu o plano da
fase de métricas na linha 792 (`node_exporter` + PromEx → Prometheus, **no mesmo Grafana**). O
caminho incremental existe, custa menos memória, preserva os 97 painéis e mantém o pipeline de
redação já validado.

O custo de trocar é concreto e imediato: reescrever 97 painéis, refazer a redação de PII,
multiplicar por 5–10 a memória da ferramenta. O ganho é obter, de outra forma, algo que já está
planejado e dimensionado.

**Quando reavaliar** — se qualquer um destes virar verdade:

- a fase de métricas se mostrar mais trabalhosa do que a migração (medir, não supor);
- passarmos de dois ou três serviços, quando trace deixa de ser luxo;
- alguém quiser APM de verdade (service map, RED automático), que o Grafana só entrega montando
  Tempo + Mimir.

Nesse dia, o candidato é o **SigNoz**, pelas razões do §4 — e o §3.3 (redação de PII) é o item que
precisa de plano antes de qualquer migração, não depois.

---

## Fontes

- [SigNoz — Resources Planning](https://signoz.io/docs/setup/capacity-planning/community/resources-planning/) (números de cluster)
- [SigNoz — Install on Docker Standalone](https://signoz.io/docs/install/docker/) (mínimo de nó único)
- [SigNoz — LICENSE](https://github.com/SigNoz/signoz/blob/main/LICENSE) e [ee/LICENSE](https://github.com/SigNoz/signoz/blob/develop/ee/LICENSE)
- [HyperDX — repositório](https://github.com/hyperdxio/hyperdx) (componentes, MIT, 4 GB/2 cores)
- [HyperDX — Local Mode](https://www.hyperdx.io/docs/v2/local) (1 GB/1 core)
- [ClickStack — Getting started OSS](https://clickhouse.com/docs/use-cases/observability/clickstack/getting-started/oss) (all-in-one)
- [OpenAlternative — HyperDX vs SigNoz](https://openalternative.co/compare/hyperdx/vs/signoz) (adoção, UI)
