# 59 — Deploy no Dokploy (Oracle Cloud A1, Vinhedo)

Produção do Cinetra sai do Fly.io e vai para uma **VPS Oracle Cloud A1 (ARM, Always Free, 4
OCPU / 24 GB)** na região **Vinhedo (`sa-vinhedo-1`)**, orquestrada por **Dokploy** (Docker +
Traefik). Substitui, na prática, o [`17-deploy-fly.md`](17-deploy-fly.md) — que fica como
referência histórica do modelo Fly. A **mecânica de segurança do app** (dois roles de RLS, HSTS
no BFF, CSP por ambiente, token do WS no subprotocolo) foi construída na Onda 5
([`46`](46-onda-5-producao.md)/[`47`](47-bate-volta-onda-5.md)) e **não muda**; o que muda é o
alvo de deploy e o plano de gestão da máquina.

Artefatos: [`compose.dokploy.yml`](../compose.dokploy.yml) (o deploy real), `api/Dockerfile.prod`,
`web/Dockerfile.prod`, `Api.Release`.

> **Mudança de mentalidade em relação ao Fly:** na Fly, o SO, a rede e o TLS eram do provedor.
> Numa VPS o SO e a rede **são nossos**: o deploy do app fica fácil, mas firewall, patch e o socket
> do Docker passam a ser responsabilidade nossa. O **backup** chegou a ser nosso também e desde
> 2026-08-05 voltou a ser do painel (§13). A regra que sustenta isso é **máquina descartável**:
> config (env) mora fora da VM e o estado se recupera por snapshot, então recriar a máquina é
> rotina, não catástrofe (ver §Backup e recriar a VM).

---

## 1. O modelo: dois ambientes, um servidor

```
   PR ──> CI (portão: mix coveralls + job api-rls + svelte-check/coverage) — em todo PR e push
   │      (em PR o job `imagem` CONSTRÓI as imagens como gate, e não publica)
   │
   ├─ push em DEVELOP ─> CI publica :develop no GHCR ─> webhook ─> Dokploy faz PULL ─> stack HML
   │                                  hml.cinetra.com.br (domínio único; /socket e /webhooks -> API)
   │                                  banco próprio · segredos próprios · bucket R2 próprio · dado SINTÉTICO
   │
   └─ push em MAIN ────> CI publica :main no GHCR ────> webhook ─> Dokploy faz PULL ─> stack PROD
                                      cinetra.com.br (domínio único; /socket e /webhooks -> API)
                                      banco de produção · segredos de produção
```

Os **dois stacks rodam no mesmo A1**, a partir do **mesmo** [`compose.dokploy.yml`](../compose.dokploy.yml).
HML é **idêntico** a prod (mesma máquina, mesmo Dockerfile, mesmo passo de `migrate`); só muda o
que é injetado por env — **e a imagem do BFF**, que é atada ao ambiente porque a CSP é assada no
build ([ADR-028](00-decisoes.md)): `cinetra-api` é o mesmo build nas duas tags,
`cinetra-web:main` ≠ `cinetra-web:develop`.

| | HML (branch `develop`) | PROD (branch `main`) |
|---|---|---|
| `STACK` | `hml` | `prod` |
| `IMAGE_TAG` | `develop` | `main` |
| `WEB_HOST` (domínio único) | `hml.cinetra.com.br` | `cinetra.com.br` |
| Banco | próprio (dado sintético) | produção |
| Segredos | próprios | produção |
| R2 | bucket/prefixo de teste | bucket de produção |
| OAuth Google | client de teste | client de produção |

**Por que este modelo:** todo risco perigoso (build ARM, migration, guarda de boot, env)
bate **primeiro no HML**, dias antes de chegar na main. É a mitigação mais forte do dia do deploy
(§10).

## 2. CI e deploy são coisas separadas

- **CI (GitHub Actions, [`.github/workflows/ci.yml`](../.github/workflows/ci.yml))** = o **portão**.
  Roda em todo PR e push: `mix format --check`, `compile --warnings-as-errors`, `mix coveralls`
  (gate 80%), o job **`api-rls`** (conecta como `cinetra_app` NOBYPASSRLS e prova a RLS),
  `svelte-check` + coverage do web. **Continua no GitHub, igual.**
- **Dokploy** = só o **deploy**: clona a branch, **baixa a imagem que o CI publicou** e sobe.
  Disparado por **webhook**, no fim do workflow, **só quando o CI fica verde**. *(Buildava no
  servidor até 2026-08-05 — [ADR-028](00-decisoes.md) / [doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md).)*

