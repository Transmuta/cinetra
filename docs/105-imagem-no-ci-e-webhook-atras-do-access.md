# 105 — A imagem passa a nascer no CI, e o webhook aprende a atravessar o Cloudflare Access

Fecha as duas metades que a onda 3 do [doc 102](102-plano-de-acao-infraestrutura.md) deixou
declaradas como pendentes, e conserta um defeito que só existia porque as duas ainda não tinham se
encontrado:

- **R-M4, a segunda metade** — *"publicar num registry e mandar o Dokploy consumir […] precisa de
  credencial de registry e de reconfigurar o Dokploy — decisão que não é minha"*. Decidido: **GHCR**,
  por tag, com `pull_policy: always`. Isso também paga o [**D-21**](50-debitos-tecnicos.md) —
  o build sai da máquina de produção.
- **O 302 que passava por 200** — o passo que dispara o webhook do Dokploy usava `curl -fsS`, que
  falha em status **>= 400**. O painel está atrás do **Cloudflare Access** ([doc 59 §5.1](59-deploy-dokploy-oci.md)),
  e o Access **não recusa** quem chega sem credencial: **redireciona para a tela de login, com 302**.
  O curl saía com 0, o job ficava verde e o Dokploy nunca tinha recebido nada.

> **Resposta curta à pergunta que originou este doc:** sim, dá para automatizar o webhook com o
> Access na frente. Ele tem um caminho feito para máquina — **Service Token** —, e é o §2.

---

## 1. O que mudou no repositório

