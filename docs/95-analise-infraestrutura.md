# 95 — Análise completa da infraestrutura: riscos, melhorias e trade-offs

**Data:** 2026-07-30 · **Branch:** `develop` · **Alcance:** todo o encanamento de deploy, rede,
banco, backup, CI/CD, observabilidade e segredos.

> **ATUALIZAÇÃO 2026-07-31 — isto deixou de ser uma auditoria pré-voo.** O ponto 3 do "Como ler"
> abaixo diz que *"nada foi medido em servidor nenhum — não há VPS provisionada"*. **Não é mais
> verdade:** produção está no ar numa **Hostinger KVM 2**, com prod + HML + observabilidade + Dokploy
> ([ADR-023](00-decisoes.md)).
>
> **O que isso muda na leitura deste documento:**
>
> - A **Faixa 0** do §2 chamava-se "antes do primeiro deploy". O primeiro deploy aconteceu **sem
>   ela**. Os itens não ficaram menos urgentes — ficaram **mais**, porque saíram de "preparação" e
>   viraram **lacuna em sistema no ar**. Em especial: **R-C1** (os 9 alertas do Grafana não têm
>   contact point — detecção sem notificação, agora com algo para detectar) e **R-C3** (a chave `age`
>   que decifra todo backup de produção segue no working tree desta máquina de desenvolvimento).
> - **R-A4** (`mem_limit` ausente) muda de forma: com **3,5 GB de 8 GB** em uso
>   ([doc 87 §2.1](87-servidor-hostinger-riscos-e-cuidados.md#21-o-que-a-máquina-de-verdade-mediu-2026-07-31--a-estimativa-acima-estava-errada)),
>   a folga é maior do que se supunha, mas o mecanismo do achado é o mesmo — sem teto, o OOM killer
>   escolhe pelo tamanho do processo, e o maior tende a ser o Postgres.
> - **R-M12** (sem limite de CPU) ganhou uma medição parcial e um débito próprio:
>   [D-21](50-debitos-tecnicos.md).
> - As afirmações marcadas **"não verificável a partir do repositório"** continuam válidas como
>   ressalva, mas agora **são verificáveis na máquina** — o que era honestidade sobre alcance virou
>   lista de tarefas.
>
> O corpo do documento fica **como escrito**, sem reescrita retroativa: as evidências `arquivo:linha`
> continuam corretas e a severidade não mudou.

## Como ler este documento

Três coisas o distinguem de uma varredura genérica:

1. **Cada afirmação tem `arquivo:linha`.** Onde não deu para verificar a partir do repositório
   (configuração que só existe no painel do Dokploy, comportamento de provedor), está escrito
   **"não verificável a partir do repositório"** em vez de suposição.
2. **Não repito como achado novo o que já é decisão consciente ou débito registrado.** Onde o
   assunto já está em [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md),
   [`59`](59-deploy-dokploy-oci.md), [`86`](86-seguranca-da-observabilidade.md),
   [`87`](87-servidor-hostinger-riscos-e-cuidados.md) ou [`90`](90-bate-volta-pos-77.md), a entrada
   **referencia** o registro e diz **se a avaliação mudou** — em vários casos ela mudou para pior,
   porque o achado continua aberto e o contexto endureceu.
3. **O contexto que mais importa:** [`87 §9`](87-servidor-hostinger-riscos-e-cuidados.md) declara
   que **nada foi medido em servidor nenhum — não há VPS provisionada**. Isto é, portanto, uma
   auditoria **pré-voo**. Quase tudo aqui custa minutos agora e custa incidente depois.

Severidade: **crítico** = expõe dado de paciente, perde dado ou derruba tudo, com gatilho
plausível e sem mitigação de pé. **alto** = indisponibilidade relevante ou degradação de controle
de segurança. **médio** = falha intermitente, cegueira operacional ou dívida que trava evolução.
**baixo** = correto consertar, barato, sem cenário agudo.

---

# 1. Riscos

## 1.1 CRÍTICOS

### R-C1 · Os 9 alertas não têm para onde disparar

**Evidência.** [`deploy/observability/grafana-alertas.yml`](../deploy/observability/grafana-alertas.yml)
tem 361 linhas e **zero** `contactPoints` — só `groups:`. O compose monta apenas esse arquivo em
`/etc/grafana/provisioning/alerting/` (`deploy/observability/compose.obs.yml:155`) e
`GF_SMTP_ENABLED` tem default `false` (`compose.obs.yml:133`). O próprio arquivo admite, em
`grafana-alertas.yml:16-19`: *"Configure o contato […] e prove que chega. Alerta que dispara e fica
só na tela é painel, não alerta."*

**Cenário de falha.** As 9 regras caem na notification policy default do Grafana, que aponta para o
contact point embutido `grafana-default-email`, com endereço placeholder e SMTP desligado. Disco a
90%, 5xx sustentado, pipeline de log parado há 10 minutos: **tudo verde para fora**, vermelho só
numa aba que ninguém tem aberta às 3h da manhã.

**Já registrado?** Sim — é o **A9 do [doc 86](86-seguranca-da-observabilidade.md:269-278)** (*"hoje o
stack **mostra**, não **avisa**"*) e o item de "primeira semana" do
[`87 §7`](87-servidor-hostinger-riscos-e-cuidados.md:376). **A avaliação mudou: subo para crítico.**
A razão é de composição, não de gravidade isolada: 12 dashboards, 4 jobs do Prometheus, WAL no
Alloy, dead man's switch nos dois pipelines, poda de métrica medida — todo esse investimento produz
**detecção sem notificação**. Um controle de detecção que não notifica não é um controle parcial; ele
é zero, e pior que zero, porque cria a sensação de estar coberto. E o
[`verificar.sh`](../deploy/observability/verificar.sh), que cobre 14 seções, **não tem nenhuma que
verifique entrega de alerta** — a única peça declarada indispensável é a única sem gate.

---

### R-C2 · Os traces exportam CPF, nome, telefone e e-mail de paciente em texto puro

**Evidência.** A poda de atributos está **comentada** em
`deploy/observability/alloy.alloy:255-276` (`// ---- O LUGAR DA PRÓXIMA PODA ----`). O pipeline real
de trace é `receiver → memory_limiter → filter(db.statement) → batch → tempo`
(`alloy.alloy:188-295`); os `stage.replace` de CPF/e-mail/telefone (`alloy.alloy:102-130`) vivem em
`loki.process "higiene"` — **só no caminho do log**.

E existe rota que põe PII crua na query string:
`web/src/routes/api/patients/lookup/+server.ts:10` documenta
`GET /api/patients/lookup?cpf=&tel=&email=&nome=&nascimento=`. Os SDKs instalados gravam isso:
`web/node_modules/@opentelemetry/instrumentation-http/build/src/utils.js:527`
(`attributes[ATTR_URL_QUERY] = parsedUrl.search.slice(1)`) e
`web/node_modules/@opentelemetry/instrumentation-undici/build/src/undici.js:166,168`
(`ATTR_URL_FULL`, `ATTR_URL_QUERY`). Retenção de 7 dias em `deploy/observability/tempo.yml:71`.

**Cenário de falha.** A recepcionista digita o CPF ao cadastrar paciente novo. O aviso de duplicado
dispara o GET com `cpf=`, `tel=`, `email=`, `nome=`. **Três spans** (servidor do BFF, cliente undici,
servidor da API) chegam ao Tempo com CPF, telefone, e-mail e nome completo, guardados 7 dias e
legíveis por qualquer login do Grafana. É exatamente o dado que
[`05 §1.3`](05-observabilidade-e-producao.md) proíbe exportar — e o log gasta **três camadas** para
barrá-lo (`api/lib/api_web/request_logger.ex:99-123`, `web/src/lib/server/log.ts:26-56`,
`alloy.alloy:102-130`) enquanto o trace o entrega inteiro.

**Já registrado?** Parcialmente. O **A6 do [doc 86](86-seguranca-da-observabilidade.md:201-238)**
nomeia `url.path` com **UUID** de paciente. **A avaliação mudou, e é uma escalada de classe:** UUID é
identificador pseudonimizado; `cpf=`+`nome=` é **dado pessoal direto**, e CPF é o identificador que
o [doc 06](06-seguranca-e-lgpd.md) trata como sensível. A premissa de jurisdição do
[`05:655-663`](05-observabilidade-e-producao.md) ("a telemetria pode sair do país porque nenhum
identificador de titular entra em span") está **factualmente falsa** hoje.

**Ponto de precisão para não caçar o alvo errado:** `db.statement` **não** é o vetor. O Ecto emite
SQL parametrizado e há teste que prova (`api/test/api/tracing_test.exs:101`). O vetor é a query
string, e o filtro que existe (`alloy.alloy`, `filter` de `db.statement`) mira o lugar errado.

---

### R-C3 · A chave privada `age` de produção está no working tree do repositório

**Evidência.** `/home/ruby/dev/transmuta/cinetra/cinetra-prod-age.key` existe, tem 3 linhas e contém
`AGE-SECRET-KEY` (verificado por contagem, sem exibir o valor). É a chave que **decifra todo backup
de produção**. O desenho diz o contrário, em dois lugares:

- `deploy/backup/backup.sh:9-11` — *"O servidor cifra mas **NÃO decifra** — a chave privada fica
  offline, usada só no restore."*
- `deploy/backup/restore.sh:10-11` — *"…que vive **FORA do servidor** e você monta só na hora do
  restore."*

**Cenário de falha.** Um `.dump.age` do R2 sem a chave é ruído. Com a chave, é o banco inteiro:
nome, CPF, telefone, e-mail, evolução clínica de todo paciente de todas as clínicas. Hoje as duas
metades do cofre estão a uma pasta de distância uma da outra na máquina de desenvolvimento — que
não tem disco cifrado verificado, não tem MFA, roda navegador e instala dependências de npm e hex.
Qualquer comprometimento da estação de trabalho, qualquer backup automático de home para nuvem
pessoal, qualquer `tar` da pasta do projeto reúne as duas metades.

**Já registrado?** **Não.** Nenhum doc menciona que este arquivo existe. O
[`87 §7`](87-servidor-hostinger-riscos-e-cuidados.md:369) manda *rotacionar as credenciais que já
circularam no `.env` do working tree (R2 e client secret do Google)* — a chave `age` **não está
nessa lista**, e é a de maior alcance de todas.

**Agravante latente.** `.gitignore:17` protege **o nome exato do arquivo**, não um padrão:

```
cinetra-prod-age.key
```

Verificado: `git check-ignore cinetra-hml-age.key` **não casa**. A guarda é um nome, não uma regra —
a próxima chave (HML, ou a rotação `cinetra-prod-age-2.key`) entra no commit.

---

## 1.2 ALTOS

### R-A1 · Job do Oban morto pelo SIGKILL fica `executing` para sempre — não há `Lifeline`

Este é o achado mais mecânico do relatório, e todas as peças são verificáveis no repositório.

**Evidência, em quatro fatos que se encaixam:**

1. `compose.dokploy.yml` **não declara `stop_grace_period` em nenhum serviço** (verificado: 0
   ocorrências). O default do Docker é **SIGTERM, 10 s, SIGKILL**.
2. `api/config/config.exs:96-107` — os plugins do Oban são **`Pruner` e `Cron`, e só**. Não há
   `Oban.Plugins.Lifeline` (verificado: 0 ocorrências de `Lifeline` em todo `config/` e `lib/`).
3. `api/lib/api/housekeeping/prune_attachments.ex:59` — *"`Api.Storage.delete/1` — request ao
   Cloudflare, **`receive_timeout` de 15 s**"*. Uma única deleção de objeto pode levar 15 s, e o job
   varre **linha a linha** de propósito (`config.exs:110-112`: *"tem BYTES no R2 do outro lado, e por
   isso varre linha a linha em vez de DELETE em lote"*).
4. O drain próprio do Oban (default de 15 s no 2.x; `mix.lock:51` fixa `oban 2.23.0`) é **maior que
   os 10 s do Docker** — ou seja, o Docker garantidamente corta o drain que o Oban planejou.

**Cenário de falha.** Deploy (ou OOM kill, ou reinício por `restart: unless-stopped`) enquanto
`PruneAttachments` roda às 03:30 UTC, ou enquanto um `Api.Packages.Materializer` disparado por
clique de usuário está no meio de uma série. O container recebe SIGTERM, o Oban começa a drenar, aos
10 s vem o SIGKILL. A linha em `oban_jobs` fica em `state = 'executing'` **para sempre**:

- o `Oban.Plugins.Pruner` **não a remove** — ele poda `completed`, `cancelled` e `discarded`;
- sem `Lifeline`, **ninguém a resgata** — não há retentativa, não há `discarded`, não há exceção;
- portanto **não há linha de log de erro**, e o alerta `cinetra-job-falhando`
  (`grafana-alertas.yml:177-208`) conta linhas `job:exception` — que nunca existirão.

O resultado por tipo de job: a materialização de série do paciente **nunca acontece** e o usuário vê
um pacote vazio sem motivo; o lembrete ao paciente **não sai**; a poda de anexos deixa bytes órfãos
pagos no R2. E `oban_jobs` acumula linhas zumbis que nenhuma poda alcança.

**Já registrado?** **Não.** O [doc 77 §5.1](77-bate-volta-observabilidade-e-pacotes.md:288-292)
registra que *"a criação da série inteira segue assíncrona e engolindo o motivo"* — é o problema
vizinho (erro engolido), não este (job **órfão**, que nem chega a errar).

**Onde vai o teste** (convenção do CLAUDE.md): a metade barata é um teste de configuração no
espírito do `Api.ObanPoolTest` — cobrar que `Lifeline` esteja na lista de plugins e que
`stop_grace_period` do serviço `api` exceda o grace do Oban, lendo o compose como o
`Api.DeployEnvTest` já faz. A mutação que valida: **remova o `Lifeline` e confira o vermelho.**

---

### R-A2 · Página autenticada com dado clínico sai sem `Cache-Control`

**Evidência.** `web/src/hooks.server.ts:45-47` escreve exatamente três headers —
`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` — e `:63` o HSTS. Nenhum
`Cache-Control`. No SvelteKit 2.69.2 instalado, `private, no-store` só é emitido para `__data.json`
(`node_modules/@sveltejs/kit/src/runtime/server/data/index.js:173`) e para remote functions; o HTML
de SSR de `/pacientes/<id>` sai **sem header de cache nenhum**.

**Cenário de falha.** Recepção de clínica, computador compartilhado — que é o cenário de uso real
deste produto, não uma hipótese. A profissional abre a ficha (nome, CPF, evolução), clica em "Sair";
o POST invalida a sessão e apaga o cookie **corretamente**. O próximo usuário aperta *Voltar*: o
browser re-renderiza a ficha do cache de disco/bfcache **sem tocar no servidor** — nem a sessão
apagada nem o `redirect(303, '/entrar')` de `+layout.server.ts:28` são consultados. É dado de saúde
na tela depois do logout, sem uma única requisição que qualquer log pudesse registrar.

**Já registrado?** **Não.** O [doc 06](06-seguranca-e-lgpd.md) não trata de cache de browser, e o
[doc 87 §6](87-servidor-hostinger-riscos-e-cuidados.md:333-338) lista os headers que existem sem
notar a ausência deste.

---

### R-A3 · `ORIGIN` ausente não derruba o boot — e rebaixa o CSRF ao header `Host`

**Evidência.** `node_modules/@sveltejs/adapter-node/files/handler.js:17,101`:
`base: origin || get_origin(req.headers)`, e `get_origin` (`:208-222`) monta a origem a partir de
`headers['host']` com protocolo default `https`. O teste de CSRF do Kit (`respond.js:83-89`) compara
`request_origin !== url.origin`. `ORIGIN` está setado hoje em `compose.dokploy.yml:257` — mas **nada
verifica que continua**.

**Cenário de falha.** Alguém renomeia ou apaga a variável no painel do Dokploy. O container sobe
verde, `/health` 200, `/ready` 200, nenhum log. A partir daí a comparação de CSRF é contra
`https://<Host que o próprio request enviou>` — e o Traefik roteia **por `Host()`**, então o header
chega intacto ao Node. Um POST cross-site volta a passar contra `/auth/sign-out`,
`/auth/switch-clinic` e todas as form actions. No mesmo pacote, o HSTS de `hooks.server.ts:63` passa
a sair sempre, porque o comentário de `:57-59` já admite que *"quem garante a verdade aqui é o
`ORIGIN`"*.

O que torna isso um achado e não uma observação genérica é o **contraste interno**: o projeto **tem**
guarda de boot para `API_PUBLIC_ORIGIN` (`hooks.server.ts:20-21`, `throw` deliberado, com a
justificativa escrita) e **não tem** para a variável que sustenta o CSRF. O padrão certo já foi
escolhido; três variáveis ficaram de fora dele.

**Irmão do mesmo tipo — `API_URL`:** `web/src/lib/server/api.ts:10` faz
`return env.API_URL ?? 'http://localhost:4000'`. Se a env sumir, toda chamada BFF→API vira
`ECONNREFUSED`, `loadMe` falha, o produto inteiro vira uma tela de login que não loga — e `/health`
continua 200 porque não faz I/O de propósito (`web/src/routes/health/+server.ts:13`), que é
justamente o que o Traefik consulta (`compose.dokploy.yml:293`). **O container fica na rotação
servindo o nada.**

---

### R-A4 · Nenhum limite de memória nos containers da aplicação — e eles ficam fora do alerta por construção

**Evidência.** `compose.dokploy.yml`: **0 ocorrências** de `mem_limit`, `deploy:`, `cpus`. Contraste
medido no repositório: `deploy/observability/compose.obs.yml` tem **10** `mem_limit`.

**Já registrado?** Sim — é **o achado do [`87 §8`](87-servidor-hostinger-riscos-e-cuidados.md:386-415)**,
escrito **hoje**, que termina com: *"Enquanto não estiver consertado, entra em
`50-debitos-tecnicos.md` — não passa em silêncio."* **Verifiquei as duas pontas: continua sem
`mem_limit` no compose e continua sem entrada em `50-debitos-tecnicos.md`** (que vai de D-1 a D-18,
nenhum sobre isto). Repito aqui não como achado novo, mas porque **a instrução do próprio documento
não foi cumprida** e o item é pré-requisito de provisionamento, não follow-up.

O agravante já está escrito em `87:145-155` e vale reforçar: o alerta `cinetra-container-no-teto`
filtra por `container_spec_memory_limit_bytes > 0` — então **os containers sem teto ficam fora do
alerta por construção**. São exatamente os que servem o paciente.

**Cenário de falha.** 16 GB divididos entre dois stacks, observabilidade e um build que pica 1–2 GB.
Sem teto, o OOM killer do kernel escolhe pelo `oom_score`, que privilegia o processo maior — com boa
chance, o **Postgres**. Um vazamento no BFF derruba o banco.

---

### R-A5 · O teto de disco do Loki é opt-in — e a variável que o liga não está no template

**Evidência.** `compose.obs.yml:19-25` declara o teto de disco do Loki como uma das três
salvaguardas que substituíram a segunda VM. Mas `compose.obs.yml:87` é
`- ${LOKI_DATA:-loki_data}:/loki`, e **`LOKI_DATA` não aparece em
`deploy/observability/.env.exemplo`** (verificado: 0 linhas). `TEMPO_DATA` aparece, mas comentado
(`.env.exemplo:171`). O [`62:174`](62-plano-de-logs.md) confirma: *"Sem `LOKI_DATA`, o compose usa o
volume nomeado de sempre — o teto é opcional e não muda nada"*.

**Cenário de falha.** Quem provisiona seguindo a instrução da linha 1 do template
(`cp .env.exemplo .env.local`) sobe **sem teto**, dividindo disco com `pgdata`.
`loki.yml:64` permite `ingestion_rate_mb: 4` — 4 MB/s são ~345 GB/dia, ordens de grandeza acima do
disco. Um laço de log num deploy ruim enche o disco: o Postgres recusa escrita, o backup falha, a
clínica para. É o modo de falha que `criar-volume-limitado.sh:5-13` descreve em detalhe — e que o
template não previne. O script é bom; o problema é ser **opcional e invisível**.

---

### R-A6 · Os containers de observabilidade não têm rotação de log

**Evidência.** `compose.dokploy.yml:32-42` define `x-logging: &logging` (`max-size: 20m`,
`max-file: 3`) e o aplica aos 6 serviços da aplicação (linhas 73, 91, 104, 129, 250, 301), com a
justificativa certa: *"O default do Docker é `json-file` **sem limite**"*. Em
`deploy/observability/compose.obs.yml`: **nenhuma ocorrência de `logging:`**, nos 7 serviços.

**Cenário de falha.** Loki e Tempo estão em `log_level: warn` (`loki.yml:20`, `tempo.yml:41`), mas
Prometheus, Grafana, cAdvisor, node-exporter e Alloy logam em `info` **sem teto**, no mesmo disco do
`pgdata`. E como `cinetra-obs` está **deliberadamente fora** da allowlist de coleta
(`compose.obs.yml:48-54`, decisão correta para o Loki não coletar a si mesmo), esses arquivos não
são embarcados nem consultáveis: crescem invisíveis. A ferramenta de disco cheio enchendo o disco —
exatamente o risco #5 do [doc 59](59-deploy-dokploy-oci.md:347-357) que o `x-logging` do outro
arquivo existe para fechar.

---

### R-A7 · Nenhum `HEALTHCHECK` de Docker nos containers da aplicação

**Evidência.** **Zero** instruções `HEALTHCHECK` em qualquer Dockerfile do repositório
(`api/Dockerfile.prod`, `web/Dockerfile.prod`, `*.dev`, `deploy/backup/Dockerfile`). Em
`compose.dokploy.yml`, o único bloco `healthcheck:` é o do `db` (`:81-85`); `api` e `web` têm apenas
**labels de load balancer do Traefik** (`:237-238`, `:293-294`).

**Cenário de falha.** O processo trava sem morrer — event loop bloqueado no Node, pool esgotado no
BEAM, heap estourado sem sair. O Traefik tira da rotação (bom, e é o que o
[`87 §4.7`](87-servidor-hostinger-riscos-e-cuidados.md:198-204) considera coberto), **mas o Docker
continua reportando `Up`**: `restart: unless-stopped` nunca dispara porque o processo não morreu, e
nada reinicia nada. O container fica zumbi indefinidamente. Segundo efeito: sem healthcheck, o
`depends_on: condition: service_healthy` fica indisponível — `compose.dokploy.yml:251-252` só
consegue `depends_on: - api` seco, que espera o container **iniciar**, não **servir**.

**Distinção que o doc 87 não faz:** healthcheck do Traefik decide **roteamento**; healthcheck do
Docker decide **reinício**. Os dois são necessários e só o primeiro existe.

---

### R-A8 · Os logs do container do Postgres entram no Loki, e nome de paciente não é redigível por regex

**Evidência.** A allowlist de coleta é **por projeto do compose** (`alloy.alloy:42-46`,
`OBS_PROJETOS=cinetra`/`cinetra-prod|cinetra-hml`), e o serviço `db` está nesse projeto
(`compose.dokploy.yml:70`). As três redações do Alloy (`alloy.alloy:102-130`) cobrem **CPF, e-mail e
telefone**. Não cobrem **nome, nome social, endereço, responsável** — e não têm como: não existe
regex para nome próprio.

**Cenário de falha.** Desde 2026-07-29, identificação repetida barra no save por `identities`
(`web/src/routes/api/patients/lookup/+server.ts:13`). Uma violação de unicidade faz o Postgres logar
`ERROR: duplicate key value violates unique constraint`, seguido de `DETAIL: Key (...)=(...)` e de
`STATEMENT:` com os parâmetros. O CPF sai como `[CPF]`; o **nome completo do paciente vai inteiro**
para o Loki e fica 30 dias. A primeira camada de defesa que o [`05 §2.4`](05-observabilidade-e-producao.md)
prescreve — allowlist na origem — **não existe para um container que não é nosso**.

---

### R-A9 · `docker.sock` montado é root-equivalente, e o `:ro` não muda isso

**Evidência.** `compose.obs.yml:470-473` monta `/var/run/docker.sock:/var/run/docker.sock:ro` no
Alloy com o comentário *"Somente leitura no socket do Docker"*. **A afirmação está invertida:** o
`:ro` é do *bind mount* (impede apagar/substituir o arquivo), e não impede `connect()` +
`POST /containers/create` na API do Docker. Um container com o socket montado, `:ro` ou não, cria um
container privilegiado com `/` do host montado.

**Já registrado?** Sim — **A1 do [doc 86](86-seguranca-da-observabilidade.md:37+)**, classificado
ALTO e medido. **O que acrescento é novo e piora o alcance:** `compose.obs.yml:379` monta
`- /var/run:/var/run:ro` no **cAdvisor** — e `/var/run` **contém** `docker.sock`. Ou seja, são dois
containers com root-equivalente, não um. Além disso, o raciocínio de `compose.obs.yml:322-331` que
dispensa `privileged` no cAdvisor se apoia na mesma premissa errada (*"privilegiado é estritamente
pior que o socket do Docker que o alloy já monta — e aquele ao menos é `:ro`"*): a comparação não
se sustenta, porque as duas pontas são equivalentes.

**Cenário de falha.** Um RCE no Alloy — que expõe receptor OTLP na rede da aplicação,
`compose.obs.yml:478-493` — ou no cAdvisor vira root no host, com o `pgdata` do Postgres de produção
ao lado. A mitigação real é o **socket proxy com allowlist de endpoints**
(`/containers/json`, `/containers/*/logs`), já previsto em [`87 §7`](87-servidor-hostinger-riscos-e-cuidados.md:376),
não a flag `:ro`.

---

### R-A10 · O workflow não declara `permissions:` — o `GITHUB_TOKEN` herda o default do repositório

**Evidência.** `.github/workflows/ci.yml` — **nenhuma ocorrência de `permissions:`**, em nenhum nível
(verificado). Sem declaração, o `GITHUB_TOKEN` recebe o default configurado no repositório/organização,
que em repositórios mais antigos é **read/write em todos os escopos** (não verificável a partir do
repositório qual é o default configurado aqui).

**Cenário de falha.** O job `api` roda `mix deps.get` (`ci.yml:57`) e o job `web` roda `npm ci`
(`ci.yml:171`) — ambos executam código de terceiros no runner, com o token no ambiente. Um pacote
comprometido em qualquer ponto da árvore de dependências usa o token para empurrar commit, alterar
workflow ou publicar release. O agravante específico deste repositório: o job `deploy`
(`ci.yml:184-205`) tem acesso a `DOKPLOY_DEPLOY_WEBHOOK_PROD`, ou seja, ao **gatilho de deploy de
produção**.

Correção: `permissions: contents: read` no topo, e o escopo mínimo por job onde precisar de mais.
Custo: duas linhas.

**Já registrado?** O [`87 §5.11`](87-servidor-hostinger-riscos-e-cuidados.md:311-317) trata de supply
chain **pela ausência de Dependabot**. A permissão do token é outra superfície, e não está registrada.

---

## 1.3 MÉDIOS

| # | Risco | Evidência | Cenário de falha |
|---|---|---|---|
| R-M1 | **Sem `stop_grace_period` também no `web`** — o adapter-node planeja drenar por 30 s | `compose.dokploy.yml:240-294` (0 ocorrências); `node_modules/@sveltejs/adapter-node/files/index.js:14,100` (`SHUTDOWN_TIMEOUT` default 30) | Todo deploy. Requisições em voo entre 10 s e 30 s levam SIGKILL no meio do stream — e o SSR é *streamed* (`web/src/lib/server/compress.ts:71`, `pipeThrough(CompressionStream)`). O usuário recebe **gzip truncado**: página quebrada, não retry. Mesma raiz do R-A1; correção é uma linha de YAML |
| R-M2 | **Sem `shm_size` no Postgres** | `compose.dokploy.yml:70-85` (0 ocorrências em todo o repositório) | `/dev/shm` fica no default de 64 MB do Docker. Uma query com plano paralelo — os agregados das views `metrics_*` e os relatórios são candidatos — falha com `could not resize shared memory segment […] No space left on device`. Sintoma que não parece disco e não parece memória |
| R-M3 | **Sem `KEEP_ALIVE_TIMEOUT` no BFF** | `adapter-node/files/index.js:43-47` só aplica se a env existir; nada a define no compose | Fica o default de **5 s** do Node, menor que o idle do pool do Traefik. Corrida clássica: o Traefik tira do pool uma conexão no instante em que o Node a fecha → **502 intermitente sem uma linha no log da aplicação**, tipicamente em baixa carga. Vira "flakiness inexplicável" |
| R-M4 | **O CI nunca constrói a imagem de produção** | `.github/workflows/ci.yml` — nenhum `docker build`; o Dokploy builda no servidor a cada webhook (`:184-205`) | A guarda de sourcemap de `web/Dockerfile.prod:44-48` — **última fronteira** contra o código-fonte ir para produção — nunca roda antes do merge. Idem `npm prune`, wiring dos `ARG`, sintaxe do Dockerfile. Erro ali só aparece no painel do Dokploy **depois** do merge em `main`, e o sintoma é "o deploy não subiu", sem log no GitHub |
| R-M5 | **O passo de deploy é fire-and-forget** | `ci.yml:205` — `curl -fsS -X POST "$URL"` | O `curl` retorna assim que o Dokploy **aceita** o webhook. O CI fica verde mesmo que o build no servidor falhe, o `migrate` aborte ou o container novo não passe no healthcheck. Não há verificação pós-deploy, smoke test nem gatilho de rollback. O sinal de "deploy ok" que a equipe vai aprender a confiar mede apenas que o HTTP POST chegou |
| R-M6 | **Actions fixadas por tag, não por SHA** | `ci.yml:40,43,49,110,113,119,162,165` — `@v4`, `@v1` | Tag é ponteiro móvel. Um comprometimento upstream de `erlef/setup-beam@v1` ou `actions/cache@v4` executa código arbitrário no runner com os secrets de deploy no ambiente — sem nenhum commit neste repositório |
| R-M7 | **Nenhuma varredura de dependência** | `api/mix.exs` não tem `mix_audit`, `sobelow`, `credo` nem `dialyxir`; `web/package.json` não roda `npm audit`; `.github/` tem só `workflows/ci.yml` (sem `dependabot.yml`, sem CodeQL) | CVE conhecida em dependência direta entra e permanece sem nenhum sinal. Já é item de "primeira semana" em [`87 §7`](87-servidor-hostinger-riscos-e-cuidados.md:377) para as **imagens**; para as bibliotecas de aplicação não há registro |
| R-M8 | **Nenhuma imagem fixada por digest** | `postgres:16`, `node:22`, `node:22-slim`, `debian:bookworm-slim`, `elixir:1.18.4-otp-27`; `web/.npmrc:1` tem `engine-strict=true` mas `web/package.json` **não tem `engines`** | Build não reprodutível, agravado porque o Dokploy builda no servidor: o CI testou contra o `node:22` de hoje, o deploy de amanhã puxa outro. Uma mudança de patch em `undici` — o `fetch` global que o BFF usa para **toda** chamada à API — entra em produção **sem um commit**, e não reproduz localmente |
| R-M9 | **Rate limiter em ETS local ao nó** | `api/lib/api/rate_limiter/global.ex:28` — `use Hammer, backend: :ets` | Correto e medido para uma instância (o benchmark de `:29-20` justifica bem a janela fixa). Mas é **bloqueio silencioso de escala horizontal**: subir uma segunda réplica dobra na prática todos os tetos e **enfraquece o anti-brute-force do magic link** sem nenhum sintoma. Também: os contadores zeram a cada deploy |
| R-M10 | **O backup não verifica o dump antes de declarar sucesso** | `deploy/backup/backup.sh:59` (`pg_dump`), `:72-74` (upload), `:84` (`sinal` de sucesso) | Não há `pg_restore --list` entre gerar e sinalizar. Um dump legível-mas-inconsistente sobe e o heartbeat diz "ok". A prática certa está escrita em `restore.sh:5` (*"backup não testado não é backup"*), mas depende de humano; a verificação automática de integridade custa uma linha e fecha a metade barata |
| R-M11 | **O `pg_dump` escreve no disco do próprio host, ao lado do `pgdata`** | `backup.sh:54` (`mktemp -d`), sem volume dedicado em `compose.dokploy.yml:87-96` | O dump vai para a camada gravável do container, no mesmo disco do banco. No momento em que o disco é o recurso escasso ([`87 §4.1`](87-servidor-hostinger-riscos-e-cuidados.md:133-142), *"o mais provável de todos"*), a ferramenta de recuperação **consome espaço proporcional ao banco** exatamente quando não há espaço. E como o `backup` roda **antes do `migrate`** e é fail-closed, disco cheio vira **deploy bloqueado** por cima |
| R-M12 | **Sem limite de CPU em nenhum container** | `compose.obs.yml` — 0 ocorrências de `cpus`/`cpu_`; `compose.dokploy.yml` idem | `mem_limit` não contém consulta ligada a CPU/IO. Uma consulta LogQL de 30 dias — aberta **durante um incidente**, que é quando o painel é usado — descomprime e varre chunks, satura os núcleos, a BEAM entra em `run_queue`, o p95 sobe e `cinetra-latencia-p95` dispara. A ferramenta de diagnóstico vira a causa |
| R-M13 | **O alerta de disco dispara CRÍTICO quando o teto do Loki enche por desenho** | `grafana-alertas.yml:250` — `max(1 - node_filesystem_avail_bytes{fstype=~"ext4\|xfs"} / …)`, limiar 0.85, `severity: critico`; o volume de `criar-volume-limitado.sh:84` é um loop ext4 que **deve** encher | Contenção funcionando emite alerta crítico cujo texto (`:236-240`) diz *"O Postgres recusa escrita […] e o backup falha em silêncio"* — com o banco intacto. Página falsa em plantão; e o `max()` **sem `by (mountpoint)`** faz a partição pequena e cheia **mascarar** a raiz de verdade. O alerta que mais importa é o primeiro a perder a confiança |
| R-M14 | **O Prometheus não raspa Loki, Alloy, Tempo nem Grafana** | `prometheus.yml:102-235` tem 4 jobs: `node`, `cadvisor`, `api`, `prometheus`. Mas `grafana-alertas.yml:82-84` manda o operador comparar `loki_source_docker_target_entries_total`, `loki_write_dropped_entries_total` e `loki_distributor_lines_received_total` | O alerta "pipeline parado" dispara às 3h, o runbook manda comparar três contadores, o operador recebe **"No data"** e conclui que a coleta também caiu. De fundo: **não existe alerta sobre descarte de log** — o Alloy pode estar descartando 100% das linhas e nada avisa até o total zerar 10 min depois |
| R-M15 | **Buracos de alerta em métricas que já são coletadas** | `prometheus.yml:212` mantém `api_prom_ex_oban_queue_length_count`, `container_health_state`, `container_oom_events_total`, `node_vmstat_oom_kill`, `node_filesystem_readonly` — **nenhuma tem regra** | Fila do Oban crescendo **sem exceção** (worker sem slot, job agendado não puxado) não gera linha `job:exception` e portanto não dispara `cinetra-job-falhando` (`:177-208`): os lembretes param de sair e ninguém sabe até o paciente faltar. Sem alerta de banco fora (não há `postgres_exporter`), sem alerta de **certificado expirando** ([`87 §4.8`](87-servidor-hostinger-riscos-e-cuidados.md:206-213)), e `container_health_state` é raspado sem leitor |
| R-M16 | **O Grafana tem `depends_on: loki condition: service_healthy`** | `compose.obs.yml:105-107` | O Grafana hospeda **todas** as 9 regras, inclusive as 4 que só leem o Prometheus. Reboot da VM com o volume do Loki cheio ou com permissão errada (o caso previsto em `criar-volume-limitado.sh:52-55`) → o healthcheck do Loki nunca passa → **o Grafana nunca sobe** → somem também os alertas de disco e de memória. `restart: unless-stopped` não ajuda: o `depends_on` bloqueia a partida |
| R-M17 | **Conta única de admin do Grafana, com leitura do agregado de todas as clínicas** | `compose.obs.yml:111-112,119`; datasource `cinetra_metrics` em `grafana-datasources.yml:111-133`; `compose.obs.yml:146-148` diz que *"lê o agregado de TODAS as clínicas […] e ignora RLS por construção"* | Três pessoas dividem uma senha. Alguém consulta o agregado pelo Explore e o `audit_events` **não registra nada** — é trilha da aplicação, não do Grafana. Numa investigação de LGPD, "quem viu o quê" não tem resposta; e revogar acesso de uma pessoa vira troca coordenada de senha |
| R-M18 | **O `.env.exemplo` reintroduz um teto já medido como insuficiente** | `compose.obs.yml:341` usa `${CADVISOR_MEM_LIMIT:-512m}` e `:335-340` explica: *"com 384m o working set medido ficou em 337 MiB (87,8% do teto) — a um passo do OOM kill"*. `.env.exemplo:70` traz `CADVISOR_MEM_LIMIT=384m` | O `.env` **vence** o default do compose. Quem copia o template desfaz silenciosamente uma correção diagnosticada; o cAdvisor volta a 88% do limite, morre por OOM, reinicia e some do log — e com ele todos os painéis de container e o alerta `cinetra-container-no-teto`. **Regressão que não aparece em diff nenhum** |
| R-M19 | **`getClientAddress()` levanta quando o header falta — e o comentário do compose afirma o contrário** | `adapter-node/files/handler.js:114-121` lança para **qualquer** header configurado; `compose.dokploy.yml:262-267` afirma que *"O `x-forwarded-for` do default **não tem esse risco**"* | Qualquer requisição que alcance o container sem passar pelo Traefik — outro serviço na rede `app`, um `curl` de diagnóstico de dentro da `dokploy-network`, um probe futuro — vira **500 em toda página que fale com a API**. `web/src/lib/server/api.ts:42` usa `?.`, que protege contra a função ser `undefined`, **não** contra ela levantar; `routes/api/client-error/+server.ts:75` chama sem guarda. Comentário errado é pior que ausente: alguém vai decidir com base nele |
| R-M20 | **A guarda de boot do BFF prova concordância, não validade** | `compose.dokploy.yml:247` e `:256` derivam ambos de `${WEB_HOST}`; `web/src/lib/csp.js:96` faz `autorizadas.includes(origemRuntime)` | Com `WEB_HOST` indefinido, os dois lados viram a string literal `"https://"`, a comparação **casa**, e a guarda devolve `null`. Container sobe, CSP servida com host inválido, WebSocket morto, deploy verde. Compare com o que o próprio adapter-node faz para a env análoga (`utils.js:26-53`): valida com `new URL()` e levanta com mensagem descritiva |
| R-M21 | **`/metrics` da API sem autenticação, na rede compartilhada por todos os stacks** | `api/lib/api/prom_ex.ex:42-48` justifica pela ausência de publicação; `targets/api-prod.yml:37-45` mira `api-prod:4021` **pela `dokploy-network`**, descrita em `:31-35` como *"EXTERNA e compartilhada por todos os stacks da máquina"* | O argumento *"quem já está dentro tem o Postgres ao lado, alvo melhor"* só valeria se "dentro" fosse a rede do stack. Não é: o atacante lateral **não** alcança o Postgres (que só existe na rede `data`, `compose.dokploy.yml:313`) mas **alcança os dois `/metrics`**, e mapeia rotas, filas do Oban e taxa de erro de produção de graça. Vale igual para Prometheus e Grafana, que também entram na rede (`compose.obs.yml:252`, `:189`) — o bind em `127.0.0.1` protege da internet, **não lateralmente**, contornando o Cloudflare Access que `:167` apresenta como a proteção do painel. E `alloy.alloy:36-38` já registra que há outros projetos na máquina (*"um `educatizzy-postgres` apareceu inteiro"*) |
| R-M22 | **Nada automatiza a regra de expand-contract** | [`59 §8`](59-deploy-dokploy-oci.md:315-333) é explícito (*"nunca faça uma mudança de schema que quebre a versão do app que está rodando agora"*), mas não há teste nem script: busca por automação em `api/test/`, `deploy/` e `.github/` não encontra nada | A regra é boa e a disciplina é real, mas `compose.dokploy.yml:98-132` recria em ordem de dependência: enquanto `migrate` roda, o container **anterior** da API ainda serve tráfego contra o schema já migrado. Que migrations destrutivas são escritas está provado no repositório — `api/priv/repo/migrations/20260726205405_remove_appointment_package_id.exs:26` faz `remove(:package_id)`. Uma dessas sem a disciplina produz erro em toda query de agenda durante a janela. É o risco #4 do [`59 §10`](59-deploy-dokploy-oci.md:354), com mitigação **só humana** |
| R-M23 | **`Api.Release` roda no caminho crítico do deploy com um único teste** | `api/test/api/release_test.exs` tem **um** `test`, sobre validação de identificador SQL; `release.ex:18-22` (`setup/0`), `:24-32` (`migrate/0`) e `:70-91` (`setup_metrics_role/0`) não têm cobertura direta | O código que aplica migrations e provisiona roles em produção é o menos testado do caminho de deploy. Uma regressão em `with_admin_config/1` (`:165-180`) — por exemplo, o `after` deixando de restaurar a config — faria a API subir **como owner**, bypassando RLS, e a suíte não veria (ela já roda como superusuário) |

---

## 1.4 BAIXOS

| # | Risco | Evidência |
|---|---|---|
| R-B1 | **Deriva de comentário no rate limit**: a prosa diz 400/min, o código diz 2.000/min | `api/lib/api_web/router.ex:33` (*"teto folgado (400/min)"*) contra `api/lib/api_web/plugs/rate_limit_global.ex:48` (`@edge_limit 2_000`). Quem dimensionar capacidade pelo comentário erra por 5× |
| R-B2 | **`web/.dockerignore` com 4 linhas, e o Dockerfile faz `COPY . .`** | `web/.dockerignore` (só `node_modules/`, `.svelte-kit/`, `build/`, `.git/`) e `web/Dockerfile.prod:12`. Vão para o estágio de build `sourcemaps/`, `playwright-report/`, `e2e/`, `a11y-*.json`. **Não vaza para a imagem final** (o estágio `app` copia só 4 caminhos, `:60-65`) e o contexto é `./web`, então a chave `age` e o `.env` da raiz ficam fora por construção. Sobra contexto inflado a cada build no servidor, e o risco latente de um `web/.env` futuro ser lido por `loadEnv` em `web/vite.config.ts:24` |
| R-B3 | **Sem `timeout-minutes` em nenhum job do CI** | `.github/workflows/ci.yml` (0 ocorrências). Um job travado queima até o teto de 6 h do runner |
| R-B4 | **Credencial default commitada, e é a senha real de dev** | `deploy/observability/verificar.sh:22` — `GRAFANA_AUTH="${GRAFANA_AUTH:-admin:cinetra-local}"`, arquivo rastreado. Não vale em produção (`:?` obrigatório em `compose.obs.yml:111-112`, bind em `127.0.0.1`), mas publica o padrão `admin:cinetra-<algo>` e convida a reuso |
| R-B5 | **Faltam `Permissions-Policy`, COOP e CORP** | `web/src/hooks.server.ts:45-47`. Busca em `docs/` e `web/`: nenhuma ocorrência — é lacuna, não decisão registrada. `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()` é uma linha |
| R-B6 | **CSP sem `report-to`/`report-uri`** | `web/svelte.config.js:18-43` define 9 diretivas, nenhuma de relatório — e a tubulação já existe (`web/src/routes/api/client-error/+server.ts`, com rate limit e sanitização). Concreto: se um build sair sem `R2_ACCOUNT_ID` (`web/Dockerfile.prod:30-31` diz *"vazio é estado válido"*), o bucket não entra no `connect-src`, **todo upload de anexo morre** e o motivo fica só no console do browser do usuário |
| R-B7 | **Duas seções numeradas "13" no `verificar.sh`** | `verificar.sh:481` e `:576`, com a "12" entre elas (`:562`) — enquanto `grafana-alertas.yml:85` manda *"rode `verificar.sh`, seção 9"* |
| R-B8 | **Healthchecks ausentes em 5 dos 7 serviços de observabilidade** | Só Loki (`compose.obs.yml:94`) e Prometheus (`:253`) têm. O Tempo é ausência **justificada** (`:426-435`, imagem distroless). Grafana, Alloy, cAdvisor e node-exporter não têm nem justificativa — e o Alloy é o caminho único de log **e** trace |
| R-B9 | **A chave do rate limiter do BFF pode colapsar em string vazia** | `web/src/routes/api/client-error/+server.ts:75`. Se o XFF chegar presente mas vazio, `handler.js:138` devolve `''` e todos caem no mesmo balde de 20/min. Não explorável sob o Traefik atual; vira problema se a edge mudar |
| R-B10 | **Documentação de infra obsoleta apontando para runbook morto** | [`17-deploy-fly.md`](17-deploy-fly.md) descreve Fly/6PN/`fly secrets` e o próprio [`59:3-5`](59-deploy-dokploy-oci.md) o declara histórico; [`05 §5`](05-observabilidade-e-producao.md:318) ainda descreve deploy no Fly, clustering por DNS interno e backup por snapshot; **ADR-008 continua "Aceita" dizendo "Deploy em Fly.io"** ([`00-decisoes.md:109-117`](00-decisoes.md)), contra a regra do próprio arquivo (`:4`, *"uma decisão só muda por um novo ADR"*). Custo real: durante um incidente, alguém abre o doc errado |

---

# 2. Sugestões de melhoria, priorizadas

Esforço: **XS** < 30 min · **S** 1–2 h · **M** meio dia · **L** 1–3 dias.

## Faixa 0 — antes do primeiro deploy (não são follow-up)

| # | Ação | Fecha | Esforço |
|---|---|---|---|
| 1 | **Tirar `cinetra-prod-age.key` da máquina de desenvolvimento** e guardá-la onde o desenho diz (offline). Trocar `.gitignore:17` por `*.key` + `!*.pub`. Se ela já circulou, **gerar par novo** e re-cifrar/descartar os dumps antigos | R-C3 | XS |
| 2 | **Provisionar contact point + notification policy** no Grafana e **provar que chega**, com uma seção nova no `verificar.sh` que dispare uma regra de teste e confirme a entrega | R-C1 | S |
| 3 | **Ligar a poda de atributos de trace** que já está escrita e comentada em `alloy.alloy:255-276` — no mínimo `delete_key(attributes, "url.query")` e `url.full`. Complemento na origem: parar de mandar PII em query string em `patients/lookup` (corpo de POST, ou hash) | R-C2 | S (Alloy) + M (rota) |
| 4 | **`mem_limit` nos quatro serviços de longa duração** de `compose.dokploy.yml` (`db`, `api`, `web`, `backup-cron`), e o teste que o [`87 §8`](87-servidor-hostinger-riscos-e-cuidados.md:400-412) já especificou — com a mutação que o valida | R-A4 | XS + S |
| 5 | **`LOKI_DATA` no `.env.exemplo`**, apontando para o volume limitado, com o `criar-volume-limitado.sh` como passo obrigatório do provisionamento. E **corrigir `CADVISOR_MEM_LIMIT` para 512m** no template | R-A5, R-M18 | XS |
| 6 | **`stop_grace_period` em todos os serviços** (`api` ≥ 20 s para exceder o drain do Oban; `web` ≥ 35 s para exceder o `SHUTDOWN_TIMEOUT`) **+ `Oban.Plugins.Lifeline`** na lista de plugins | R-A1, R-M1 | XS |
| 7 | **`Cache-Control: private, no-store` + `Vary: Cookie`** nas respostas do grupo `(app)` | R-A2 | XS |
| 8 | **Estender a guarda de boot** de `hooks.server.ts:20-21` para `ORIGIN` e `API_URL`, e validar `API_PUBLIC_ORIGIN` com `new URL()` em vez de comparação de string. É o padrão que o projeto já escolheu, aplicado a três variáveis que ficaram de fora | R-A3, R-M20 | S |
| 9 | **`permissions: contents: read`** no topo do `ci.yml`, com escopo mínimo por job | R-A10 | XS |
| 10 | **`x-logging` também no `compose.obs.yml`** (a âncora já existe do outro lado; é copiar) | R-A6 | XS |
| 11 | **Ensaiar o restore** num banco separado, cronometrando — é o item 8 do [`87 §7`](87-servidor-hostinger-riscos-e-cuidados.md:373) e nunca foi feito. Com o número na mão, **declarar RTO/RPO por escrito** | — | M |
| 12 | **Rotacionar** o que circulou no working tree: R2, client secret do Google e (agora) a chave `age` | — | S |

## Faixa 1 — primeira semana

| # | Ação | Fecha | Esforço |
|---|---|---|---|
| 13 | **`HEALTHCHECK` nos dois Dockerfiles** (ou `healthcheck:` no compose) para `api` e `web`, apontando para o liveness, e `depends_on: condition: service_healthy` onde fizer sentido | R-A7 | XS |
| 14 | **Socket proxy com allowlist** na frente do Alloy; tirar `/var/run` do cAdvisor (montar só o que ele precisa) e corrigir os comentários de `compose.obs.yml:470-473` e `:322-331` | R-A9 | M |
| 15 | **Verificação pós-deploy no CI**: após o webhook, esperar e bater em `/ready` do ambiente até 200, com timeout; falhar o job se não subir. Fecha o "verde que só prova que o POST chegou" | R-M5 | S |
| 16 | **Construir a imagem de produção no CI** (sem publicar, ou publicando num registry e mandando o Dokploy consumir por digest). Fecha a guarda de sourcemap e torna o artefato testado igual ao implantado | R-M4, R-M8 | M |
| 17 | **Fixar actions por SHA** e adicionar `dependabot.yml` (actions + npm + hex + imagens Docker); acrescentar `mix hex.audit`/`mix_audit` e `npm audit --audit-level=high` ao CI | R-M6, R-M7 | S |
| 18 | **`shm_size: 256m`** no serviço `db`; **`KEEP_ALIVE_TIMEOUT`** no `web` maior que o idle do Traefik | R-M2, R-M3 | XS |
| 19 | **`pg_restore --list` no `backup.sh`** entre gerar e sinalizar; e **volume dedicado** para o `mktemp` do dump | R-M10, R-M11 | XS |
| 20 | **Corrigir o alerta de disco**: `by (mountpoint)` e excluir (ou tratar em regra própria) o loop do Loki, cujo enchimento é o mecanismo de contenção | R-M13 | S |
| 21 | **Raspar Loki, Alloy, Tempo e Grafana no Prometheus** — sem isso o runbook do alerta de pipeline aponta para métricas que não existem — e criar **alerta de descarte de log** | R-M14 | S |
| 22 | **Alertas para o que já é coletado**: `oban_queue_length`, `container_health_state`, `container_oom_events_total`, `node_vmstat_oom_kill`; e **check de expiração de certificado** | R-M15 | M |
| 23 | **Tirar o `depends_on: loki` do Grafana** (ou trocar por `service_started`): o motor de alerta não pode depender de uma das fontes | R-M16 | XS |

## Faixa 2 — decidir com custo escrito

| # | Ação | Fecha | Esforço |
|---|---|---|---|
| 24 | **Allowlist de log na origem para o container do `db`** (só o que não carrega parâmetro) ou tirar o `db` da coleta e depender do `audit_events` | R-A8 | M |
| 25 | **SSO/Cloudflare Access com identidade individual no Grafana**, em vez de conta única compartilhada | R-M17 | M |
| 26 | **Limites de CPU** nos containers de observabilidade (o argumento de `compose.obs.yml:69-71` cita competição por recurso e a mitigação escolhida não a cobre) | R-M12 | XS |
| 27 | **Verificação automática de expand-contract**: um script que barre `remove`/`drop table`/`rename` numa migration sem marcação explícita de "fase 3", no espírito do `verificar.sh` | R-M22 | M |
| 28 | **Cobrir `Api.Release`** — em especial que `with_admin_config/1` restaura a config, e que o app não termina como owner | R-M23 | S |
| 29 | **Sair do rate limiter em ETS** (Redis ou tabela) **se e quando** houver segunda réplica — hoje é registro, não obra | R-M9 | L |
| 30 | **Realinhar a documentação**: ADR novo substituindo o ADR-008 (Fly), marcar `17` e `05 §5` como históricos no topo, e reconciliar o [`62 §8`](62-plano-de-logs.md) (ainda fala em duas VMs e nos dois firewalls da OCI) | R-B10 | S |

---

# 3. Prós e contras das escolhas atuais

## 3.1 O que está bem feito e deve ser mantido

**A topologia BFF-only é o melhor controle estrutural do projeto.** `compose.dokploy.yml:10-15`:
apenas `/socket` e `/webhooks` chegam à API pelo Traefik; todo o resto vai ao BFF. Consequências que
valem mais do que qualquer plug: o `/api/json/swaggerui` (`router.ex:53-55`) **não é alcançável da
internet**, o `/dev/mailbox` idem, e a superfície pública da API são duas rotas que se contam nos
dedos. Some a isso o isolamento de rede (`:313-316`): o `web` **não entra na rede `data`** e não
alcança o banco nem por TCP. Isolamento por topologia não depende de ninguém lembrar de nada.

**Zero portas publicadas no host em produção.** Verificado: `compose.dokploy.yml` não tem um único
bloco `ports:`. Tudo entra pelo Traefik. É a diferença entre "o firewall protege" e "não há o que
proteger".

**Dois roles de banco com um gate de CI dedicado.** O app conecta como `cinetra_app`
(NOBYPASSRLS, `release.ex:128-148`), a DDL roda como owner por variável separada
(`release.ex:159-180`), e o job `api-rls` (`ci.yml:84-153`) roda o subconjunto marcado **sob o role
restrito** — com o comentário de `ci.yml:70-83` explicando que essa classe de bug já mordeu 3× e era
invisível ao gate. E o limite desse gate está honestamente registrado
(D-15, [`50-debitos-tecnicos.md:377`](50-debitos-tecnicos.md)).

**Liveness e readiness separados pela pergunta certa, com a medição que decidiu.**
`api/lib/api_web/controllers/health_controller.ex` — `/api/health` sem I/O, `/api/ready` tocando o
banco com **teto duro por `Task.yield` + `Task.shutdown`**, porque o `timeout:` do Ecto foi medido
não limitando nada (21 s reais, `queue=17003ms`). Do lado do BFF, o Traefik aponta para `/health` de
propósito (`compose.dokploy.yml:288-292`: *"tirar o BFF da rotação quando a API pisca faz o site
deixar de servir até a página de erro"*). Essa distinção é a coisa mais frequentemente errada nesse
tipo de stack, e aqui está certa nos dois lados.

**Fail-closed onde importa, com o custo do silêncio nomeado.** `compose.dokploy.yml:178-183` usa
`${VAR:?mensagem}` em `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET` e `MAIL_FROM`, com a explicação de
por que `${VAR}` seco **não protege nada**. Idem `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_SECRET_KEY` e
`METRICS_DB_PASSWORD` (`compose.obs.yml:112`, `:118`, `:151`). Backstop mais forte que teste: *"o
default não tem como vazar porque não sobe"*.

**`Api.DeployEnvTest` é o único gate automatizado sobre configuração de deploy — e é bem
construído.** Ele **lê o compose de verdade** (`deploy_env_test.exs:46`), extrai as envs do
`runtime.exs` em vez de digitá-las (`:141-146`), recorta por serviço para que uma env no `web` não
conte pelo `api` (`:113-131`), e tem **duas guardas contra virar vacuidade** (`:128`, `:156`) —
escritas depois de a asserção antiga casar com um **comentário** do YAML. Este é o padrão que os
itens 4, 6 e 27 da seção anterior propõem estender.

**Backup com as decisões certas.** Bucket separado do de anexos, credencial escopada, retenção em
dois níveis self-contained via `--min-age` (sem depender de lifecycle do provedor,
`backup.sh:79-80`), cifra client-side opcional, **pré-deploy fail-closed**, e um heartbeat com
`trap ... ERR` (`backup.sh:50`) que dispara em qualquer saída não-zero — com o sinal de sucesso
**depois** do upload confirmado (`:82-84`), porque sinalizar antes *"diria 'estou vivo' para um
backup que não subiu"*.

**Poda de métricas e redação de log construídas sobre erro medido.** `prometheus.yml:31-49`: 755
nomes e 7.567 séries coletados para 25 usados; `keep` em vez de `drop` porque *"lista de descartar
envelhece contra você"*. `alloy.alloy:90-130` documenta três regressões reais e o conserto de cada
uma — inclusive o `stage.replace` que troca **grupos de captura** e não o match. E `verificar.sh:181-187`
testa o **falso positivo** da própria proteção. Poucos projetos fazem isso.

**`noDataState` decidido caso a caso** (`grafana-alertas.yml:39`, `:75-76`, `:117`, `:230-232`), com
a medição que motivou (*"quatro alertas falsos ativos em dev"*), e **dead man's switch nos dois
pipelines** (`:64-107`, `:328-361`) com a lição escrita: *"liveness não detecta ausência de dado; só
a ausência detecta"*.

**Imagens de produção limpas nos dois serviços.** Multi-stage, não-root (`api/Dockerfile.prod:45-48`
com uid explícito; `web/Dockerfile.prod:67` com `COPY --chown=node:node` em todos os copies),
`npm ci` e não `install`, `npm prune --omit=dev`, runtime em `-slim`. E a **guarda de sourcemap em
três camadas** (`vite.config.ts:47` → `scripts/mover-sourcemaps.mjs` → `Dockerfile.prod:44-48`), com
a honestidade de o próprio script declarar que sua conferência é fraca de propósito *"porque o risco
real é o script não rodar"*.

**CSP genuinamente restritiva.** `web/svelte.config.js:18-43`: `script-src 'self'` **sem
`unsafe-inline` e sem `unsafe-eval`**, `object-src 'none'`, `base-uri 'self'`, `form-action 'self'`,
`frame-ancestors 'none'`. O `connect-src` é **derivado**, não curinga — `csp.js:59-60` recusa
explicitamente `wss:` genérico e `https://*.r2.cloudflarestorage.com` *"porque liberariam qualquer
destino — inclusive o bucket de outra conta"*.

**Zero segredo no cliente.** Verificado: nenhuma ocorrência de `$env/static/public`,
`$env/dynamic/public` ou `PUBLIC_` em `web/src`. E cookie de sessão com as flags certas
(`api.ts:75-80`), com `maxAge` alinhado ao `token_lifetime` do JWT, e sign-out **só por POST** nos
dois endpoints.

**A qualidade da documentação é, ela própria, um controle.** Praticamente toda decisão não óbvia
carrega a medição que a produziu — o benchmark que escolheu janela fixa
(`rate_limiter/global.ex:10-13`), as 11 conexões do pool medidas em `pg_stat_activity`
(`runtime.exs:249-262`), os 337 MiB do cAdvisor, os 21 s do readiness. Isso reduz a chance de alguém
"consertar" uma proteção sem entendê-la, que é como a maioria dos controles morre.

## 3.2 Trade-offs conscientes — manter, com o custo à vista

| Escolha | Registro | O que se ganha | O que se paga |
|---|---|---|---|
| **Uma máquina só, sem HA** | [`87 §4.6`](87-servidor-hostinger-riscos-e-cuidados.md:189-197) | Custo e simplicidade; RTO baixo por ser máquina descartável | Ponto único de falha. A contrapartida (RTO/RPO **declarados** e restore **ensaiado**) ainda não foi paga |
| **Postgres em container, no mesmo host** | [`59:419-420`](59-deploy-dokploy-oci.md) | Custo zero, sem dependência de gerenciado | O dado vive na máquina descartável; disco, CPU e OOM são compartilhados com tudo |
| **Observabilidade no mesmo host** | [`62 §3.1`](62-plano-de-logs.md:83-113), revisão de 2026-07-28 com custo medido | Uma VM em vez de duas | A ferramenta de diagnóstico compete com o produto (R-M12) e pode enchê-lo de disco (R-A5, R-A6) |
| **Deploy recria containers — há downtime** | Implícito em `compose.dokploy.yml` | Simplicidade total; sem orquestrador | Janela de indisponibilidade por deploy, mais a janela de schema N+1 do R-M22. Sem blue-green nem rolling |
| **Migrations automáticas no `release_command`** | [`59 §8`](59-deploy-dokploy-oci.md:308-333) | "App no ar com migration pendente" não é estado alcançável — e o `health_controller.ex` se apoia nisso | Depende de disciplina humana de expand-contract, sem gate (R-M22) |
| **Backup pré-deploy fail-closed** | [`59:386-389`](59-deploy-dokploy-oci.md), [`87 §4.4`](87-servidor-hostinger-riscos-e-cuidados.md:170-175) | Nunca se migra sem rede | R2 fora = **deploy impossível**, inclusive o hotfix de um incidente. Vale ter um break-glass documentado |
| **CSP assada no build** | [`59:297-302`](59-deploy-dokploy-oci.md) | Header forte, com nonce, sem custo de runtime | A imagem fica **atada ao ambiente**; e o R-M20 mostra que a guarda que protege isso tem um furo |
| **Janela fixa no rate limit global** | `rate_limiter/global.ex:6-20`, com benchmark | 0,39 µs contra 31.110 µs por hit | Burst de 2× na virada — irrelevante para teto de infraestrutura, e a janela deslizante continua onde precisão importa |
| **e2e fora do CI** | D-4, [`16:118`](16-testes-frontend.md) | Sem job que pula com aviso fingindo cobertura | O caminho ponta a ponta não é gate; depende de rodada local |
| **Sem preview por PR** | D-10 | Menos infra | Revisão só no HML, depois do merge em `develop` |
| **Ingestão anônima em Loki/Tempo/Alloy** | [`86:194-199`](86-seguranca-da-observabilidade.md) | Simplicidade | Aceito **registrando** que log e trace não são prova — a trilha legal é `audit_events` |

## 3.3 O que é dívida, não trade-off

Estes não têm contrapartida escrita — são coisas que ficaram para depois:

- **Alertas sem destino** (R-C1) — o desenho declara a peça indispensável e ela não existe.
- **Traces sem redação** (R-C2) — a poda está escrita, comentada, e o [`86 §A6`](86-seguranca-da-observabilidade.md:201-238)
  argumenta que processador vazio é código morto; mas o resultado prático é PII de paciente em texto
  puro por 7 dias.
- **Chave `age` fora do lugar** (R-C3) — contradiz o desenho no próprio script.
- **`mem_limit` ausente** (R-A4) — o [`87 §8`](87-servidor-hostinger-riscos-e-cuidados.md:414) mandou
  registrar em `50-debitos-tecnicos.md` e não foi registrado.
- **Restore nunca ensaiado** — dito em [`59:407-410`](59-deploy-dokploy-oci.md),
  [`87 §4.5`](87-servidor-hostinger-riscos-e-cuidados.md:184-187) e [`05:572-575`](05-observabilidade-e-producao.md).
  Enquanto isso, "temos backup" é hipótese. Pior: **restore por clínica** (multi-tenant) não tem
  runbook nenhum ([`05:584-600`](05-observabilidade-e-producao.md)).
- **Segredos nunca rotacionados** — prescrito em quatro lugares, executado em nenhum.
- **Sem varredura de dependência** (R-M7) e **sem imagem construída no CI** (R-M4).
- **Documentação de infra contraditória** (R-B10) — três máquinas diferentes descritas como "a
  produção", e o ADR vigente aponta para um provedor que saiu.

---

# 4. Veredito

A engenharia de infraestrutura deste projeto está **acima da média para o seu porte**, e por um
motivo específico: as decisões difíceis foram tomadas na direção certa e **medidas**. A topologia
BFF-only, os dois roles de banco com gate de CI próprio, o isolamento de rede que impede o BFF de
enxergar o banco, zero portas publicadas, liveness/readiness com teto duro, fail-closed nas envs que
importam e um teste que lê o compose de verdade — esse conjunto é raro, e não foi copiado de
tutorial: cada peça carrega o número que a produziu.

O que separa isso de estar pronto é de outra natureza. Não são erros de desenho; são **peças
declaradas indispensáveis pelo próprio desenho e ainda não instaladas**. Os alertas não notificam
ninguém. Os traces levam CPF e nome de paciente. A chave que decifra todo backup está na máquina de
desenvolvimento, ao lado do repositório, contra o que o script de backup afirma. O restore nunca foi
ensaiado. Os containers que servem o paciente são os únicos sem teto de memória — e, por
construção, os únicos fora do alerta que vigia teto de memória. Some-se a isso um achado mecânico
novo: sem `stop_grace_period` e sem `Lifeline`, todo deploy pode deixar um job do Oban órfão em
`executing` para sempre, sem log, sem retentativa e sem alerta.

O momento é favorável: **não há VPS provisionada** ([`87 §9`](87-servidor-hostinger-riscos-e-cuidados.md:419-432)),
não há paciente real, e a lista da Faixa 0 é quase toda de XS e S. Doze itens, quase todos linhas de
YAML e uma tarde de trabalho, separam "muito bem projetado" de "operável com segurança". Feito nessa
ordem, a infra passa de boa-no-papel a boa-de-fato. Feito depois do primeiro paciente, cada um deles
vira incidente com nome.

Uma nota de método, no espírito do CLAUDE.md: os achados R-A1, R-A4, R-A7, R-M20 e R-M22 são
**verificáveis por script ou por teste**, e o repositório já tem os dois precedentes certos — o
`Api.DeployEnvTest`, que lê o compose, e o `verificar.sh`, que checa a stack de pé. Cada conserto
deve vir com a sua guarda, e cada guarda deve ser validada pela mutação: **desfaça o conserto e
confira o vermelho.**
