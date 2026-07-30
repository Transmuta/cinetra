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
> Numa VPS o SO/rede/backup **são nossos**. O deploy do app fica fácil; firewall, patch, backup e
> o socket do Docker passam a ser responsabilidade nossa. A regra que sustenta isso é **máquina
> descartável**: estado (banco) e config (env) moram fora da VM, e recriar a máquina é rotina, não
> catástrofe (ver §Backup e recriar a VM).

---

## 1. O modelo: dois ambientes, um servidor

```
   PR ──> CI (portão: mix coveralls + job api-rls + svelte-check/coverage) — em todo PR e push
   │
   ├─ push em DEVELOP ─> webhook ─> Dokploy builda ─> stack HML
   │                                  hml.cinetra.com.br (domínio único; /socket e /webhooks -> API)
   │                                  banco próprio · segredos próprios · bucket R2 próprio · dado SINTÉTICO
   │
   └─ push em MAIN ────> webhook ─> Dokploy builda ─> stack PROD
                                      cinetra.com.br (domínio único; /socket e /webhooks -> API)
                                      banco de produção · segredos de produção
```

Os **dois stacks rodam no mesmo A1**, a partir do **mesmo** [`compose.dokploy.yml`](../compose.dokploy.yml).
HML é **idêntico** a prod (mesmo ARM, mesma imagem, mesmo passo de `migrate`); só muda o que é
injetado por env:

| | HML (branch `develop`) | PROD (branch `main`) |
|---|---|---|
| `STACK` | `hml` | `prod` |
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
- **Dokploy** = só o **deploy**: clona a branch, builda a imagem arm64 no A1 e sobe. Disparado
  por **webhook**, no fim do workflow, **só quando o CI fica verde**.

> **Não empurrar testes para dentro do Dokploy.** Rodar a suíte no `docker build` perde o job
> `api-rls` (que precisa de um Postgres com os dois roles), perde os gates de cobertura, roda na
> VM de produção competindo com o app, e só rodaria no deploy — tarde demais, depois do merge. O
> CI no GitHub roda **em PR**, antes do merge, que é onde o erro tem de ser pego.

O job **`deploy`** já está no `ci.yml`: `needs: [api, api-rls, web]` (só roda depois dos gates),
`if` só em push para `main` (prod) ou `develop` (hml), nunca em PR. Faz `curl -X POST` no webhook do
ambiente, cuja URL vem dos secrets `DOKPLOY_DEPLOY_WEBHOOK_PROD`/`_HML`. **Enquanto o Dokploy não
existir, o secret está ausente e o passo é pulado sem falhar o CI** — falta só criar os webhooks no
painel e colar as URLs nos GitHub Secrets. O gatilho de push do workflow também passou a incluir
`develop` (era só `main`), para o fluxo HML.

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
   `${VAR}` — nada de segredo no arquivo). `STACK`/`WEB_HOST` diferem por ambiente (`STACK` mantém
   os nomes de router do Traefik únicos entre os dois stacks).
5. Habilite o auto-deploy por webhook em cada branch.

## 7. Segredos e env (por ambiente)

**Gerar novos para produção** (não reaproveitar dev): `SECRET_KEY_BASE` e `TOKEN_SIGNING_SECRET`
(`mix phx.gen.secret`), `POSTGRES_PASSWORD`, `DATABASE_APP_PASSWORD`. **Rotacionar** as
credenciais que já circularam no `.env` do working tree (R2 e o client secret do Google) ao montar
o pipeline. **HML tem os seus próprios** — nunca compartilhe segredo/banco/bucket com prod.

| Var | Onde | Observação |
|---|---|---|
| `STACK` | env | `prod` ou `hml` (nomes únicos no Traefik) |
| `WEB_HOST` | env | domínio único do ambiente (não há `API_HOST` — BFF-only) |
| `POSTGRES_PASSWORD` / `POSTGRES_DB` | env | banco do ambiente |
| `DATABASE_APP_USER` / `DATABASE_APP_PASSWORD` | env | role restrito `cinetra_app` |
| `SECRET_KEY_BASE` / `TOKEN_SIGNING_SECRET` | env | `raise` no boot se faltar |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | env | client do ambiente |
| `R2_ACCOUNT_ID` / `R2_BUCKET` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | env | bucket do ambiente |

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