| Arquivo | Mudança |
|---|---|
| [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | o job `imagem` ganhou `packages: write`, um passo que decide **alvo do build**, login no GHCR e `push:` condicional; o job `deploy` passou a **ler o status** da resposta e a mandar o service token |
| [`compose.dokploy.yml`](../compose.dokploy.yml) | `build:` → `image:` + `pull_policy: always` nos serviços do produto; âncoras `x-imagem-*` no topo |
| [`api/test/api/ci_workflow_test.exs`](../api/test/api/ci_workflow_test.exs) | 4 testes novos (status do disparo, service token, publicação, cobrança das variáveis de CSP) |
| [`api/test/api/deploy_imagem_test.exs`](../api/test/api/deploy_imagem_test.exs) | novo — o compose consome em vez de construir, e a tag é obrigatória |

### O que o CI publica

Duas imagens, `linux/amd64` (runner e VPS são x86_64 desde o [ADR-023](00-decisoes.md) — sem QEMU,
sem cross-compile), cada uma com **duas tags**:

| Imagem | Consumida por | Tag móvel | Tag imutável |
|---|---|---|---|
| `ghcr.io/transmuta/cinetra-api` | `migrate` **e** `api` | `main` · `develop` | `sha-<12>` |
| `ghcr.io/transmuta/cinetra-web` | `web` | `main` · `develop` | `sha-<12>` |

> Eram **três** quando este doc foi escrito: havia `cinetra-backup`, consumida por `backup` e
> `backup-cron`. A [ADR-029](00-decisoes.md) tirou o backup do repositório no mesmo dia, e com ele
> a imagem, os dois serviços e o step de build.

A móvel é a do dia a dia; a imutável é o que torna **rollback** possível sem depender de o Git ter
voltado atrás (`IMAGE_TAG=sha-…` no Environment do stack → redeploy → **devolva a `main`/`develop`
depois**, senão os deploys seguintes deixam de mudar qualquer coisa).

`migrate` e `api` compartilham a **mesma âncora** de propósito: rodar a migration de uma versão e
servir outra é o modo de falha que o expand-contract do [doc 59 §8](59-deploy-dokploy-oci.md)
pressupõe impossível. Com âncora, isso é estrutural em vez de acidental.

### Três decisões que não são óbvias

**A imagem do BFF é atada ao ambiente, e isso mudou de dono.** A CSP é assada no **build**
(`kit.csp`), então `API_PUBLIC_ORIGIN` e `R2_ACCOUNT_ID` entram por `ARG` — o próprio
`web/Dockerfile.prod` diz isso por escrito. Enquanto o build acontecia no servidor, quem fornecia
os dois era o Environment do stack no Dokploy. **Movendo o build para o CI, a responsabilidade veio
junto**: agora saem das variáveis `WEB_HOST_PROD` / `WEB_HOST_HML` / `R2_ACCOUNT_ID` do
repositório. Se faltarem, o job **aborta** — porque o modo de falha delas não é deploy vermelho, é
`connect-src` errado, WebSocket bloqueado e upload de anexo recusado **no console do browser**, com
todo healthcheck verde.

Consequência prática a saber: `cinetra-web:main` **não serve** no stack de HML. Isso é fail-closed e
não silencioso — a guarda de boot (`web/src/lib/server/boot.ts` + `conferirOrigem` do `csp.js`)
derruba o container quando a CSP assada diverge do `API_PUBLIC_ORIGIN` de runtime.

**`pull_policy: always` não é detalhe.** Com tag móvel, a imagem nova tem o **mesmo nome** da que já
está no disco do servidor. Sem essa linha o `docker compose up` acha o nome localmente e **não baixa
nada**: o webhook é aceito, o stack "sobe", o `/api/ready` responde 200 — e o código é o do deploy
anterior. No `migrate`, é rodar a migration da versão errada.

**`IMAGE_TAG` não tem default.** Um default faria o stack de HML subir com a tag de produção no dia
em que alguém esquecesse a variável. `${IMAGE_TAG:?…}` faz o compose recusar com a mensagem —
medido: sem a variável, `docker compose config` para com
`required variable IMAGE_TAG is missing a value: defina IMAGE_TAG no Environment do stack`.

---

## 2. O Cloudflare Access e o webhook: o runbook

O Access tem duas formas de deixar uma máquina passar. **A primeira é a recomendada.**

### 2.1 Service Token (recomendado)

Um par ID/segredo que o Access aceita **no lugar de uma sessão de navegador**.

1. **Zero Trust → Access → Service Auth → Service Tokens → Create.** Nome sugerido:
   `github-actions-deploy`. Guarde **Client ID** (termina em `.access`) e **Client Secret** — o
   segredo aparece **uma vez só**.
2. **Crie um app do Access com path mais específico**, cobrindo só o webhook:
   `dok.cinetra.com.br/api/deploy` (confira o path exato na URL que o painel do Dokploy gera em
   *Deployments → Webhook*). O Access casa o app **mais específico** primeiro, então o app do painel
   inteiro continua com a política de humanos.
3. **Política desse app: ação `Service Auth`**, include → *Service Token* → o token do passo 1.
   `Service Auth` **não** aceita sessão de navegador, e é o que se quer: aquele path passa a ser só
   para máquina.
4. **Se houver WAF/Bot Fight Mode desafiando**, acrescente uma regra de **skip** para esse path — é
   o mesmo cuidado que o [doc 59 §5.1](59-deploy-dokploy-oci.md) já registra para `/webhooks`.
5. **GitHub → Settings → Secrets and variables → Actions → Secrets:** `CF_ACCESS_CLIENT_ID` e
   `CF_ACCESS_CLIENT_SECRET`.

**O que escopar o app pelo path compra:** o token do CI dispara deploy e **não** alcança o resto do
painel — que é root-equivalente na máquina ([doc 87 §3.1](87-servidor-hostinger-riscos-e-cuidados.md)).
Sem o path, o mesmo par de headers abriria a API inteira do Dokploy.

**O custo, e é real:** service token **expira** (o padrão é 1 ano). Expirado, o Access volta a
redirecionar — e é exatamente por isso que o passo agora lê o status e nomeia essa causa primeiro na
mensagem de erro. Anote a data de renovação junto das outras rotações.

### 2.2 Bypass no path (alternativa mais simples e mais fraca)

Política de **Bypass** para o path do webhook, e nenhum secret novo. O disparo passa sem headers —
o workflow segue funcionando, só emite um `::warning::` avisando que está dependendo disso.

O que se perde: o gatilho de deploy fica **aberto a quem descobrir a URL**. A única proteção passa a
ser o `refreshToken` embutido nela, que é um segredo em query string — vai para log de proxy, para
histórico de shell, e não rotaciona sozinho.

### 2.3 O que o passo faz agora, e como cada falha se lê

Provado com um `curl` de mentira encenando cada cenário:

| Resposta | Comportamento | Diagnóstico que a mensagem aponta |
|---|---|---|
| **2xx** | ✓ segue para a verificação do `/ready` | — |
| **3xx com `cloudflareaccess.com` no `location`** | ❌ falha | credencial: token ausente/expirado, política não é `Service Auth`, ou o app específico não cobre o path |
| **3xx sem isso** | ❌ falha, imprimindo `location:` **e o corpo** | a URL ou o payload; se o corpo diz `Branch Not Match`, é a branch (§2.4) |
| **403 com `cf-access-aud`** | ❌ falha | **o Access** recusou — o POST não chegou ao Dokploy. A mensagem lista as três causas e imprime o AUD do app que respondeu |
| **outros 4xx/5xx** | ❌ falha, imprimindo o corpo | o Dokploy recusou |
| **secret ausente** | pula sem falhar, e a verificação do `/ready` **também** pula | Dokploy ainda não provisionado |

Esse último item conserta um verde vazio de tabela: antes, sem webhook disparado, o passo de
verificação ainda batia no `/ready` e passava — medindo apenas que o ambiente **anterior** continuava
no ar.

**Mutação, para não ficar como prosa:** o passo antigo (`curl -fsS -X POST`) contra o mesmo 302 do
Access sai com **código 0**. É o bug, reproduzido.

### 2.4 O primeiro deploy real, e as duas coisas que ninguém tinha medido

Tudo acima foi escrito **antes** de o pipeline rodar de verdade. Quando rodou, falhou — e por dois
motivos que a encenação com `curl` de mentira não tinha como produzir. Ficam aqui porque custaram
três rodadas de investigação **no lugar errado**.

**1. O Dokploy quer o payload de push, não um gatilho vazio.** O endpoint compara o `ref` do corpo
com a branch configurada no stack. Medido ao vivo contra o webhook de HML, em 2026-08-05:

| Requisição | Resposta |
|---|---|
| `POST` sem corpo | `301` · `{"message":"Branch Not Match"}` (30 bytes) |
| `POST` + `X-GitHub-Event: push` + `{"ref":"refs/heads/develop"}` | `200` · `{"message":"Compose deployed successfully"}` |

O passo agora manda `Content-Type: application/json`, `X-GitHub-Event: push` e `{"ref":"$REF"}` —
o **REF do evento**, não uma constante. Isso é de graça e vira gate: se a branch do stack divergir
da que disparou o CI, o Dokploy recusa em vez de implantar a versão errada.

**2. O `.access` do Client ID, que só apareceu no teste manual.** O Client ID de um service token
termina em `.access`. Reproduzido lado a lado contra o servidor real, mesma URL e mesmo secret:

| Client ID | Resposta |
|---|---|
| `420…6ee` | `403` do Cloudflare Access |
| `420…6ee.access` | passa o Access, chega no Dokploy |

**A lição, que é maior que os dois defeitos.** O 403 existia **só no teste manual** — no CI o Access
sempre passou. A prova estava no primeiro erro o tempo todo: `content-length: 30`, o tamanho exato
de `{"message":"Branch Not Match"}`. Perseguimos o Access por três rodadas, mexendo em políticas do
Zero Trust que não tinham problema nenhum, porque o diagnóstico do passo escondia o corpo da
resposta atrás de um `head -c 400` nos **cabeçalhos**.

Quando o teste manual e o automatizado divergem, **a diferença está no teste, não no sistema** — e
a primeira coisa a fazer é igualar os dois, não sair mexendo no sistema.

---

## 3. O que falta fazer fora do repositório

Nada disto é código, e nada disto eu consigo verificar daqui — o painel do Dokploy, o Zero Trust e
os secrets do GitHub são todos do operador. **Enquanto não for feito, o pipeline não implanta**, e
falha no lugar certo (é o desenho).

1. **GitHub → Secrets** — `WEB_HOST_PROD=cinetra.com.br`, `WEB_HOST_HML=hml.cinetra.com.br`,
   `R2_ACCOUNT_ID=<id da conta>`. Ausentes, o job `imagem` **aborta** no primeiro push para
   `main`/`develop`.

   > Estas três nasceram na aba **Variables**, e tecnicamente é lá que pertencem: os valores são
   > públicos por construção — o domínio e o host que a CSP anuncia a todo browser. Foram movidas
   > para **Secrets** em 2026-08-05 por uma razão de operação, não técnica: **uma aba só** para
   > provisionar o repositório. O preço, pago de propósito, é que o GitHub mascara secret em log e
   > a linha de diagnóstico do job passa a imprimir `host=***`. Preso por
   > `Api.CiWorkflowTest`, para ninguém "consertar" de volta achando que foi engano.
2. **Visibilidade dos pacotes no GHCR.** Publicados por Actions, eles nascem **privados**. Duas
   saídas, e a escolha é uma decisão de postura:
   - **públicos** (`Package settings → Change visibility`) — o servidor baixa sem credencial
     nenhuma. Coerente com o repositório, que já é público; a imagem não carrega segredo (tudo entra
     por env). Mas publica o release compilado para qualquer um.
   - **privados** — configure um *Registry* no Dokploy com um PAT de escopo `read:packages`. Uma
     credencial a mais na máquina, e ela precisa de rotação.
3. **Dokploy → Environment de cada stack:** `IMAGE_TAG=main` (prod) e `IMAGE_TAG=develop` (HML).
   **Sem isso o stack recusa subir** — de propósito.
4. **Dokploy → Deployments → Webhook** em cada stack; cole as URLs em `DOKPLOY_DEPLOY_WEBHOOK_PROD`
   e `DOKPLOY_DEPLOY_WEBHOOK_HML` (GitHub Secrets). A URL do stack em modo Compose tem o formato
   `https://<painel>/api/deploy/compose/<refreshToken>` — o `/compose/` faz parte, e o
   `refreshToken` é **segredo**: ele sozinho dispara deploy se a política do path for Bypass.
5. **Cloudflare Access:** §2.1 (ou §2.2), e os secrets `CF_ACCESS_CLIENT_ID` /
   `CF_ACCESS_CLIENT_SECRET`. **O Client ID termina em `.access`** — copie o valor inteiro. Sem o
   sufixo o Access recusa com 403, e o log do CI (desde §2.4) diz isso na primeira linha.

   O app do Access que cobre `<painel>/api/deploy` precisa de política **Service Auth** com
   *Include → Service Token*. Ele convive com o app do painel inteiro, que fica com a política de
   humanos (*Allow* + e-mail): o Access resolve pelo path **mais específico**. Não ponha Service
   Auth no app do painel — humano nunca entra numa política Service Auth, e o sintoma é você
   trancado para fora do próprio Dokploy.
6. **`DEPLOY_URL_PROD` / `DEPLOY_URL_HML`** — a base com esquema e **sem barra no fim**
   (`https://cinetra.com.br`); o passo concatena `/ready`. Sem eles a verificação pós-deploy avisa
   que **não verificou** em vez de passar calada.

**Ordem sugerida:** faça o HML inteiro primeiro (1 → 5, com `develop`) e só depois prod. O primeiro
push em `develop` é o primeiro `docker push` e o primeiro disparo através do Access — os dois lugares
onde isto pode falhar por algo que este ambiente não mostra.

---

## 4. O que este trabalho **não** prova

Dito na cara, no mesmo espírito do "o que NÃO entrou" da onda 3:

- **Nada disto rodou de verdade.** O job `imagem` publicando, o `docker push` no GHCR, o Dokploy
  fazendo `pull` e o disparo atravessando o Access só acontecem no GitHub e no servidor. Aqui foram
  provados por: parsing do YAML do workflow, `docker compose config` resolvendo as âncoras
  (`ghcr.io/transmuta/cinetra-api:main`, e recusa sem `IMAGE_TAG`), execução dos dois scripts de
  shell com o ambiente encenado, e a suíte. **A primeira execução real é o próximo push.**
- **O `/ready` continua não provando que o deploy foi ESTE deploy.** Ele responde 200 com o
  container anterior no ar. Com a imagem por digest isso ficou pior de disfarçar e melhor de
  resolver — o caminho seria a API expor o SHA do commit e a verificação comparar —, mas **não foi
  feito** e fica anotado como o próximo passo natural do R-M5.
- **A tag móvel não é digest.** O item 16 do [doc 95](95-analise-infraestrutura.md) fala em consumir
  **por digest**; o que está aqui é por tag, com a tag imutável `sha-…` publicada ao lado. A janela
  que sobra é estreita (o webhook dispara logo depois do push) e o preço de fechá-la seria o CI
  escrever no Environment do Dokploy pela API do painel — outra credencial, e de alcance muito
  maior. Fica registrado como escolha, não como esquecimento.