> **Não empurrar testes para dentro do Dokploy.** Rodar a suíte no `docker build` perde o job
> `api-rls` (que precisa de um Postgres com os dois roles), perde os gates de cobertura, roda na
> VM de produção competindo com o app, e só rodaria no deploy — tarde demais, depois do merge. O
> CI no GitHub roda **em PR**, antes do merge, que é onde o erro tem de ser pego.

O job **`deploy`** já está no `ci.yml`: `needs: [api, api-rls, web, imagem]` (só roda depois dos
gates **e da publicação da imagem**, para a tag existir quando o Dokploy for buscá-la), `if` só em
push para `main` (prod) ou `develop` (hml), nunca em PR. Faz um `POST` no webhook do ambiente, cuja
URL vem dos secrets `DOKPLOY_DEPLOY_WEBHOOK_PROD`/`_HML`, **confere o status da resposta** e manda o
service token do Cloudflare Access quando ele existe (§5.1 e [doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md)
§2). **Enquanto o Dokploy não existir, o secret está ausente e o passo é pulado sem falhar o CI** —
falta só criar os webhooks no painel e colar as URLs nos GitHub Secrets. O gatilho de push do
workflow também passou a incluir `develop` (era só `main`), para o fluxo HML.

## 3. Plano de gestão: acesso externo com allowlist de IP + chave

O **app é público** (clínicas e pacientes acessam de qualquer IP; o WebSocket sai do browser
deles) — isso **não** entra em allowlist. O que entra em **allowlist de IP + chave** é o **plano
de gestão**: SSH e o painel do Dokploy. É lá que mora o risco — o painel controla o socket do
Docker, que é root na máquina.

O OCI tem **dois firewalls independentes**, e a porta precisa estar aberta **nos dois** (é a
armadilha nº 1 de quem vem de outro provedor: abre no console, testa, "não funciona", porque o
iptables do SO ainda barra):

1. **Security List / NSG da VCN** (console OCI).
2. **iptables dentro da imagem Ubuntu** (a imagem da Oracle já vem com regras restritivas
   pré-carregadas).

Regras (nos **dois**):

| Porta | Origem | Uso |
|---|---|---|
| `22` (SSH) | **só nossos IPs** (IP fixo/VPN) | administração |
| `3000` (painel Dokploy) | **fechada** (após configurar o `dok`) | painel vai por `dok` + Cloudflare Access (§5.1) |
| `443` | **só faixas do Cloudflare** | o app, atrás do proxy (§5.1) |
| `80` | **só faixas do Cloudflare** | Cloudflare→origem; o redirect fica no Cloudflare |
| `5432` (Postgres) | **fechado** | nunca sai da rede interna |

Hardening do SSH: **só chave** (senha e root direto desabilitados, **passphrase na chave**),
`fail2ban`. Painel do Dokploy: senha forte + 2FA, sempre atrás de HTTPS com domínio, nunca IP cru.
**Sempre mexa em firewall com uma segunda sessão SSH aberta**, para não se trancar para fora.

> **A chave SSH não é a única fechadura.** Há **três** caminhos root-equivalentes para a máquina, e
> cada um precisa do seu cadeado: **(1)** SSH (chave + allowlist + passphrase); **(2)** o **painel
> do Dokploy** — credencial *separada* do SSH, e ele controla o socket do Docker = root, então
> senha forte + 2FA + allowlist; **(3)** a **conta da Oracle (console web)** — pode adicionar
> chave, usar serial console, resetar a VM, então **MFA na conta OCI**. O `443` é público, mas isso
> é *usar o app*, não *acessar a máquina*.

### 3.1 Quem alcança o quê (superfície de rede)

- **Público (443) — domínio único (`WEB_HOST`):** por padrão tudo vai para o **web** (BFF). A
  **API não tem host público próprio** (o subdomínio `api.*` foi removido — BFF-only). Só **dois
  paths** de `WEB_HOST` o Traefik roteia para a API:
  - **`/socket`** — o WebSocket, único caminho que o browser toca direto na API (`wss://<WEB_HOST>/socket`);
  - **`/webhooks`** — provedores externos (Resend hoje; genérico para os próximos).

  Todo o resto (`/api/*` REST, OAuth, magic-link, resposta do paciente em `/confirmar`) é
  `browser → web (BFF) → api`, server-to-server. Os dois routers da API têm prioridade maior que o
  catch-all do web. A API continua se defendendo com `check_origin` no socket, token de realtime no
  subprotocolo, policies + RLS e rate limit — o BFF-only **remove a superfície pública**, não troca
  a autenticação. (Rastreado no código que só essas duas rotas são de fato públicas.)
