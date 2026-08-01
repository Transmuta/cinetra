# 87 — O servidor na Hostinger: cuidados, o que derruba, o que ataca, e o que já está coberto

A produção do Cinetra sai do plano de **Oracle Cloud A1 (Vinhedo)** descrito em
[`59-deploy-dokploy-oci.md`](59-deploy-dokploy-oci.md) e vai para uma **VPS da Hostinger**. Este
documento é o levantamento pedido antes de provisionar: **o que muda**, **o que pode deixar a
aplicação fora do ar**, **quais ataques importam** e — explicitamente — **o que já temos coberto**,
para não gastar esforço em cima de coisa feita.

> **Estado factual, para não haver ilusão de progresso:** nada disto está provisionado. O A1 nunca
> foi criado ([memória do deploy](59-deploy-dokploy-oci.md#14-pendências--follow-ups)), o `ci.yml`
> tem o job `deploy` esqueletado esperando o secret do webhook, e o
> [`compose.dokploy.yml`](../compose.dokploy.yml) nunca rodou fora do smoke local. Portanto: **tudo
> abaixo marcado "coberto" é código escrito e testado, não comportamento observado em produção.**
> A distinção é o assunto do §9.

> **ATUALIZAÇÃO 2026-07-31 — o parágrafo acima está vencido.** O servidor **foi provisionado**: um
> **KVM 2 (8 GB)** na Hostinger, com prod + HML + observabilidade + Dokploy no ar. O que isso muda
> neste documento está em **[§2.1](#21-o-que-a-máquina-de-verdade-mediu-2026-07-31--a-estimativa-acima-estava-errada)**
> (a conta de memória, que estava ~3× superestimada) e em **[§9](#9-o-que-eu-não-medi)** (o alcance
> revisado). O resto do documento — as quatro portas root-equivalentes, o firewall, os modos de
> falha — continua valendo como escrito. A decisão de provedor está travada no
> **[ADR-023](00-decisoes.md)**.

A boa notícia vem primeiro: **o plano do doc 59 sobrevive quase inteiro**. A Hostinger oferece um
template **"Ubuntu 24.04 com Dokploy"** pré-instalado, então a arquitetura (Dokploy + Traefik, dois
stacks do mesmo compose, BFF-only, um domínio por ambiente) não muda **uma linha**. O que muda é a
máquina e o **plano de gestão** dela.

---

## 1. O delta: A1 → Hostinger

| Dimensão | A1 Oracle (doc 59) | VPS Hostinger | Consequência |
|---|---|---|---|
| **CPU** | ARM `aarch64` | `x86_64` | **O risco #3 do doc 59 §10 morre.** "Build ARM que o CI x86 não vê" deixa de existir; o `picosat_elixir`/`bcrypt_elixir` (NIFs em C) e a confirmação de arm64 do §14 saem da lista de preocupações. O CI e a produção passam a rodar a mesma arquitetura. |
| **RAM** | 24 GB (Always Free) | 8 GB (KVM 2) · 16 GB (KVM 4) · 32 GB (KVM 8) | **A mudança mais importante, e a única que exige uma decisão antes de comprar** — ver §2. Sair de 24 GB para 8 GB não cabe. |
| **Disco** | boot volume 100–150 GB | 100 GB (KVM 2) · 200 GB (KVM 4) · 400 GB (KVM 8) | Disco era "o recurso escasso" no A1 e continua sendo o candidato nº 1 a derrubar tudo (§4.1). |
| **Custo / ociosidade** | grátis, com **reclamação por ociosidade** e "out of host capacity" | pago | Dois riscos operacionais reais do A1 desaparecem: a Oracle recuperar a instância idle, e não conseguir criar a VM. |
| **Firewall** | **duas** camadas (Security List da VCN + iptables da imagem Ubuntu) | firewall gerenciado no **hPanel**, que filtra **antes do tráfego chegar ao servidor**, + iptables dentro da VM | A armadilha muda de forma (§3.2). Ponto a favor: por filtrar antes da VM, ele **cobre porta publicada por container** — coisa que o UFW notoriamente não faz. Ponto contra: por default ele **dropa tudo**, e um grupo de regras vazio aplicado ao servidor **bloqueia todo o tráfego**. |
| **Backup do provedor** | nenhum | semanal automático (diário opcional), até 4 retidos; **snapshot** manual, 1 por vez, expira em 1 dia | **Complementa, não substitui** o nosso backup (§4.5). São coisas diferentes: o do provedor recupera a **máquina**, o nosso recupera o **dado**. |
| **DDoS de rede** | nada na frente | filtragem L3/L4 do provedor | Ganho real na camada 3/4. **A camada 7 continua sendo nossa** (§5.6). |
| **Região** | Vinhedo (`sa-vinhedo-1`) | São Paulo | LGPD igual: dado de paciente permanece no Brasil. |
| **Caminhos root-equivalentes** | **três** (SSH, painel Dokploy, console OCI) | **quatro** (SSH, painel Dokploy, **hPanel**, e o backup/snapshot restaurável a partir dele) | §3.1. O hPanel reinstala o SO, reseta a senha de root, abre terminal no browser e restaura backup — é root por outro caminho, e por isso **MFA na conta Hostinger deixa de ser higiene e passa a ser controle de segurança**. |

**O que não muda, e é a maior parte:** o [`compose.dokploy.yml`](../compose.dokploy.yml) serve
igual, sem edição. Isolamento de rede (`data` só com db+migrate+api, o web fora dela), BFF-only
(só `/socket` e `/webhooks` públicos na API), dois roles de RLS, HSTS saindo do BFF, CSP assada no
build, backup pré-deploy fail-closed, rotação de log local. Só trocam `WEB_HOST`, o DNS e as envs
por ambiente — exatamente como o doc 59 §7 já prevê.

---

## 2. Dimensionamento: a conta que decide o plano

O A1 dava 24 GB de graça e a arquitetura foi desenhada dentro dessa folga — inclusive a decisão de
**colocar a observabilidade no mesmo host** em vez de numa segunda VM ([doc 62 §3](62-plano-de-logs.md)),
que é o que os `mem_limit` do [`compose.obs.yml`](../deploy/observability/compose.obs.yml) sustentam.
Numa VPS paga essa folga é uma linha de fatura, então a conta precisa estar escrita:

| Consumidor | Contas | Memória |
|---|---|---|
| **Observabilidade** (7 containers, `mem_limit` **declarados**) | Loki 1500m + Grafana 512m + Prometheus 512m + Tempo 512m + cAdvisor 512m + Alloy 384m + node-exporter 128m | **≈ 4,0 GB** (teto, medido no arquivo) |
| **Stack PROD** | Postgres + api (BEAM) + web (Node) + backup-cron | ≈ 1,5–2,5 GB (estimado, **sem teto declarado** — §8) |
| **Stack HML** | idem | ≈ 1,5–2,5 GB (idem) |
| **Dokploy** | painel + Traefik + o Postgres e o Redis próprios dele | ≈ 0,5–1,0 GB |
| **Pico de build** | o Dokploy builda **na própria máquina**: `mix release` (compilação Elixir) + `vite build` | **1–2 GB transitórios, e é o pico que mata** |

Somando: **8 GB não cabe** com prod + HML + observabilidade + build. **16 GB (KVM 4) é o piso**
para o modelo do doc 59 inteiro; 32 GB (KVM 8) é o que dá folga para o build coincidir com um pico
de uso. Se o orçamento apertar, a ordem de corte é: **(1)** tirar a observabilidade para outra
máquina, **(2)** buildar fora da VM (registry externo), **(3)** desligar o HML — nunca reduzir o
backup.

**Swap de 4 GB** em qualquer plano. Não é para rodar em swap — é para o pico de build não virar OOM
kill do Postgres.

### 2.1 O que a máquina de verdade mediu (2026-07-31) — a estimativa acima estava errada

**A conta de cima está mantida como registro do raciocínio, mas a conclusão dela caiu.** O servidor
foi provisionado num **KVM 2 (8 GB)** e está no ar com **prod + HML + observabilidade + Dokploy,
tudo de pé ao mesmo tempo**:

| | Estimado (§2) | **Medido** |
|---|---|---|
| Residente, tudo ligado | 8,5–12 GB | **≈ 3,5 GB** |
| CPU durante o build | não estimado | **≈ 90%** dos 2 vCPU, sem degradação percebida no app |

**Onde a estimativa errou, para não repetir o erro:** a linha da observabilidade somava
**`mem_limit`**, que é **teto**, não consumo. Os 4,0 GB atribuídos aos 7 containers eram a soma dos
limites declarados em [`compose.obs.yml`](../deploy/observability/compose.obs.yml); o working set
real é uma fração disso. Teto de container é para conter o pior caso, não para prever o caso comum
— usar um como se fosse o outro superestimou a conta em **~3×**.

**Consequência direta:** o **KVM 2 é suficiente** e nenhum dos três cortes precisou entrar. Isso
fecha a pergunta nº 4 do [doc 91 §7](91-custos.md) e mantém o piso de custo na linha de
R$ 108,99/mês, não na de ≈ R$ 220.

> **O alcance desta medição, dito com precisão.** São observações do operador na máquina em
> operação, não uma série do Grafana anexada aqui, e — decisivo — **sob carga real baixa ou nula**.
> Os 3,5 GB são um ponto, não um teto: não medem o pico de build coincidindo com uso real, que é
> exatamente o cenário que a estimativa temia. O mesmo vale para o "sem degradação percebida": com
> pouca gente usando, não há com quem o build competir. **O número que ainda falta é o mesmo de
> antes — consumo e p95 sob clínica trabalhando** — e agora ele é medível, porque o stack de
> observabilidade está no ar. Ver [D-21](50-debitos-tecnicos.md).

---

## 3. Cuidados com o servidor

### 3.1 As quatro portas root-equivalentes

O doc 59 §3 já nomeia três. Na Hostinger são **quatro**, e cada uma precisa do seu cadeado
independente — a chave SSH não protege nenhuma das outras três:

1. **SSH** → chave apenas (senha e root direto desabilitados), **passphrase na chave**, `fail2ban`,
   allowlist de IP no firewall.
2. **Painel do Dokploy** → credencial **separada** do SSH, senha forte + **2FA**, allowlist de IP.
   Ele controla o socket do Docker, que é root na máquina.
3. **hPanel da Hostinger** → **MFA obrigatório**. Daqui se reinstala o SO, se reseta a senha de
   root, se abre terminal no browser e se restaura backup. É o caminho que não passa por nenhuma
   regra de firewall nossa.
4. **Restore de backup/snapshot** → é uma escrita total na máquina disparada do hPanel. Restaurar
   **sobrescreve tudo** e, uma vez iniciado, **não pode ser interrompido**. Ou seja: conta do
   provedor comprometida = produção destruível com dois cliques, e o item 3 é o que protege isto.

### 3.2 Firewall: uma camada gerenciada, e a defesa estrutural

O modelo da Hostinger é **drop-all por default**: só passa o que houver regra de `accept`. Isso
inverte a armadilha do OCI (lá o erro era esquecer a segunda camada; aqui é aplicar um grupo de
regras vazio e derrubar o mundo). Regras:

| Porta | Origem | Uso |
|---|---|---|
| `22` | **só nossos IPs** | SSH |
| `3000` (painel Dokploy) | **só nossos IPs** | administração |
| `80` | mundo | redirect + desafio do Let's Encrypt (**não feche** — §4.8) |
| `443` | mundo | o app |
| `5432` | **fechado** | o banco não publica porta no compose; nunca republique |
| `3000` do Grafana | **não publicar** | ver §5.4 |

Dois cuidados que valem mais que a tabela:

- **A defesa estrutural é não publicar a porta**, não a regra do painel. Regra em painel é
  configuração que alguém apaga; `ports:` ausente no compose é topologia. Hoje o banco já é assim
  (invisível ao host e à internet) e o Grafana **não** é (§5.4).
- **`DOCKER-USER`, não `INPUT`.** Se um dia se restringir porta publicada por dentro da VM, a regra
  tem de entrar na cadeia `DOCKER-USER` — o Docker escreve NAT/FORWARD e o pacote nunca passa pelo
  `INPUT` do UFW. É o item 6 do checklist do [doc 86](86-seguranca-da-observabilidade.md), e a
  única razão de ele ser menos urgente aqui é que o firewall do provedor filtra antes da VM.
- **Sempre mexa em firewall com uma segunda sessão SSH aberta.**

### 3.3 Sistema operacional

- `unattended-upgrades` **só para security updates**.
- **`apt-mark hold`** no Docker: um `apt upgrade` que reinicia o daemon derruba os dois stacks de
  uma vez. Upgrade de Docker/kernel só em janela planejada, esperando o reboot. (Hoje isto é
  **prosa no doc 59 §13** — não há artefato que o garanta. Ver §8.)
- Relógio (`systemd-timesyncd`) conferido: assinatura de webhook tem janela de tolerância de 300 s
  ([`Api.Messaging.Svix`](../api/lib/api/messaging/svix.ex)) — relógio derivando rejeita entrega
  legítima.
- **`docker system prune` agendado.** Dois stacks buildando na mesma máquina acumulam camadas até o
  disco acabar. Também é prosa hoje.

---

## 4. O que pode deixar a aplicação fora do ar

Ordenado por (probabilidade × impacto), com a cobertura de cada um.

### 4.1 Disco cheio — o mais provável de todos

Dois stacks + observabilidade + builds na mesma máquina. Disco cheio não degrada: o Postgres para
de escrever e a clínica para de trabalhar.

**Coberto:** rotação de log local no compose (`json-file`, 3 × 20 MB por container — é o piso, vale
mesmo com o Alloy embarcando para o Loki); alerta **"Disco quase cheio"** no
[`grafana-alertas.yml`](../deploy/observability/grafana-alertas.yml); retenção do Loki.
**Falta:** o `prune` agendado. O alerta avisa; nada colhe.

### 4.2 OOM kill — e o app é invisível para o alerta que existe

**Achado desta análise.** Os 7 containers da observabilidade têm `mem_limit`. Os do
[`compose.dokploy.yml`](../compose.dokploy.yml) — `db`, `api`, `web`, `migrate`, `backup*` —
**não têm nenhum**, em nenhum dos dois stacks. Duas consequências:

1. Nada limita o BEAM, o Node ou o Postgres. Num pico, quem o kernel mata é o maior processo —
   com boa chance, o Postgres.
2. **O alerta "Container encostando no próprio teto de memória" não os vê, por construção.** A
   expressão divide por `container_spec_memory_limit_bytes{name!=""} > 0`, e o `> 0` está lá de
   propósito (container sem limite reporta teto zero, a divisão viraria `+Inf` e alarmaria para
   sempre). O comentário no arquivo diz que o `mem_limit` "é a salvaguarda que substituiu a segunda
   VM" — só que essa salvaguarda nunca foi aplicada aos containers do app.

O doc 59 §10 lista "limites de memória por container" como mitigação do risco #5. **Está na prosa,
não no compose.** Conserto e teste em §8.

### 4.3 Migration destrutiva ou que trava

O único caso em que rollback de imagem não salva — schema é catraca de sentido único, e o que se
perde é **dado**.

**Coberto, e bem:** expand-contract escrito com a lista perigosa (doc 59 §8); `backup` **pré-deploy
fail-closed** (roda antes do `migrate`; upload falha → deploy para); HML idêntico rodando a mesma
migration dias antes; regra do `CONCURRENTLY` em [`migrations.md`](../.claude/rules/migrations.md).
**Falta:** nada estrutural. É disciplina no dia — o ritual do doc 59 §11.

### 4.4 O backup fail-closed barra o deploy

Contrapartida deliberada de 4.3: se o R2 estiver fora, **não dá deploy**. É a escolha certa (nunca
alterar schema sem backup fresco), mas precisa ser sabida antes de acontecer às 19h de uma
sexta — senão alguém "resolve" comentando o serviço no compose.

### 4.5 Banco em container, num volume, numa máquina

O `pgdata` é um volume Docker na VPS. Não há réplica.

**Coberto:** `pg_dump` do owner **1×/hora**, cifrado com `age` (chave pública no servidor; a privada
fica offline), em bucket R2 **separado do de anexos** com credencial escopada; retenção escalonada
(`hourly/` 48 h + `daily/` 30 d); heartbeat no healthchecks.io para o cron que morre em silêncio;
[`restore.sh`](../deploy/backup/restore.sh) escrito. **Agora somam-se** os backups semanais e o
snapshot do provedor — úteis para recuperar a **máquina**, não o dado: só 1 snapshot por vez, ele
**expira em 1 dia**, é apagado se você reinstalar o SO, e restaurar **sobrescreve tudo**.
**Falta:** **ensaiar o restore**. Backup não testado não é backup — e é a única linha desta seção
que não se resolve escrevendo código.

### 4.6 Uma máquina só é um ponto único de falha

Reboot do provedor, manutenção, vizinho saturando o host. Não há HA, e isso é **decisão consciente
de custo** — o que se compra em troca é RTO baixo: envs anotadas fora da VM + dump no R2 +
"máquina descartável" = recriar em ~30 min.

**Falta:** declarar RTO/RPO por escrito (o RPO já é 1 h por construção) e o **monitor externo** que
bate em `/ready` — sem ele, "o site está fora" chega pela clínica ligando.

### 4.7 Deploy que sobe e não serve

**Coberto:** `raise` no boot da API se faltar `SECRET_KEY_BASE`/`TOKEN_SIGNING_SECRET`/`DATABASE_URL`;
guarda de boot no BFF que **derruba o container** se `API_PUBLIC_ORIGIN` de runtime divergir do que
foi assado na CSP; healthchecks do Traefik apontando para `/api/ready` (readiness, com banco) na API
e `/health` (liveness, sem I/O) no web — a assimetria é deliberada; e **o container antigo continua
servindo** se o novo não passa no healthcheck. O HML pega tudo isso dias antes.

### 4.8 Certificado que não renova

Se o `80` fechar no firewall, o desafio do Let's Encrypt falha e o certificado expira **90 dias
depois, em silêncio**. Cuidado extra: recriar o stack várias vezes seguidas queima o rate limit de
emissão do LE.

**Falta:** um check de expiração de certificado. Não existe hoje.

### 4.9 Esgotamento do pool do Postgres

**Coberto:** `pool_size: 16` com a conta escrita no [`runtime.exs`](../api/config/runtime.exs)
(7 conexões podem estar em job do Oban ao mesmo tempo) e `Api.ObanPoolTest` como alarme — mexer nas
filas sem mexer no pool deixa teste vermelho.

### 4.10 O Traefik do Dokploy é o único ingress

Se ele cai, cai tudo. O reflexo errado é publicar porta do container como contorno — o que remove o
TLS e o isolamento de uma vez. O contorno certo é reiniciar o Traefik.

---

## 5. Ataques: o que importa e o que já se defende

### 5.1 Força bruta / credencial no plano de gestão
**Vetor:** SSH exposto, painel do Dokploy exposto, conta do provedor.
**Mitigação:** §3.1 e §3.2 inteiros. **Cobertura hoje: prosa em doc, nada aplicado** — é o trabalho
do dia 0.

### 5.2 O socket do Docker via Alloy — root na máquina
O Alloy monta `/var/run/docker.sock:ro`, e o `:ro` **não** limita o que a API do Docker aceita: quem
alcança o socket cria container privilegiado e é root no host. Achado **A1** do
[doc 86](86-seguranca-da-observabilidade.md), **medido** (handler de escrita alcançável, parou no
HTTP 400 sem explorar até o fim).
**Mitigação:** socket proxy na frente (`CONTAINERS=1`, escrita em `0`). **Pendente.**

### 5.3 Segredos legíveis por dentro do stack
Consequência de 5.2 e do A7: as envs do app (R2, Google, `SECRET_KEY_BASE`) são alcançáveis por
componentes de observabilidade. **Mitigação real** — segredos saindo de `Env` para arquivo/`secrets:`
— está registrado como débito grande no checklist do doc 86 (item 9). **Pendente, e é decisão.**

### 5.4 Grafana publicado, com `secret_key` default
`ports: ${GRAFANA_PORT:-3000}:3000` publica; o `GF_SECURITY_SECRET_KEY` é o default publicado
(**medido**, A2/A3 do doc 86). E o Grafana é a **ponte** entre o plano de observabilidade e o plano
de dados: ele entra na rede `app` para ler as views `metrics_*`.
**Mitigação:** tirar o `ports:`, alcançar por Traefik+TLS ou túnel, e `GF_SECURITY_SECRET_KEY` com
`:?` e valor aleatório. **São os itens 1 e 2 do checklist do doc 86, e são pré-requisito do
provisionamento — não follow-up.**

### 5.5 Enumeração e spam no login
**Coberto:** `RateLimitAuth` com chave dupla no magic link — **por e-mail** (5/15 min, contra
bombardear um alvo) **e por IP** (10/2 min, contra disparar para mil e-mails); magic link e convite
viajam **selados** (cifrados) na URL; allowlist de `jti` na tabela; cookie `_api_key` **cifrado**;
plug `VerifyTokenSubject` fazendo o binding `jti`↔`sub`; sign-out revoga.

### 5.6 Flood / DDoS na camada 7
**Coberto:** rate limit de **dois estágios** — borda por IP (2.000/min, corta enxurrada anônima
**antes do banco**) e ator (200/min, o limite fino, depois do `LoadScope`). A separação foi medida:
enquanto só existia o estágio de ator, cada requisição barrada ainda pagava 5 queries
([doc 68](68-bate-volta-rate-limit-global.md)).
**Ganho novo:** filtragem L3/L4 do provedor.
**Falta:** não há WAF nem cache de borda — o Traefik fica direto na internet.

> **Se entrar uma edge (Cloudflare é o candidato natural, já usamos R2), a decisão vem em par.**
> `config :api, trusted_client_ip_headers: ["cf-connecting-ip"]` tem de entrar **junto** com a
> mudança de proxy. O default hoje é **lista vazia** de propósito, e a razão está escrita em
> [`ApiWeb.ClientIp`](../api/lib/api_web/client_ip.ex): o default já foi `["fly-client-ip"]` e
> sobreviveu à saída da Fly, tornando o header forjável em produção — os dois limitadores viraram
> no-op **sem nada quebrar visivelmente**. Ligar a edge sem declarar o header repete exatamente
> essa falha, na direção oposta.

### 5.7 Spoof de `x-forwarded-for` (D-16)
`ClientIp` pega `List.first/1` do XFF, e o Traefik **anexa** em vez de substituir — um cliente que
mande `X-Forwarded-For: 9.9.9.9` produz `9.9.9.9, <ip real>`, e vale o que o atacante escreveu.
**Custo hoje: baixo por acidente de topologia** (a API é interna; das duas rotas públicas dela, o
`/socket` é tratado no endpoint antes do router e o `/webhooks` está fora do rate limit de propósito).
**Vira crítico** no minuto em que qualquer rota passar a ser pública direto na API, ou com uma edge
na frente. Débito [D-16](50-debitos-tecnicos.md); o conserto é escolher a **profundidade** do XFF
em vez do primeiro item.

### 5.8 Webhook forjado, e replay
**Coberto:** assinatura conferida sobre o **corpo cru** antes de qualquer leitura de banco
(`CacheRawBody`), com `Plug.Crypto.secure_compare/2`; **fail closed** — sem o segredo no ambiente o
endpoint recusa **tudo** (a alternativa, aceitar sem verificar, seria um endpoint aberto de escrita
cujo sintoma é nenhum); Svix/Resend com janela de tolerância de 300 s.
**Falta:** a **Zernio não tem janela de timestamp** — está documentado em
[`webhooks.ex`](../api/lib/api/messaging/webhooks.ex): um evento assinado e capturado pode ser
reenviado depois. Rota pública na API, portanto alcançável de fora.

### 5.9 Cruzamento de tenant
**Coberto, e é a parte mais forte do sistema:** dois roles no Postgres (o servidor roda como
`cinetra_app`, `NOBYPASSRLS`), RLS por `clinic_id` via GUC de transação, policies do Ash por cima, e
o job **`api-rls`** no CI conectando como o role restrito. WebSocket não passa por policy nem por
RLS, então o canal **relê com o escopo do assinante** (R-D1).
**Limite conhecido:** o gate `:rls` prova a **porta de entrada**, não cada leitura interna — a GUC
fica pendurada no sandbox ([D-15](50-debitos-tecnicos.md), regra em
[`migrations.md`](../.claude/rules/migrations.md) §3). Leitura por-tenant nova em caminho de escrita
se prova por `psql` sob o role restrito, não por `mix test`.

### 5.10 Upload malicioso
**Coberto:** R2 privado, URL assinada, SigV4 próprio, FKs `RESTRICT` para o CASCADE não deixar bytes
órfãos, trilha de visualização, e **profissional não vê anexo**.
**Falta:** **antivírus** ([D-6](50-debitos-tecnicos.md)) e **rate limit na emissão de URL assinada**
([D-8](50-debitos-tecnicos.md)). A URL de upload também segue válida depois do `confirm`
([D-7](50-debitos-tecnicos.md)).

### 5.11 Supply chain
Sete imagens de terceiros na observabilidade, **sem mecanismo de atualização** (A8 do doc 86 —
"baixo virando médio com o tempo"), e o **build roda na VM de produção**, o que põe `npm`/`hex` na
mesma máquina que serve pacientes.
**Mitigação:** `dependabot.yml` com ecossistema `docker` sobre `deploy/observability/` (item 4 do
checklist, barato).

### 5.12 LGPD: o dump tem CPF
**Coberto:** cifra client-side com `age` (o servidor cifra e **não** decifra), bucket separado com
credencial escopada, retenção 90 d na trilha, sensíveis redigidos na auditoria, HML com dado
**sintético** e banco/segredos/bucket próprios.
**Falta:** eliminação de dados do titular é só soft-delete ([D-1](50-debitos-tecnicos.md)); os
documentos legais estão no ar com **placeholder** e sem revisão jurídica
([D-13](50-debitos-tecnicos.md)); o aceite não fica registrado ([D-14](50-debitos-tecnicos.md)).
Nada disso é do servidor, mas entra no mesmo pacote de "subir para produção com paciente real".

---

## 6. Resumo do que já está coberto

Para responder direto à pergunta "o que já temos":

**Aplicação** — RLS com dois roles + policies do Ash + gate `api-rls` no CI · rate limit em dois
estágios (borda por IP, ator) · rate limit de auth com chave dupla no magic link · cookie de sessão
cifrado + allowlist de `jti` + binding `jti`↔`sub` · magic link/convite selados · `check_origin` no
socket + token de realtime no subprotocolo + releitura com escopo do assinante · HSTS, CSP por
ambiente, `X-Frame-Options`, `nosniff`, `Referrer-Policy`, `frame-ancestors: none` · assinatura de
webhook fail-closed sobre o corpo cru.

**Dado** — `pg_dump` 1×/h cifrado com `age`, bucket separado, credencial escopada, retenção
escalonada 48 h/30 d · backup **pré-deploy fail-closed** · heartbeat do cron · script de restore
escrito · banco sem porta publicada e inalcançável pelo web (isolamento de rede estrutural).

**Deploy** — CI como portão (formatter, `--warnings-as-errors`, `coveralls` 80%, `api-rls`,
`svelte-check`, coverage do web) · HML idêntico a prod na mesma máquina · expand-contract escrito
com lista perigosa · `raise` no boot por env faltando · guarda de boot do BFF · healthcheck no
Traefik com liveness/readiness distintos · container antigo segue servindo se o novo não passa.

**Observabilidade** — logs (Loki) + métricas (Prometheus/cAdvisor/node-exporter) + traces (Tempo) ·
9 regras de alerta, incluindo disco, memória da máquina, 5xx, p95, job do Oban e "pipeline parado" ·
`mem_limit` por container na observabilidade · rotação de log local como piso · heartbeat externo
dos 6 crons do Oban · role só-leitura para o Grafana ler as views `metrics_*`.

**Novo, que passa a vir do provedor** — filtragem de DDoS L3/L4 · backup semanal da máquina +
snapshot manual · firewall gerenciado que filtra antes da VM (cobre porta publicada por container) ·
dado em São Paulo.

---

## 7. Ordem de execução

**Antes do primeiro deploy** (nenhum destes é follow-up):

1. Escolher o plano pela conta do §2 — **KVM 4 (16 GB) é o piso** para prod + HML + observabilidade.
2. `GF_SECURITY_SECRET_KEY` com `:?` e valor aleatório; **tirar o `ports:` do Grafana** (A2/A3).
3. **`mem_limit` nos containers do app** nos dois stacks (§4.2, §8).
4. MFA na conta Hostinger; 2FA no painel do Dokploy; SSH só-chave + `fail2ban`; firewall do hPanel
   com as 4 regras do §3.2 — **com uma segunda sessão SSH aberta**.
5. Gerar segredos novos para prod (não reaproveitar dev) e **rotacionar** os que já circularam no
   `.env` do working tree (R2 e client secret do Google).
6. Swap de 4 GB; `apt-mark hold` no Docker; `unattended-upgrades` só security; `prune` agendado.
7. Criar os webhooks no Dokploy e colar as URLs nos secrets `DOKPLOY_DEPLOY_WEBHOOK_PROD`/`_HML`.
8. **Ensaiar o restore** do dump num banco separado — antes de existir paciente real.
9. Provar o WS ao vivo em `wss://<WEB_HOST>/socket` (a pendência do doc 59 §14).

**Primeira semana:** socket proxy na frente do Alloy (5.2) · contact point do alerta + monitor
externo em `/ready` · `dependabot.yml` para as imagens · poda de atributo nos traces (A6) · check de
expiração de certificado.

**Decidir depois, com custo escrito:** segredos saindo de `Env` (5.3) · janela de timestamp na
Zernio (5.8) · profundidade do XFF (D-16) · antivírus de anexo (D-6) · Postgres gerenciado externo,
para desacoplar o dado da máquina descartável.

---

## 8. O achado desta análise, e onde vai o teste

**O que é.** O [`compose.dokploy.yml`](../compose.dokploy.yml) não declara `mem_limit` (nem
`deploy.resources`) para nenhum serviço. O doc 59 §10 lista "limites de memória por container" como
mitigação do risco #5, e o comentário do `compose.obs.yml` chama o `mem_limit` de "a salvaguarda que
substituiu a segunda VM" — mas os containers do app nunca receberam nenhum. Em cima disso, o alerta
`cinetra-container-no-teto` filtra por `container_spec_memory_limit_bytes > 0`, **então esses
containers ficam fora dele por construção**: são exatamente os que não têm teto, e são os que servem
o paciente.

**Por que importa mais na Hostinger que no A1.** Com 24 GB de folga, a ausência de teto raramente
seria exercitada. Com 16 GB divididos entre dois stacks, observabilidade e um build que pica 1–2 GB,
o OOM kill deixa de ser hipótese — e quem o kernel escolhe é, com boa chance, o Postgres.

**Como se prova** (o CLAUDE.md manda achado virar teste, e este é verificável por script). O
precedente é o [`verificar.sh`](../deploy/observability/verificar.sh), que já checa "porta não está
publicada no host". Acrescentar ali:

- todo serviço de longa duração do `compose.dokploy.yml` declara `mem_limit` (`db`, `api`, `web`,
  `backup-cron`);
- o Grafana não publica em `0.0.0.0`;
- o `secret_key` do Grafana não é o default.

E a mutação que valida o teste: **remova um `mem_limit` e confira que o script fica vermelho.** Se
ficar verde, ele não prova o que o nome dele diz — é a lição do
[doc 35](35-plano-execucao-backlog.md) ("mute a regra e veja o teste ficar vermelho") aplicada a
infra, e a mesma que o [`migrations.md`](../.claude/rules/migrations.md) §3 cobra para RLS.

Enquanto não estiver consertado, entra em [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md) — não
passa em silêncio.

---

## 9. O que eu **não** medi

Honestidade sobre o alcance deste documento:

- ~~**Nada foi medido em servidor nenhum.**~~ **Corrigido em 2026-07-31** — ver
  [§2.1](#21-o-que-a-máquina-de-verdade-mediu-2026-07-31--a-estimativa-acima-estava-errada). A VPS
  existe (KVM 2), a conta de memória foi medida e a estimativa deste documento **errou por ~3× para
  cima**, porque somava `mem_limit` (teto) como se fosse consumo. O que **continua não medido** é o
  que só aparece com carga: consumo e p95 com clínica trabalhando, e o build coincidindo com uso
  real. Registrado como [D-21](50-debitos-tecnicos.md).
- **As características do provedor vêm do material da Hostinger**, não de teste próprio: onde o
  firewall filtra, a retenção de backup, o comportamento do snapshot, a filtragem de DDoS. O item
  que mais merece confirmação é **se o firewall do hPanel de fato cobre porta publicada por
  container** — a documentação diz que filtra antes do tráfego chegar ao servidor, o que implica que
  sim, mas isso se confirma em cinco minutos com um `nc` de fora contra uma porta publicada de
  teste, e é o tipo de suposição que, errada, expõe o Grafana.
- **Não auditei CVE por versão** das imagens. 5.11 é sobre a ausência de mecanismo, não um
  levantamento de vulnerabilidade conhecida.
- **Não explorei 5.2 até o fim** — o doc 86 parou no HTTP 400, que já prova o handler de escrita
  alcançável.
- **Não reavaliei os débitos** de D-1 a D-16 um por um; usei o que cada um já afirma sobre si.