**Lista perigosa** (quando o `mix ash.codegen` gerar uma destas, trate o deploy como especial —
`pg_dump` antes e fatie em expand-contract):

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
| 1 | **Migration destrutiva/trava** — único caso onde rollback da imagem não salva (schema é catraca de sentido único; o perigo é **dado perdido**, não downtime) | HML rodou a mesma migration antes · `pg_dump` de prod imediatamente antes · expand-contract (§8) |
| 2 | **Drift develop→main** — HML validou um commit e a main subiu outro | promova o **commit exato** validado no HML |
| 3 | **Build ARM / guarda de boot / env faltando** — furos que o CI x86 não vê | HML no mesmo ARM/compose quebra primeiro · o **container antigo segue servindo** se o novo não passa no healthcheck |
| 4 | **Blip no `migrate`** (recreate do Compose) | expand-contract mantém o app antigo funcional sobre o schema migrado · `pg_dump` |
| 5 | **Disco/memória no A1** (prod + HML juntos dobram o churn) | `docker system prune` agendado + alerta ~75% · limites de memória por container · deploy de HML fora de pico |
| 6 | **Cruzamento prod↔HML (LGPD)** | HML com banco/segredos/bucket próprios · dado **sintético** (`Ash.Generator`), nunca paciente real |
| 7 | **Primeira vez**: DNS/TLS/redirect do Google | checklist do §Verificação; uma vez feito, não volta |

## 11. O ritual do dia do deploy

1. **Antes:** PR verde no CI · a mudança já roda **saudável no HML** (via develop) · `pg_dump` de
   prod guardado.
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

> **Estado: implementado no compose, ainda não provisionado.** O backup vive em
> [`deploy/backup/`](../deploy/backup/) e roda em dois gatilhos (ver
> [`compose.dokploy.yml`](../compose.dokploy.yml)). Antes dele, o volume `pgdata` era a **cópia
> ÚNICA** do dado.

**Dois gatilhos** (mesmo script, [`deploy/backup/backup.sh`](../deploy/backup/backup.sh) — pg_dump
do owner, que captura tudo bypassando a RLS):

- **Pré-deploy (fail-closed):** o serviço `backup` roda UMA vez **antes** do `migrate`. Se o upload
  falhar, o deploy **para** — nunca se altera schema sem um backup fresco. É a rede de segurança do
  risco de migration (§10).
- **Agendado 1/1h:** o serviço `backup-cron` dorme 1h e roda (o pré-deploy cobre t=0).

**Frequência e retenção (por que 1h + escalonado):** restaurar backup *antigo* é raro — quase todo
restore usa o mais recente (recuperação de desastre). A **frequência** protege o **RPO**: 1/1h = no
máximo 1h de dado perdido, o que numa clínica que digita o dia todo vale a pena. A **retenção**
protege a **janela de detecção** (corrupção achada dias depois). Por isso, em vez de um número
único, **dois níveis**, self-contained via `rclone --min-age` (sem depender de lifecycle do R2):

- `hourly/` — granularidade fina, mantida **48h** (`BACKUP_HOURLY_RETENTION`).
- `daily/` — um objeto por dia, mantido **30 dias** (`BACKUP_DAILY_RETENTION`).

**Destino:** bucket R2 **privado, SEPARADO do de anexos**, com **credencial própria**
(`BACKUP_R2_ACCESS_KEY_ID`/`SECRET`) escopada só a esse bucket. Nunca o bucket dos pacientes.

**LGPD (o dump tem CPF):** cifra client-side com `age` — `BACKUP_AGE_RECIPIENT` é a chave
**pública** (o servidor cifra mas **não** decifra); a **privada fica offline**, usada só no restore.
Vazio desliga a cifra (ok em HML, dado sintético).

**Restore (pratique):**
[`deploy/backup/restore.sh <objeto> <db-alvo>`](../deploy/backup/restore.sh) baixa, decifra (com a
chave privada) e faz `pg_restore` num banco alvo. Restaure para um banco **separado** e extraia as
linhas — raramente se sobrescreve prod inteiro. **Backup não testado não é backup.**

**Monitorar a falha:** alerta se o `backup-cron` parar — backup que morre em silêncio só aparece no
desastre.

**Env do backup** (além dos do app, ver §7): `BACKUP_BUCKET`, `BACKUP_R2_ACCESS_KEY_ID`,
`BACKUP_R2_SECRET_ACCESS_KEY`, `BACKUP_AGE_RECIPIENT` (opcional), `BACKUP_HOURLY_RETENTION`
(default 48h), `BACKUP_DAILY_RETENTION` (default 30d). Reusa `R2_ACCOUNT_ID` (mesmo endpoint).

Considerar, no futuro, **Postgres gerenciado externo** para desacoplar o dado da VM descartável
(hoje: container no compose, aceito pelo custo zero).

**Recriar a VM:**

- **Env vars anotadas** (fora da VM). Com o dump do R2 + as envs, recriar o A1 é rotina de ~30 min.
- **`apt`**: `unattended-upgrades` só para *security updates*; **`apt-mark hold`** no Docker para
  ele não subir sozinho num deploy inesperado; upgrade de Docker/kernel só em janela planejada,
  esperando reboot. (A lição do "`apt upgrade` matou tudo" é de qualquer VPS, não de um provedor.)

## 14. Pendências / follow-ups

- **Webhook de deploy no `ci.yml`** — o job `deploy` já existe (esqueletado, pula se o secret
  faltar). Falta **criar os webhooks no painel do Dokploy** e colar as URLs nos GitHub Secrets
  `DOKPLOY_DEPLOY_WEBHOOK_PROD`/`_HML`.
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
