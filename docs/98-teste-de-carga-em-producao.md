# 98 — Primeiro teste de carga em produção: a porta de entrada, os limitadores, e o Cloudflare que ninguém tinha registrado

**Data:** 2026-08-01 · **Alvo:** `https://cinetra.com.br` (produção, Hostinger KVM 2) ·
**Janela:** `from=1785552031000&to=1785553497000` (02:40:31Z → 03:04:57Z, 24 min)

Rodado com produção no ar e **sem nenhum cliente usando**, por decisão explícita. Instrumentos em
[`deploy/carga/`](../deploy/carga/). **Nenhuma linha foi escrita no banco**; o único efeito colateral
é ~25 linhas `log.error` com `origem: teste-carga` no Loki (§5).

Este é o primeiro número medido **sob carga** desta máquina. Até aqui o repositório só tinha o
"≈ 3,5 GB residentes sob carga real baixa ou nula" de
[87 §2.1](87-servidor-hostinger-riscos-e-cuidados.md), com a ressalva explícita de que *"o número
que ainda falta é consumo e p95 sob clínica trabalhando"* ([D-21](50-debitos-tecnicos.md)).

---

## 1. A curva de saturação da porta de entrada

`GET /ready` — o caminho completo: Cloudflare → Traefik → Node (BFF) → rede interna → API → pool do
banco ([`web/src/routes/ready/+server.ts`](../web/src/routes/ready/+server.ts)). Nenhum limitador no
caminho (o `/api/ready` da API está no scope `pipe_through :api` puro,
[`router.ex:85-89`](../api/lib/api_web/router.ex#L85-L89)) — de propósito: aqui se mede o teto, não a
política.

| Concorrência | Vazão | p50 | p95 | max | Erros |
|---|---|---|---|---|---|
| 20 | 64,2 req/s | 263 ms | 369 ms | 644 ms | **0** |
| 50 | 159,2 req/s | 283 ms | 339 ms | 476 ms | **0** |
| 100 | 235,8 req/s | 346 ms | 455 ms | 775 ms | **0** |
| 200 | 292,0 req/s | 599 ms | 663 ms | 1345 ms | **0** |

**3.650+ requisições, zero erro em qualquer nível.** Nem um 5xx, nem um timeout.

**O joelho está entre 50 e 100.** A leitura é a razão entre os saltos, não os valores absolutos:

- 20 → 50: concorrência 2,5×, vazão **2,5×** — linear, o servidor tem folga
- 50 → 100: concorrência 2×, vazão **1,48×** — começou a dobrar
- 100 → 200: concorrência 2×, vazão **1,24×**, e o p50 quase dobra (346 → 599 ms) — fila

O p50 subindo proporcional enquanto a vazão empaca é a assinatura de fila saturada. Por Little:
a 200 concorrentes, 292 req/s × 0,599 s ≈ 175 requisições em voo — ou seja, a concorrência
oferecida está quase toda **esperando**, não sendo servida.

### 1.1 O custo da API + banco é ~7 ms

Comparando com `/health`, que é o liveness do Node **sem I/O nenhum**
([`health/+server.ts`](../web/src/routes/health/+server.ts)):

| Alvo | p50 @ PAR=5 | p50 @ PAR=100 |
|---|---|---|
| `/health` (Node puro) | 274 ms | 331 ms |
| `/ready` (atravessa API + banco) | 281 ms | 356 ms |

**A diferença é 7 ms em repouso e 25 ms sob carga.** Todo o resto é rede e TLS. Confirmado por
medição direta: numa conexão reaproveitada (sem handshake por requisição) o round-trip cai para
**~99 ms**, contra os ~300 ms dos testes acima. Ou seja: **os 300 ms não são o servidor** — são
handshake TLS + spawn de processo do gerador.

> **O que este número NÃO é.** `/ready` é barato. Uma abertura de agenda são 3 SELECTs e ~9 ms de
> banco ([28](28-auditoria-bate-volta-ciclo-de-vida.md)) mais renderização. **Não se traduz "292
> req/s" em "N clínicas"** sem o perfil de carga — é a conta que continua em aberto.

---

## 2. Os limitadores: o que foi provado e o que não foi

### 2.1 Provado — o limitador do BFF em `/api/client-error`

20 por minuto por IP, janela deslizante em memória do processo
([`client-error/+server.ts:32-33`](../web/src/routes/api/client-error/+server.ts#L32-L33)):

```
 1..20 → 204        21..25 → 429        (recuperação após a janela → 204)
```

**Exatamente o especificado.** E não é burlável — estando barrado, cinco tentativas de forjar o IP
de origem continuaram todas em 429:

| Header forjado | Resultado |
|---|---|
| `X-Forwarded-For: 203.0.113.99` | 429 |
| `X-Forwarded-For: 203.0.113.99, 198.51.100.1` | 429 |
| `X-Real-IP: 203.0.113.99` | 429 |
| `Forwarded: for=203.0.113.99` | 429 |
| `CF-Connecting-IP: 203.0.113.99` | **403** ← foi o que denunciou o Cloudflare (§3) |

### 2.2 Não provado — os limitadores da API

Os que importam para capacidade (**2.000/min por IP** na borda, **200/min por ator**,
[`rate_limit_global.ex:44-47`](../api/lib/api_web/plugs/rate_limit_global.ex#L44-L47)) e o
anti-brute-force do magic link (**10/2min por IP**,
[`rate_limit_auth.ex:31-33`](../api/lib/api_web/plugs/rate_limit_auth.ex#L31-L33))
**não foram testados**, e não por falta de tentativa: eles são **inobserváveis de fora**.

Duas razões somadas:

1. **A API não é pública** — desenho BFF-only, o Traefik só encaminha `/socket` e `/webhooks`.
2. **O BFF engole o 429.** [`auth.ts:96-106`](../web/src/lib/server/auth.ts#L96-L106) chama
   `apiFetch` e **nunca lê o status**; `fetch` não levanta em 4xx e o retorno é fixo
   `{ sent: true }`. Um 429 da API sai como **200 "link enviado"** no `/entrar`.

Prová-los exige rodar de dentro do servidor, contra a API pela rede do stack — é o modo `interno`
do [`rate-limit.sh`](../deploy/carga/rate-limit.sh), 15 requisições, ainda **não executado**.

---

## 3. O achado: há um Cloudflare na frente, e ele não está em doc nenhum

```
server: cloudflare        cf-ray: a2419ce9bb51528a-GIG        cf-cache-status: DYNAMIC
```

[87 §1](87-servidor-hostinger-riscos-e-cuidados.md) descreve a borda como "firewall gerenciado no
hPanel + iptables", com "a camada 7 continua sendo nossa". [95](95-analise-infraestrutura.md) não
menciona CDN. E o moduledoc de [`ApiWeb.ClientIp`](../api/lib/api_web/client_ip.ex) diz, em
julho: *"Sob um proxy que não o conhece — **o Traefik do Dokploy, hoje**"*. **A topologia mudou e o
registro não acompanhou.** Só isso já pede correção nos três lugares.

### 3.1 A consequência séria: em qual IP os limitadores estão chaveados?

O `ADDRESS_HEADER`/`XFF_DEPTH` do BFF lê **a última posição** do `X-Forwarded-For`, e o comentário
do compose diz por quê: *"da DIREITA (`XFF_DEPTH=1`) e quem escreve a última posição é o Traefik"*
([`compose.dokploy.yml:267-271`](../compose.dokploy.yml#L267-L271)). E
`TRUSTED_CLIENT_IP_HEADER: ${CLIENT_IP_HEADER:-}` tem **default vazio**.

Esse raciocínio estava correto **quando o Traefik era a borda**. Com o Cloudflare na frente, quem o
Traefik enxerga conectando não é o cliente — **é o edge do Cloudflare**. Se for isso, a última
posição do XFF é um IP do Cloudflare, e a chave de rate limit passa a ser **o PoP, não a pessoa**.

O moduledoc do `ClientIp` previu exatamente este dia:

> *"Ao entrar numa edge nova, adicione o header dela aqui **junto** com a troca do proxy: é a mesma
> decisão, e separá-las é como o limite vira decorativo."*

### 3.2 A medição que desmontou o §3.1 — a chave **é** o cliente

O parágrafo acima fica como registro do raciocínio, mas **a conclusão dele caiu**. Três medições,
nesta ordem:

| Sonda | Resultado |
|---|---|
| 25 requisições **sequenciais** | 20× 204, depois 429 |
| 60 requisições **em paralelo**, 30 concorrentes | **20× 204**, 40× 429 |
| 5 tentativas de forjar o IP, já barrado | todas 429 |

**A do meio é a que decide.** Se a chave fosse o IP de saída do Cloudflare, 30 conexões simultâneas
se espalhariam por várias máquinas do PoP — cada IP de egresso com seu próprio balde de 20 — e
teriam passado 40, 60, algum múltiplo de 20. Passaram **exatamente 20**, o mesmo número do teste
sequencial. **Concorrência não comprou cota**, o que só acontece com uma chave única e estável.

E o mecanismo fecha com o código. O adapter-node resolve o endereço como
`addresses[addresses.length - xff_depth]` com `xff_depth = 1` — **o último elemento do XFF**. O
Cloudflare **acrescenta o IP real do cliente ao final** de qualquer XFF que chegue. Logo, o XFF
forjado `203.0.113.99` vira `203.0.113.99, 138.84.43.61` e o que é lido é o segundo. É por isso que
as cinco tentativas de burla falharam: **não há como escrever depois do Cloudflare.**

O `XFF_DEPTH=1` está certo — não porque "quem escreve a última posição é o Traefik", como diz o
comentário do compose, mas porque quem escreve é o Cloudflare. **O comentário está desatualizado; o
valor está correto.** Corrigir a prosa, não a configuração.

**A dúvida residual, dita com precisão.** Se o Traefik também acrescentasse o peer (o edge do
Cloudflare), o último elemento seria dele. O teste paralelo torna isso improvável, mas não
impossível: exigiria que o Cloudflare tivesse usado **um único** IP de egresso para as 60
requisições. O que fecha o assunto custa 2 minutos: **estourar o balde daqui e mandar uma
requisição do celular fora do wi-fi.** 204 = chave por cliente, confirmado. 429 = balde
compartilhado, e aí o conserto já está previsto no código (`CLIENT_IP_HEADER=CF-Connecting-IP`, que
o `ClientIp` aceita, **ou** `XFF_DEPTH=2` — um dos dois, nunca os dois).

### 3.2 A consequência metodológica: o teste externo não mede só o seu servidor

Com o Cloudflare terminando TLS na borda, **o teto de 292 req/s medido no §1 pode ser dele, não
seu**. O `cf-cache-status: DYNAMIC` garante que as requisições chegaram à origem, mas não que a
origem foi o gargalo. Para medir **a máquina**, o próximo teste tem de bater no IP de origem com
`Host:` na mão, contornando o CDN — e isso muda a leitura de tudo que vier depois.

---

## 4. O que isto fecha e o que continua aberto

**Fecha:** a porta de entrada tem folga confortável para qualquer carga plausível de uma clínica —
zero erro a 200 concorrentes, e o custo de API+banco é ~7 ms sobre um endpoint sem I/O. O limitador
do BFF funciona e não é burlável.

**Continua aberto:**

| # | O quê | Como se prova |
|---|---|---|
| A1 | ~~A chave é o cliente ou o PoP?~~ **Medido: é o cliente** (§3.2). Resta confirmar com um 2º IP real | 1 requisição do celular fora do wi-fi |
| A2 | Os limitadores da API (2.000/min, 200/min, 10/2min) | `rate-limit.sh interno`, no servidor |
| A3 | O teto da **máquina**, sem o CDN no meio | Repetir §1 contra o IP de origem |
| A4 | Quantas clínicas cabem | Perfil de carga × a curva. Sem o perfil, não há tradução |
| A5 | [D-21](50-debitos-tecnicos.md) — o build degrada quem está sendo servido? | Rodar §1 e disparar um deploy no meio |

**Não relacionados a carga, achados no caminho** (detalhados na conversa que originou este doc):

- O BFF engolir o 429 do magic link (§2.2) — inobservabilidade, e possivelmente UX enganosa: o
  usuário barrado lê "enviamos o link".
- `RESEND_API_KEY: ${RESEND_API_KEY:?...}` ([`compose.dokploy.yml:178`](../compose.dokploy.yml#L178))
  **aborta o `up`** se a variável faltar ou estiver vazia — "desligar o Resend" tirando a env
  derruba o stack. O corte limpo é revogar a chave no painel da Resend.
- `pg_stat_statements` **não está carregado** (sem `shared_preload_libraries` no serviço `db`), e o
  Prometheus **não tem `postgres_exporter`** nos 4 jobs — o banco é ponto cego do Grafana. Nenhum
  dos dois é adicionável retroativamente a um teste já rodado.

---

## 5. Rastro deixado em produção

- **Banco:** nada. O modo externo só faz GET em health checks; o `client-error` "morre no stdout do
  BFF" e não chama a API.
- **Log:** ~25 linhas `log.error('erro no browser')` com `origem: teste-carga` e
  `route: /teste-carga`. Vão para o Loki e **contam nos painéis de erro** da janela — filtre por
  `origem` ao ler o dashboard 03.
- **Métrica:** o pico de 3.650+ requisições aparece nos dashboards 02 e 11 na janela do topo.

## 6. Instrumentos

- [`deploy/carga/baseline.sh`](../deploy/carga/baseline.sh) — fotografa Postgres + host para
  comparar antes/depois. **Não foi rodado neste teste** (exige acesso ao servidor).
- [`deploy/carga/rate-limit.sh`](../deploy/carga/rate-limit.sh) — modo `externo` (usado aqui) e
  modo `interno` (pendente, §A2).
