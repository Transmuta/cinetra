# 17 — Deploy no Fly.io

> **⚠️ DOCUMENTO HISTÓRICO — a produção NÃO roda mais no Fly.io.**
>
> Substituído pela [ADR-023](00-decisoes.md): produção e homologação rodam num **Dokploy sobre VPS
> Hostinger KVM 2**, com um único domínio e topologia BFF-only. O runbook em vigor é o
> [doc 59](59-deploy-dokploy-oci.md); os riscos e cuidados da máquina atual estão no
> [doc 87](87-servidor-hostinger-riscos-e-cuidados.md).
>
> Fica versionado porque descreve decisões que ainda ecoam no código — `force_ssl` fora do
> `prod.exs`, a forma dos `Dockerfile.prod`, o `Api.Release`. **Não siga nenhum passo daqui.**
> (R-B10, onda 5 do doc 102.)

Produção do Movimento no [Fly.io](https://fly.io): **dois apps** (a API e o web BFF) + um
Postgres. O TLS e o redirect http→https são da **edge do Fly** (`force_https` no `fly.toml`) —
por isso o `force_ssl` foi tirado do `prod.exs` (a API também é chamada internamente por http).
Artefatos: `api/Dockerfile.prod`, `web/Dockerfile.prod`, `api/fly.toml`, `web/fly.toml`,
`Api.Release`.

> **Correção (Onda 5, H59): o HSTS NÃO é da edge.** Este doc afirmava que sim, e o `prod.exs`
> repetia. O `force_https` do Fly faz o **redirect**; o proxy dele não emite
> `Strict-Transport-Security` (o header que existe em `*.fly.dev` é do domínio compartilhado e
> não acompanha domínio próprio). Quem o emite é o BFF, em `web/src/hooks.server.ts`, quando o
> request é https. O redirect escondia o sintoma: tudo parecia certo no browser.

## Arquitetura

```
                     (TLS + http→https na edge do Fly; HSTS sai do BFF)
  browser ──https──> cinetra-web.fly.dev  ──6PN──> cinetra-api.internal:4000
                          (SvelteKit BFF)      (http privado, não passa pela edge)
  browser ──wss────> cinetra-api.fly.dev   (SÓ o WebSocket)
```

- **web** fala com a **api** pela rede privada 6PN (`http://cinetra-api.internal:4000`) — nunca
  pela internet. Isso é o `API_URL`.
- O browser só toca a **api** direto num caso: o **WebSocket** (`API_PUBLIC_ORIGIN`). O resto é
  sempre browser → web (BFF) → api — **inclusive o OAuth do Google**: o callback do Google é uma
  rota do web (`/auth/user/google/callback`), que repassa o `code` à API server-to-server e
  re-emite a sessão no domínio do web. Este doc dizia o contrário; ver o `GOOGLE_REDIRECT_URI`
  abaixo.

## Modelo de dois roles do banco (RLS, ADR-018)

A RLS exige que o **app** conecte como um role **NOBYPASSRLS**. Migrations/DDL precisam de um
role **owner**. No Fly o `release_command` e o app rodam com os mesmos secrets, então separamos
por variável:

- `DATABASE_ADMIN_URL` — owner. Usado **só** pelo `release_command`
  (`Api.Release.setup()` → migrations + cria o role restrito).
- `DATABASE_URL` — restrito (`cinetra_app`). Usado pelo app em runtime.

O `Api.Release.setup/0` (roda antes de trocar as máquinas) cria o role restrito com
`DATABASE_APP_USER`/`DATABASE_APP_PASSWORD`; o app sobe já sujeito à RLS.

## Secrets (por `fly secrets set`, no app da API)

```bash
fly secrets set \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  TOKEN_SIGNING_SECRET="$(mix phx.gen.secret)" \
  DATABASE_ADMIN_URL="ecto://<owner>:<senha>@<host>/<db>" \
  DATABASE_URL="ecto://cinetra_app:<senha-app>@<host>/<db>" \
  DATABASE_APP_USER="cinetra_app" \
  DATABASE_APP_PASSWORD="<senha-app>" \
  PHX_HOST="cinetra-api.fly.dev" \
  WEB_APP_URL="https://cinetra-web.fly.dev" \
  GOOGLE_CLIENT_ID="..." GOOGLE_CLIENT_SECRET="..." \
  GOOGLE_REDIRECT_URI="https://cinetra-web.fly.dev/auth" \
  --app cinetra-api
```

> O `DATABASE_URL` (restrito) aponta para um role que só passa a existir depois do primeiro
> `release_command`. Tudo bem: o `release_command` usa a `DATABASE_ADMIN_URL` e roda **antes**
> de o app subir. Garanta que o owner do `DATABASE_ADMIN_URL` pode `CREATE ROLE` e fazer DDL.

> **O `GOOGLE_REDIRECT_URI` aponta para o WEB, não para a API** — e o valor termina em `/auth`,
> sem `/user/google/callback`: a estratégia do AshAuthentication completa o caminho, e a rota
> real que o Google chama é `<base>/user/google/callback`, servida pelo SvelteKit. Este doc
> mandava cadastrar a URL da API até a Onda 5; seguir aquilo quebrava o login por Google em
> produção com um erro que só aparece no console do Google, não nos logs da aplicação.

O **web** não tem secrets sensíveis — `API_URL`, `API_PUBLIC_ORIGIN` e `ORIGIN` já estão no
`web/fly.toml` (`[env]`). Ajuste-os se usar domínio próprio.

> **`API_PUBLIC_ORIGIN` aparece DUAS vezes no `web/fly.toml`**, em `[build.args]` e em `[env]`, e
> as duas precisam bater. A CSP (`connect-src`) é fixada no **build** (`kit.csp`), então o valor
> de runtime chega tarde para ela; o de runtime é o que a página usa para montar a URL do socket.
> Divergir bloqueia o WebSocket da agenda pela própria CSP — sintoma só visível no console do
> browser.

## Passos (primeira vez)

```bash
# 1. Apps (ajuste nomes/região no fly.toml antes)
fly apps create cinetra-api
fly apps create cinetra-web

# 2. Postgres (Fly PG ou externo) e as URLs owner/app nos secrets acima
fly postgres create --name movimento-db --region gru   # ou um Postgres gerenciado externo

# 3. Secrets da API (bloco acima)

# 4. Deploy — cada app do seu diretório
cd api && fly deploy && cd ..
cd web && fly deploy && cd ..
```

Deploys seguintes: `fly deploy` em cada diretório (o `release_command` reaplica migrations).

## Verificar antes / depois

- **Local, sem Fly:** `docker compose -p cinetra-smoke -f compose.prod.yml up --build` sobe as
  **mesmas imagens de prod** (release + role restrito + web buildado) em `localhost:4020` /
  `localhost:3020`. Prova que compila, migra e serve.
- **CSP:** validada no build (`svelte.config.js` `kit.csp`, `mode: auto`) — o header
  `content-security-policy` sai com `script-src 'self' 'nonce-…'`. Confira que o `connect-src`
  traz o par `https://`/`wss://` do **seu** host de API e **não** `localhost` (S3, Onda 5): se
  trouxer, o build recebeu o `API_PUBLIC_ORIGIN` errado ou não recebeu nenhum.
- **HSTS:** `curl -sI https://<seu-web> | grep -i strict-transport` tem de responder
  `max-age=63072000; includeSubDomains`. Ele sai do BFF, não da edge (H59).
- **Google OAuth:** cadastre o `GOOGLE_REDIRECT_URI` acima no console do Google — o do **web**.
- **Bind IPv6:** a API já escuta em `::` (runtime.exs). Se o web (adapter-node) ficar
  inalcançável no Fly, setar `HOST="::"` no `web/fly.toml`.
- **Domínio próprio:** `fly certs add ...` e atualize `PHX_HOST`/`WEB_APP_URL`/`ORIGIN`/
  `API_PUBLIC_ORIGIN`/`GOOGLE_REDIRECT_URI`.