- **Interno (rede `data`):** o **banco**, alcançável **só** por `migrate` e `api`. O **web NÃO
  está na rede `data`** — não alcança o Postgres nem por TCP (o invariante "só a API fala com o
  banco" é estrutural, ver [`compose.dokploy.yml`](../compose.dokploy.yml)). O banco não publica
  porta: invisível ao host e à internet.

## 4. Provisionar o A1 em Vinhedo

1. **Conta OCI com home region = `Brazil Southeast (Vinhedo)`** — a home region é escolhida **no
   cadastro e não muda depois**, e os recursos Always Free ficam presos a ela. Errar aqui exige
   refazer a conta.
2. Logo após criar, **upgrade para "Pay As You Go"** — continua sem custo dentro do Always Free,
   mas evita a **reclamação por ociosidade** (a Oracle recupera instâncias idle) e melhora o
   acesso a capacidade de A1.
3. Instância **`VM.Standard.A1.Flex`, 4 OCPU / 24 GB**, Ubuntu 22.04/24.04 (aarch64), boot volume
   **~100–150 GB** (pensando em imagens/logs/build de dois ambientes).
4. **"Out of host capacity"** é comum em A1 no Brasil — reintente em outro AD/horário, ou com um
   script/terraform em loop.
5. Guarde a **chave SSH** da criação (não dá para baixar depois).
6. **Swap** (2–4 GB) mesmo com 24 GB — barra runaway de build.

## 5. DNS (atrás do Cloudflare)

Registros para o **IP público do VPS**, todos **proxied (laranja)** no Cloudflare:

- `cinetra.com.br` → **A** (apex, não aceita CNAME) — app prod.
- `hml.cinetra.com.br` → **A** — app HML.
- `dok.cinetra.com.br` → **A** — painel do Dokploy (§5.1).

**Não há `api.*`** — BFF-only: a API é servida em `/socket` e `/webhooks` do próprio domínio.

### 5.1 Cloudflare (proxy + WAF)

Decidido rodar atrás do Cloudflare com proxy. Feito **certo** — senão a proteção é furada:

1. **Proxy ON + SSL/TLS = Full (strict).** Nunca "Flexible" (origem sem TLS = inseguro + loop de
   redirect).
2. **Cert na origem = Cloudflare Origin Certificate** (15 anos; SSL/TLS → Origin Server → Create
   Certificate). Emita para `cinetra.com.br` **e** `*.cinetra.com.br` (um cert cobre prod, hml e
   dok). Instale no Dokploy (Certificates). Os routers do
   [`compose.dokploy.yml`](../compose.dokploy.yml) usam **`tls=true`** (sem `certresolver`) — o
   Traefik serve esse cert.
3. **Trancar a origem (crítico):** o firewall do VPS aceita `80`/`443` **só das faixas de IP do
   Cloudflare** — senão um atacante pula o Cloudflare batendo no IP cru e o WAF vira enfeite. Mais
   forte ainda: **Authenticated Origin Pulls** (mTLS Cloudflare↔origem).
4. **IP real do cliente:** `ADDRESS_HEADER=CF-Connecting-IP` (o compose já traz) — o rate-limit da
   API vê o IP do usuário, não o do Cloudflare. (Opcional: `forwardedHeaders.trustedIPs` com as
   faixas do Cloudflare no entrypoint do Traefik.)
5. **Painel `dok`:** atrás do **Cloudflare Access (Zero Trust)** — portão de login no edge (e-mail/
   SSO) antes de tocar o VPS; grátis até 50 usuários. Substitui a allowlist de IP no Traefik. O
   painel fica no domínio `dok.cinetra.com.br` (servido pelo mesmo cert), e a `3000` continua
   fechada (§3).

   > **E o webhook de deploy mora nesse mesmo host.** O Access **não recusa** quem chega sem
   > credencial: ele **redireciona para o login (302)** — o que faz um `curl -fsS` do CI sair com
   > código 0 sem ter disparado nada. A saída é um **service token** do Access num app com path
   > mais específico; o passo a passo, e os dois modos de falha que ele produz, estão no
   > [doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md).
6. **Dois detalhes que mordem:**
   - **`/webhooks`:** regra de WAF **skip** para o path `/webhooks` — senão o Cloudflare desafia o
     POST do Resend e o webhook não chega.
   - **WebSocket:** funciona proxied — o heartbeat do Phoenix mantém a conexão viva dentro do
     timeout de 100s do Cloudflare.

> **Ordem de emissão do cert:** com o Origin Certificate você **não** depende do desafio HTTP-01,
> então pode subir com o proxy já ligado. (Se um dia usar Let's Encrypt na origem atrás de proxy,
> seria via **DNS-01** — o HTTP-01 quebra na renovação com o proxy permanente.)

## 6. Dokploy: os dois stacks

1. Instale o Dokploy no A1 (instalador oficial). Ele sobe Traefik + painel; crie o admin (§3).
2. Conecte o GitHub (GitHub App) ao projeto.
3. Crie **dois serviços do tipo Compose**, ambos apontando para
   [`compose.dokploy.yml`](../compose.dokploy.yml), um na branch `main` (prod) e outro na
   `develop` (hml).
4. Em cada um, preencha a aba **Environment** com os valores do §7 (o compose só referencia
   `${VAR}` — nada de segredo no arquivo). `STACK`/`WEB_HOST`/`IMAGE_TAG` diferem por ambiente
   (`STACK` mantém os nomes de router do Traefik únicos entre os dois stacks).
5. Habilite o auto-deploy por webhook em cada branch.

> **O Dokploy não builda mais nada** (R-M4, [doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md)).
> As imagens são construídas e publicadas pelo CI no GHCR; o `compose.dokploy.yml` só as consome,
> com `pull_policy: always` em cada serviço. O que o servidor faz no deploy é `pull` + trocar
> container — não `mix release` nem `vite build` disputando os 2 vCPU com o produto (D-21).

### 6.1 O terceiro stack: observabilidade (`obs.cinetra.com.br`)

Um **terceiro** serviço Compose no mesmo servidor, apontando para
[`deploy/observability/compose.obs.yml`](../deploy/observability/compose.obs.yml) (branch `main`).
É um projeto Dokploy separado — `cinetra-obs` — de propósito: o Alloy coleta por allowlist de
projeto (`OBS_PROJETOS`), e é o nome distinto que o mantém fora da própria coleta. **Sobe por
último**: ele entra nas redes externas dos stacks do app, que precisam existir antes.

**Pré-requisitos (nesta ordem):**

1. **prod no ar.** O obs entra em `cinetra-prod_data` (Grafana → Postgres), `cinetra-prod_app`
   (Alloy ← spans) e `dokploy-network` (Prometheus → api, Traefik → Grafana). Nome errado de rede
   **impede o stack de subir** (o compose valida rede externa antes de criar container) — confira:
   ```bash
   docker network ls | grep -E 'cinetra-prod_(data|app)|dokploy-network'
   docker network inspect dokploy-network --format '{{range .Containers}}{{.Name}} {{end}}'
   ```
2. **O role de leitura do banco.** No **Environment do app (prod)**, setar `DATABASE_METRICS_PASSWORD`
   e **redeployar o app** — `Api.Release.setup_metrics_role/0` cria o `cinetra_metrics` (só `SELECT`
   nas views `metrics_*`) no boot. Sem isso os painéis de banco do Grafana dão *permission denied*.
   O `METRICS_DB_PASSWORD` do obs (abaixo) tem de ser **o mesmo valor**.
3. **DNS + Access.** Registro **A `obs` proxied** (laranja), como `cinetra`/`hml`/`dok` (§5). Ponha
   `obs.cinetra.com.br` atrás do **Cloudflare Access** (§5.1), igual ao `dok` — inclusive **desligar
   "authenticate via WARP"** no app do Access. O Grafana tem login próprio; o Access é a primeira
   porta, no edge.

**Environment do `cinetra-obs`** (aba do Dokploy — modelo em
[`deploy/observability/.env.exemplo`](../deploy/observability/.env.exemplo)):

| Var | Valor em prod | Observação |
|---|---|---|
| `OBS_ENV` | `prod` | rótulo em toda linha de log/métrica |
| `OBS_PROJETOS` | `cinetra-prod\|cinetra-hml` | allowlist ANCORADA; **nunca** inclua `cinetra-obs` |
| `GRAFANA_HOST` | `obs.cinetra.com.br` | host do router Traefik |
| `GRAFANA_ROOT_URL` | `https://obs.cinetra.com.br` | senão os links do Grafana quebram |
| `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` | próprios | `:?` — recusa subir sem |
| `GRAFANA_SECRET_KEY` | `openssl rand -hex 32` | `:?` — senão usa o default publicado (A3) |
| `METRICS_DB_HOST` | `cinetra-prod-db-1` | nome do **container** (há dois `db`) |
| `METRICS_DB_NAME` | `cinetra_prod` | |
| `METRICS_DB_PASSWORD` | = `DATABASE_METRICS_PASSWORD` do app | `:?` — o role que conecta |
| `APP_NETWORK` | `cinetra-prod_data` | rede do Postgres (Grafana) |
| `APP_NETWORK_OTLP` | `cinetra-prod_app` | rede dos spans (Alloy) |
| `METRICS_NETWORK` | `dokploy-network` | rede da api (Prometheus) **e** do Traefik (edge) |
| `PROMETHEUS_TARGETS` | `./targets/api-prod.yml` | mira `api-prod`/`api-hml` (alias único, §6) |

O Grafana **não publica porta em 0.0.0.0** — o compose prende em `127.0.0.1` e o acesso vem pelo
Traefik (labels no serviço, `tls=true` com o Origin Certificate, §5.1). Não use "Add Domain" da UI.

**Deploy e verificação:**

```bash
# na VM, dentro de deploy/observability/
GRAFANA=https://obs.cinetra.com.br GRAFANA_AUTH=admin:<senha> ./verificar.sh
```

O `verificar.sh` prova as três fontes (log/métrica/trace), os dashboards provisionados, e que
nenhuma porta interna vazou — inclusive a §13, que confirma o Grafana **fora** de 0.0.0.0.

> **RAM (KVM2, 8GB).** O obs declara ~4GB de teto; com prod + hml + Dokploy cabe **parado**, mas a
> folga some num pico (consulta de 30 dias no Loki durante um build de deploy). Rodando assim por
> decisão — o próprio obs (painéis do node-exporter + alerta de OOM) é o que avisa a hora de subir
> para **KVM4 (16GB)**. Ver [`docs/87`](87-servidor-hostinger-riscos-e-cuidados.md).

## 7. Segredos e env (por ambiente)

**Gerar novos para produção** (não reaproveitar dev): `SECRET_KEY_BASE` e `TOKEN_SIGNING_SECRET`
(`mix phx.gen.secret`), `POSTGRES_PASSWORD`, `DATABASE_APP_PASSWORD`. **Rotacionar** as
credenciais que já circularam no `.env` do working tree (R2 e o client secret do Google) ao montar
o pipeline. **HML tem os seus próprios** — nunca compartilhe segredo/banco/bucket com prod.

| Var | Onde | Observação |
|---|---|---|
| `IMAGE_TAG` | env | **obrigatória** — `main` no stack de prod, `develop` no de HML. É a tag que o CI publica no GHCR ([doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md)). Sem ela o stack **recusa subir**, de propósito: um default faria HML servir a imagem de produção, e a imagem do BFF é atada ao ambiente. Para rollback, ponha a tag imutável `sha-<12 primeiros do commit>` — e lembre de devolver a `main`/`develop` depois |
| `IMAGE_REGISTRY` | env | opcional; só para apontar para outro registro. Default `ghcr.io/transmuta` |
| `STACK` | env | `prod` ou `hml` (nomes únicos no Traefik) |
| `WEB_HOST` | env | domínio único do ambiente (não há `API_HOST` — BFF-only). **Continua necessária** mesmo com o build no CI: o Traefik roteia por ela e o `API_PUBLIC_ORIGIN` de runtime sai dela — é ela que a guarda de boot compara com a CSP assada na imagem |
| `POSTGRES_PASSWORD` / `POSTGRES_DB` | env | banco do ambiente |
| `DATABASE_APP_USER` / `DATABASE_APP_PASSWORD` | env | role restrito `cinetra_app` |
| `SECRET_KEY_BASE` / `TOKEN_SIGNING_SECRET` | env | `raise` no boot se faltar |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | env | client do ambiente |
| `R2_ACCOUNT_ID` / `R2_BUCKET` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | env | bucket do ambiente |
| `RESEND_API_KEY` | env | **sem ela nenhum e-mail sai, nem o magic link** — o mailer cai no adapter `Local` e ninguém entra no sistema |
| `RESEND_WEBHOOK_SECRET` | env | o *Signing Secret* (`whsec_…`) do endpoint cadastrado no Resend; sem ela o webhook responde **401 em todo evento** (fail closed) |
| `MAIL_FROM` / `MAIL_FROM_NAME` | env | remetente de **domínio verificado**, um por ambiente — HML nunca do domínio de prod, senão um teste queima a reputação de envio da produção |
| `WHATSAPP_HABILITADO` / `ZERNIO_*` | env | fase 2 (doc 65). Default vazio = canal desligado; ligar é preencher aqui, sem deploy |

> **As três primeiras usam `${VAR:?mensagem}` no compose, de propósito: o `up` aborta se faltarem.**
> Nem `${VAR:-}` nem `${VAR}` seco serviriam — os dois substituem por string vazia e seguem (o
> segundo só acrescenta um warning no log do deploy), e o resultado é um sistema que sobe perfeito,
> com a suíte verde, e no qual o e-mail simplesmente não sai. Esse foi o modo de falha que a
> ausência delas no `compose.dokploy.yml` criou até 2026-07-30. É o mesmo fail-fast que
> `SECRET_KEY_BASE` tem de graça pelo `raise` do `runtime.exs`. Cobertas por `Api.DeployEnvTest`,
> que cobra do compose toda env de comunicação que o `runtime.exs` lê.
>
> **Preencher a env não basta:** o endpoint precisa existir no painel do Resend, apontando para
> `https://<WEB_HOST>/webhooks/resend` (o Traefik já roteia `/webhooks` para a API — §3.1), e é de
> lá que sai o `whsec_…`. Sem cadastrá-lo, nenhum evento de entrega chega e a timeline de
> comunicação fica parada em "enviado" sem erro em lugar nenhum.

`API_URL`, `API_PUBLIC_ORIGIN`, `ORIGIN`, `PHX_HOST`, `WEB_APP_URL`, `GOOGLE_REDIRECT_URI` e o
`ADDRESS_HEADER=CF-Connecting-IP` (atrás do Cloudflare, §5.1) já saem prontos do
`compose.dokploy.yml` a partir de `WEB_HOST` (domínio único) — não precisa setar à mão.

> **`API_PUBLIC_ORIGIN` é build-arg E runtime, e têm de bater.** A CSP (`connect-src`) é assada no
> **build** (`kit.csp`); a guarda de boot `conferirOrigem` (web/src/hooks.server.ts) **derruba o
> container** se o valor de runtime divergir. No BFF-only, `API_PUBLIC_ORIGIN = https://<WEB_HOST>`
> (o socket é `wss://<WEB_HOST>/socket`); o compose deriva os dois do mesmo `${WEB_HOST}`, então não
> divergem — mas editar um sem o outro derruba o web (sintoma só no console do browser).

> **Google OAuth:** cadastre `https://<WEB_HOST>/auth` como redirect URI no console do Google —
> **do WEB, terminando em `/auth`** (o AshAuthentication anexa `/user/google/callback`). Um client
> para prod, outro para HML. Cadastrar a URL da API quebra o login com um erro que só aparece no
> console do Google.

## 8. Migrations em produção

Quem toca o schema é **só** o serviço `migrate` (`Api.Release.setup()` → migrations como owner via
`DATABASE_ADMIN_URL` + cria o role restrito). O **build não toca o banco**; o **web nunca toca o
banco** (é BFF, fala com a api por HTTP). A migration roda **automática** no deploy — o que dá
segurança não é rodar na mão, é a disciplina abaixo.

**Regra de ouro (expand-contract):** nunca faça uma mudança de schema que quebre a versão do app
que está rodando **agora**. O deploy não é atômico — há uma janela em que o schema é N+1 e algum
container ainda é N. Mudança **aditiva** (coluna/tabela/índice novos) é sempre segura (o app antigo
ignora o que não conhece). Mudança **destrutiva** vira 2–3 deploys.

**Lista perigosa** (quando o `mix ash.codegen` gerar uma destas, trate o deploy como especial e
fatie em expand-contract — desde a remoção do backup do repositório (§13), o expand-contract é a
**única** rede que resta aqui, porque não há mais dump automático antes do `migrate`):

- remover/renomear atributo; `allow_nil? false` novo num atributo existente; trocar tipo;
- adicionar `identity`/unique numa tabela que já tem dado;
- índice `CONCURRENTLY` (regra [`migrations.md`](../.claude/rules/migrations.md)) — perde a
  transação de DDL do Ecto; falha no meio deixa índice inválido.

O Postgres tem DDL transacional e o Ecto envolve cada migration numa transação, então uma migration
que falha **desfaz sozinha** — exceto num **lote** (as anteriores já commitaram) e nas `CONCURRENTLY`.

Renomear `col_a → col_b` em expand-contract: **(1)** adiciona `col_b`, mantém `col_a`, backfill;
**(2)** app novo lê/escreve só `col_b` (rollback ainda seguro, `col_a` existe); **(3)** dropa
`col_a` quando não houver mais volta.

## 9. TLS, HSTS, CSP

- **TLS**: atrás do Cloudflare (Full strict), a origem serve um **Cloudflare Origin Certificate**
  instalado no Dokploy; os routers do compose usam **`tls=true`** (sem `certresolver`). O redirect
  http→https fica no Cloudflare (Always Use HTTPS). Ver §5.1.
- **HSTS**: continua saindo do **BFF** (`web/src/hooks.server.ts`, quando o request é https),
  **não** do Traefik. Depende de `ORIGIN=https://...` correto (o compose garante).
- **CSP**: build-time (§7). Confira no deploy que `connect-src` traz o par `https://`/`wss://` do
  **domínio (`WEB_HOST`)** e **não** `localhost`.
- **`force_ssl` continua ausente do `prod.exs`** de propósito — a API é chamada por http interno
  pelo BFF; ligá-lo quebraria isso.

## 10. Riscos do dia do deploy e mitigação

| # | Risco | Mitigação |
|---|---|---|
| 1 | **Migration destrutiva/trava** — único caso onde rollback da imagem não salva (schema é catraca de sentido único; o perigo é **dado perdido**, não downtime) | HML rodou a mesma migration antes · expand-contract (§8) · snapshot mais recente do painel, com a idade que ele tiver (§13) |
| 2 | **Drift develop→main** — HML validou um commit e a main subiu outro | promova o **commit exato** validado no HML |
| 3 | **Build ARM / guarda de boot / env faltando** — furos que o CI x86 não vê | HML no mesmo ARM/compose quebra primeiro · o **container antigo segue servindo** se o novo não passa no healthcheck |
| 4 | **Blip no `migrate`** (recreate do Compose) | expand-contract mantém o app antigo funcional sobre o schema migrado |
| 5 | **Disco/memória no A1** (prod + HML juntos dobram o churn) | `docker system prune` agendado + alerta ~75% · limites de memória por container · deploy de HML fora de pico |
| 6 | **Cruzamento prod↔HML (LGPD)** | HML com banco/segredos/bucket próprios · dado **sintético** (`Ash.Generator`), nunca paciente real |
| 7 | **Primeira vez**: DNS/TLS/redirect do Google | checklist do §Verificação; uma vez feito, não volta |

## 11. O ritual do dia do deploy

1. **Antes:** PR verde no CI · a mudança já roda **saudável no HML** (via develop). Se a migration
   estiver na lista perigosa do §8, dispare um snapshot pelo painel antes — ele não é mais
   automático (§13).
2. **Deploy:** merge na `main` → CI verde → webhook → Dokploy builda → `migrate` → swap.
3. **Depois (smoke, ~2 min):** §Verificação, com o **botão de rollback à mão**.

## 12. Verificação (pós-deploy)

- **CSP:** `curl -sI https://<WEB_HOST>` → `content-security-policy` com `connect-src` trazendo o
  par `https://`/`wss://` do **API_HOST** e **sem** `localhost`.
- **HSTS:** `curl -sI https://<WEB_HOST> | grep -i strict-transport` → `max-age=63072000;
  includeSubDomains` (sai do BFF).
- **WebSocket:** abrir a agenda e ver o socket conectar (tempo real).
- **OAuth:** um login por Google completa (redirect URI do ambiente cadastrada).
- **Login/magic link:** um login completa.

## 13. Backup e recriar a VM do zero (máquina descartável)

> **Estado: fora do repositório, por decisão de 2026-08-05** (ver
> [`00-decisoes.md`](00-decisoes.md)). O backup era nosso — um `pg_dump` horário cifrado com `age`,
> em `deploy/backup/`, com gate fail-closed antes do `migrate`. Foi **removido inteiro**: o
> diretório, a imagem no CI, os dois serviços do compose, as envs
> `BACKUP_*` e o heartbeat do cron. Quem cobre o dado agora são **dois mecanismos de painel**, e
> nenhum deles passa por este repositório.

**O que cobre o dado hoje:**

- **Snapshot da VPS (Hostinger).** Recupera a **máquina** — disco inteiro, incluindo o volume
  `pgdata`. Backup semanal automático (diário opcional), até 4 retidos; o snapshot manual é 1 por
  vez e expira em 1 dia. Ver [doc 87 §1](87-servidor-hostinger-riscos-e-cuidados.md) para os
  limites medidos, inclusive o de segurança: o hPanel que restaura é um caminho root-equivalente.
- **Snapshot de projeto do Dokploy → R2.** Recupera o **stack** (volumes e configuração do
  projeto), enviado para um bucket R2. Configurado no painel do Dokploy, não no compose.

**O que essa troca custou, dito na cara** — três propriedades saíram junto com o script, e nenhuma
delas volta por acaso:

1. **O gate fail-closed antes do `migrate` não existe mais.** O `migrate` agora depende só do `db`
   saudável. Migration destrutiva deixou de ter uma rede de segurança automática: o que sobra é a
   disciplina de expand-contract do §8 e o snapshot mais recente, seja lá qual for a idade dele.
2. **O RPO passou a ser o do painel.** Era ≤ 1h por construção, escrita no compose e verificável
   por leitura. Agora é o que estiver agendado na Hostinger e no Dokploy — se ninguém abrir os dois
   painéis para conferir, ninguém sabe qual é.
3. **A cifra `age` acabou.** O dump saía do servidor já cifrado com uma chave cuja privada vivia
   offline. Snapshot de painel é cifrado (ou não) segundo o que o provedor faz — e o conteúdo é o
   mesmo: nome, CPF, telefone e evolução clínica de todo paciente. **Confirmar a cifra em repouso
   nos dois destinos é item de LGPD**, não de infraestrutura.

**Ainda vale, e agora vale mais:** *backup não testado não é backup*. Restaure para uma máquina ou
banco **separado** e confira que as linhas estão lá. Sem `restore.sh` no repositório, esse ensaio é
100% manual, pelo painel — o que o torna mais fácil de adiar e mais caro de descobrir tarde.

**Recriar a VM:**

- **Env vars anotadas** (fora da VM). Com o snapshot + as envs, recriar a máquina é rotina de
  ~30 min.
- **`apt`**: `unattended-upgrades` só para *security updates*; **`apt-mark hold`** no Docker para
  ele não subir sozinho num deploy inesperado; upgrade de Docker/kernel só em janela planejada,
  esperando reboot. (A lição do "`apt upgrade` matou tudo" é de qualquer VPS, não de um provedor.)

## 14. Pendências / follow-ups

- **Webhook de deploy no `ci.yml`** — o job `deploy` já existe (esqueletado, pula se o secret
  faltar). Falta **criar os webhooks no painel do Dokploy** e colar as URLs nos GitHub Secrets
  `DOKPLOY_DEPLOY_WEBHOOK_PROD`/`_HML`. **Atravessar o Cloudflare Access** é parte disto e tem
  runbook próprio: [doc 105](105-imagem-no-ci-e-webhook-atras-do-access.md) §2.
- **Preview por PR** — decidido **não** fazer agora (HML no `develop` cobre a revisão). Se um dia
  for necessário, os três pré-requisitos na stack são: CSP templatizada pelo domínio do preview,
  banco efêmero por PR e auth por **magic link** (o Google não aceita redirect URI wildcard).
  Registrado em [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md).
- **API BFF-only — IMPLEMENTADO** (path-routing no Traefik, §3.1). Um domínio único (`WEB_HOST`);
  só `/socket` e `/webhooks` vão para a API, o resto para o web; o subdomínio `api.*` sumiu.
  Rastreado no código que só essas duas rotas são de fato públicas (OAuth, magic-link e a resposta
  do paciente em `/confirmar` passam todas pelo BFF). **Falta provar o WS ao vivo:** localmente com
  [`compose.bff-test.yml`](../compose.bff-test.yml) (`docker compose -p bff-test -f
  compose.bff-test.yml up --build` → abrir `http://cinetra.localhost`, ver o socket conectar em
  `ws://cinetra.localhost/socket`), e no primeiro deploy do HML (`wss://<WEB_HOST>/socket`).
  Descartado o túnel do WS pelo Node (adapter-node não proxia WS nativamente).
- **Observabilidade** — [`05`](05-observabilidade-e-producao.md) (OTel) segue como intenção; casar
  com o A1.
- **Confirmar arm64 cedo** — o scan de deps (2026-07-28) não achou nada precompilado nem x86-only;
  o único código nativo é `picosat_elixir` (+ `bcrypt_elixir` transitivo), NIFs em C que compilam do
  source (o `Dockerfile.prod` já tem `build-essential`) → arm64 nativo no A1. Risco baixo; o primeiro
  build no HML é a confirmação.
