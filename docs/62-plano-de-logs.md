# 62 — Plano de logs: agregação, retenção de 30 dias e dimensionamento

> Plano de execução, 2026-07-28. Fecha a primeira das lacunas levantadas em
> [`05-observabilidade-e-producao.md`](05-observabilidade-e-producao.md), que segue como intenção
> desde antes de existir código. Escopo deste documento: **logs**. Métricas e tracing ficam para
> um doc irmão — a ordem é deliberada e está justificada na §12.

O estado de hoje em uma frase: o log é texto plano no stdout de um container, sem agregação, sem
retenção e sem ninguém olhando. Se a API cair de madrugada, o motivo está numa máquina que talvez
já tenha reiniciado. Este plano troca isso por uma agregação com 30 dias de retenção, rodando
**dentro do país** e numa máquina só (ver §3.1 — a segunda VM foi revertida).

---

## 1. O que foi medido (não estimado)

Todo o dimensionamento abaixo sai destes números, colhidos do container em 2026-07-28. Registrá-los
importa porque a conta muda se qualquer um deles mudar.

| Fato | Medida | Como se mediu |
|---|---|---|
| Linhas de log por requisição HTTP na API | **2** (`GET /rota` + `Sent 200 in Xµs`) | 21 requisições a `/api/health`, 41 linhas `[info]` no trecho isolado |
| SQL do Ecto em produção | **0 linhas** | O Ecto loga em `:debug`; [`prod.exs:16`](../api/config/prod.exs#L16) fixa o nível em `:info`. Em dev aparece (medido: 20 linhas `[debug]` na mesma janela), em prod não |
| Logs de job do Oban | **0 linhas** | `Oban.Telemetry.attach_default_logger/1` não é chamado em lugar nenhum do `api/lib` |
| Chamadas de `Logger.*` no domínio | **19** (10 `warning`, 5 `info`, 4 `error`) | Concentradas em jobs, storage R2, webhooks e fan-out |
| Formato | Texto plano, metadata só `:request_id` | [`config.exs:157`](../api/config/config.exs#L157) |

Duas consequências valem antes de qualquer conta:

**O Ecto ficar em `:debug` é o que torna 30 dias barato.** Uma requisição de agenda dispara dezenas
de queries; se elas fossem para o log, o volume seria uma ordem de grandeza maior e este plano
precisaria de outra máquina. Não mexa nisso — se um dia for preciso ver SQL em produção, é por
amostragem temporária, nunca por `:debug` global.

**O Oban ser mudo é uma lacuna, não uma economia.** O [`59`](59-deploy-dokploy-oci.md) e o
[`44`](44-onda-4-notificacoes.md) supõem que dá para responder "por que o lembrete não saiu na
terça". Hoje não dá: a linha do `oban_jobs` some depois de 7 dias (Pruner) e não há log nenhum do
que aconteceu. Ligar o logger padrão do Oban é item da §7 e custa pouquíssimo volume.

---

## 2. Modelo de volume

A unidade é o **evento** — uma linha JSON com `timestamp`, `level`, `message`, `request_id`,
`clinic_id`, `actor_id`, `service`, `env` e os campos da requisição. Em JSON isso dá **≈ 400 bytes**
por evento (600 B no caso pessimista, com mensagem longa de erro).

O modelo assume o consolidado da §7 — **1 evento por requisição em vez das 2 linhas atuais** — e
soma quatro fontes: API, BFF, jobs do Oban e Traefik.

| Cenário | Clínicas | Usuários ativos | Eventos/dia | Bruto/dia | Bruto/30 d | **Comprimido/30 d** |
|---|---|---|---|---|---|---|
| **Hoje** (HML + prod piloto) | 1–3 | ~18 | ~50 k | 20 MB | 600 MB | **≈ 0,1 GB** |
| **Piloto** | 10–15 | ~90 | ~200 k | 80 MB | 2,4 GB | **≈ 0,4 GB** |
| **Alvo** | 50 | ~300 | ~700 k | 280 MB | 8,4 GB | **≈ 1,5 GB** |
| **Teto de projeto** | 200 | ~1.200 | ~2,8 M | 1,1 GB | 33 GB | **≈ 6 GB** |

Premissa por usuário: ~800 requisições de API por dia útil (app CRUD com tempo real, que troca
polling por WebSocket), mais o tráfego de SSR do BFF e o fan-out dos crons por clínica. A compressão
usada é 5–7×, típica de log estruturado com campos repetitivos — o Loki comprime bem justamente
porque a maior parte de cada linha é o mesmo conjunto de chaves.

**A conclusão que dimensiona tudo:** mesmo no teto do projeto, 30 dias de log cabem em **menos de
10 GB**. Retenção de 30 dias não é cara aqui; o recurso escasso é RAM para ingerir e consultar, não
disco.

### 2.1 O ruído que precisa ser cortado na origem

Duas fontes gerariam mais volume que o app inteiro no cenário "Hoje", e as duas são lixo:

- **Health check do Traefik** — a cada 10 s, × 2 serviços × 2 ambientes = **34.560 requisições/dia**
  que não dizem nada. Como cada uma passa pela API, ela também vira 1 evento lá. Filtrar no agente
  (dropar `path=/api/ready` e `/api/health` com status 2xx) tira ~14 MB/dia — no cenário "Hoje" isso
  é a **maioria do volume total**.
- **Assets estáticos do BFF** — `/_app/immutable/...`. Não logar.

Cortar na origem, não na consulta: evento filtrado não custa rede, disco nem retenção.

---

## 3. Recurso do servidor — a resposta direta

### 3.1 Uma máquina, não duas (revisão de 2026-07-28)

**A primeira versão deste documento pedia uma segunda VM. Estava exagerado.** O argumento era
"observabilidade junto com o app fica cega quando o app cai". Revisando cada metade dele:

- **Perda total da máquina** — quem avisa é o monitor **externo** (§9), não o Loki. E os logs de
  antes do crash já estão no R2, não no disco local. **A durabilidade vem do object storage, não
  da segunda VM** — foi a peça que eu tinha atribuído à máquina errada.
- **Falha de aplicação** (OOM de container, crash loop) — este é o caso real que a separação
  cobria. E ele se resolve com **limite de memória por container**, que é uma linha de compose.

O custo da separação, por outro lado, era concreto: outra máquina para provisionar, corrigir e
firewallar, a divisão do disco de 200 GB em porta de mão única, rede entre VMs — e, medido no
mesmo dia, **duas rodadas de depuração** por DNS entre projetos do compose, uma delas com o agente
parado sem que nada avisasse.

Fica **uma VM (4 OCPU / 24 GB, 200 GB)** com tudo, e três salvaguardas que fazem o trabalho que a
separação faria:

| Salvaguarda | Contra o quê | |
|---|---|---|
| `mem_limit` por container | um componente estrangular os outros por memória | §3.2 |
| **Teto de disco** para o Loki | o log encher o disco e **derrubar o Postgres** | §3.4 |
| Monitor **externo** | perder a máquina inteira sem ninguém saber | §9 |
| *(opcional)* chunks no R2 | perder os 30 dias junto com a máquina | §3.3 |

As duas primeiras existem porque o log agora divide a máquina com o banco — são elas que fazem o
trabalho que a separação física faria. A terceira é a única que **não** pode viver aqui dentro,
por um motivo que nenhum limite resolve: um vigia hospedado no que ele vigia não manda o alerta
que importa.

### 3.2 Quanto custa, medido

| Componente | Limite | Uso real medido |
|---|---|---|
| Loki | 1,5 GB | ~200 MB |
| Grafana | 512 MB | ~340 MB |
| Alloy | 256 MB | ~210 MB |
| **Total** | **~2,2 GB de teto** | **~750 MB em uso** |

Numa máquina de 24 GB, a observabilidade inteira custa **~3% da memória** no pior caso. O que
sobra segue para Postgres, os dois ambientes da aplicação e o pico de build do release Elixir,
que é o maior consumidor da caixa.

### 3.3 Onde os chunks ficam: disco local (padrão) ou R2

**DECIDIDO (2026-07-28): disco da própria máquina** (`LOKI_OBJECT_STORE=filesystem`). Sem bucket a
criar, credencial a rodar ou endpoint a configurar — e é o padrão, então não há o que ligar.

Medido em 2026-07-28: 17,7 MB recebidos ocuparam 1,58 MB de chunks (+1,3 MB de WAL ainda não
descarregado) — **~6× de compressão**, exatamente a premissa da §2. Extrapolando para o teto do
projeto, 30 dias cabem em **~6 GB**. Num volume de 200 GB isso é irrelevante.

**O que se perde:** com disco local, os 30 dias morrem junto com a máquina. O backup horário cobre
o **Postgres**, não o volume do Loki — e não deve cobrir: chunks mudam o tempo todo e um tar de
Loki ativo não sai consistente.

**Por que isso é aceitável aqui:** o que tem valor legal — a trilha de auditoria (`audit_events`,
docs 61/63) — vive no **banco**, que é dumpado de hora em hora e cifrado no R2. O Loki guarda log
*operacional*: diagnóstico, não evidência. Perdê-lo ao recriar a máquina é incômodo, não incidente.

**O custo que a decisão acrescenta:** o volume do Loki passa a dividir disco com o `pgdata`. Um log
em laço não enche só o log — **derruba o Postgres junto**. A retenção limita a acumulação e o
`ingestion_rate_mb` limita a taxa, mas nenhum dos dois é teto de disco. Enquanto não houver métrica
de host (fase de métricas), quem vigia é o `verificar.sh` §10, que reprova acima de 80%.

**Quando reabrir:** se um dia recriar a máquina sem os 30 dias de diagnóstico passar a doer. São
quatro variáveis (`LOKI_OBJECT_STORE=s3` + endpoint/bucket/chave), nenhuma mudança de código.

> **A troca não é retroativa.** Mudar `object_store` de `filesystem` para `s3` faz os chunks novos
> irem para o bucket e **deixa os antigos para trás** — o Loki deixa de encontrá-los. Trocar
> significa recomeçar a janela de 30 dias, ou migrar os arquivos à mão. Decida antes de ter
> histórico que importe.

### 3.4 Teto de disco para o Loki

**O Loki não tem limite de armazenamento.** Ele tem retenção por tempo (`retention_period`) e
limite de taxa (`ingestion_rate_mb`) — nenhum dos dois é teto de espaço. Com tudo numa máquina só
e chunks em disco local, o volume do Loki divide o disco com o `pgdata`: um log em laço não enche
só o log, **derruba o Postgres junto**. Quem impõe o teto é o sistema de arquivos.

[`criar-volume-limitado.sh`](../deploy/observability/criar-volume-limitado.sh) cria um arquivo
esparso de tamanho fixo, formata em ext4, monta e registra no `fstab` (senão o teto some no
primeiro reboot, silenciosamente). Depois é uma variável:

```bash
sudo ./criar-volume-limitado.sh 20G       # o padrão; 30 dias no teto do projeto cabem em ~6 GB
# no .env:  LOKI_DATA=/var/lib/cinetra/loki
docker compose -f compose.obs.yml up -d --force-recreate loki
```

Sem `LOKI_DATA`, o compose usa o volume nomeado de sempre — o teto é opcional e não muda nada
para quem não o quiser.

**Quando enche, degrada de forma VISÍVEL.** O Loki falha ao gravar chunk, o agente acumula erro de
entrega, as linhas viram descarte — e as duas coisas são detectadas: `verificar.sh` §9 acusa
"descarte EM CURSO", e o alerta "Pipeline de log parado" dispara em 10 min. É o desenho: o que não
se pode aceitar é disco cheio derrubando o banco em silêncio.

**A armadilha desta configuração é o teto ficar inativo sem sintoma** — criar o sistema de arquivos
e esquecer a variável faz o Loki gravar no disco raiz, e tudo parece bem até não estar. Por isso o
`verificar.sh` §10 reporta o tamanho total do sistema de arquivos de `/loki`: 1 TB significa "sem
teto"; 20 GB significa "teto ativo". O número denuncia a diferença.

Alternativas descartadas: `docker volume create --opt o=size=` só funciona em tmpfs (volátil) ou
XFS com project quota — depende do sistema de arquivos do host e falha calado noutros; e um segundo
block volume na OCI reabriria a divisão de disco em porta de mão única, que foi justamente o que a
consolidação eliminou.

> **Não executado aqui.** O script precisa de root e monta sistema de arquivos; nesta máquina de
> desenvolvimento só a sintaxe e a parametrização do compose foram verificadas (com `LOKI_DATA`
> apontando para um caminho, o volume vira bind mount — conferido). A criação real do sistema de
> arquivos acontece no servidor.

**Disco:** os 200 GB ficam num volume só## 4. A stack

**Grafana Alloy (agente) → Loki (armazenamento) → Grafana (consulta).**

- **Loki** indexa *labels*, não o texto integral. É exatamente por isso que 30 dias sai barato: o
  índice é minúsculo e o corpo fica comprimido em object storage. Tem backend S3-compatível (→ R2)
  e builds arm64 boas.
- **Alloy** é um agente só para log, métrica e (depois) trace. Para um time pequeno, consolidar três
  agentes em um vale mais que qualquer ganho marginal de cada peça isolada. Lê direto da API do
  Docker, que é como o Dokploy entrega os containers.
- **Grafana** já seria necessário na fase de métricas; a mesma instância serve as duas fontes.

**Alternativas consideradas e por que não:**

- *SaaS estrangeiro (Grafana Cloud, Datadog, BetterStack)* — o [`05` §9](05-observabilidade-e-producao.md)
  demonstra que telemetria pode sair do país **desde que** nenhum dado de titular entre nela. O
  argumento é correto, mas aposta a postura de conformidade numa disciplina de redação ser perfeita
  para sempre — e ela **já não é**: [`send_job.ex:150`](../api/lib/api/messaging/send_job.ex#L150)
  loga a string crua do provedor de mensagem, que num erro de destinatário carrega telefone ou
  e-mail do paciente. Manter em Vinhedo custa R$ 0 e dispensa a aposta. Se um dia o volume justificar
  SaaS, o Alloy reaponta sem tocar no app — é o dividendo de não usar SDK proprietário (ADR-008).
- *VictoriaLogs* — mais leve e com busca full-text sem a disciplina de labels do Loki. Fica como
  plano B se a §8 se provar irritante na prática; a troca é barata porque o agente é o mesmo.
- *Vector no lugar do Alloy* — VRL é melhor para redação por regex. Se a §7.3 apertar, trocar só o
  agente é viável.

---

## 5. Retenção de 30 dias — como de fato funciona

O erro clássico é configurar `retention_period` e achar que acabou. **Não acaba: sem o compactor
rodando com remoção habilitada, a retenção é inerte** e o bucket cresce para sempre. São três peças:

```yaml
limits_config:
  retention_period: 720h          # 30 dias

compactor:
  retention_enabled: true         # SEM isto, o de cima não faz nada
  delete_request_store: s3        # onde as requisições de remoção são registradas
  retention_delete_delay: 2h      # janela para reverter um engano
```

**Verificação obrigatória:** 31 dias depois de ligar, conferir que o objeto mais antigo no bucket
tem menos de 30 dias. Retenção não verificada é a mesma classe de erro que backup não testado — e o
[`59` §13](59-deploy-dokploy-oci.md) já cravou "backup não testado não é backup".

**Retenção diferenciada (opcional, quando doer).** O Loki aceita override por stream: manter
`level=error` por 90 dias e o resto por 30. Vale se a investigação de incidente antigo se mostrar
frequente. Começar uniforme; complicar só com motivo.

### 5.1 O que 30 dias significa para a LGPD

Três pontos que precisam ficar escritos, porque a pergunta vai aparecer:

- **A retenção é um compromisso de apagamento, não só de guarda.** Se um evento vazar PII apesar da
  §7.3, a exposição fica **limitada a 30 dias** em vez de indefinida. É a razão de fixar um teto em
  vez de guardar "enquanto couber".
- **Log não é trilha de auditoria.** O `AshPaperTrail` e a tela `/configuracoes/auditoria` são
  evidência com regra de retenção própria (`PruneTrail`), dirigida por necessidade legal. Log é
  operacional e descartável. Fundir os dois estraga os dois: um fica ruidoso demais para auditar, o
  outro caro demais para reter.
- **Pedido de eliminação (Art. 18).** A resposta defensável para log não é remoção cirúrgica — é a
  janela limitada. Isso precisa constar da política de privacidade, e é mais um motivo para o teto
  ser curto.

---

## 6. Cardinalidade — a regra que decide se o Loki funciona

**A regra:** label é para o que tem punhado de valores; o resto vai **dentro** da linha JSON.

| Vira label | Nunca vira label |
|---|---|
| `service` (api, web, traefik, db) | `clinic_id` |
| `env` (prod, hml) | `actor_id`, `user_id` |
| `level` | `request_id` |
| | `path` com id embutido |

Cada combinação de labels cria um *stream* separado no Loki, com estrutura própria. `clinic_id` como
label a 200 clínicas × 4 serviços × 2 ambientes × 4 níveis = 6.400 streams — e a partir daí a
ingestão degrada e a consulta fica pior que grep. `request_id` como label seria um stream por
requisição: derruba o Loki no primeiro dia.

Isso **não** custa capacidade de busca. `clinic_id` dentro do JSON é consultável assim:

```logql
{service="api", env="prod", level="error"} | json | clinic_id="019f7c5b-..."
```

O filtro por label estreita para poucos streams; o `| json` decodifica só o que sobrou. É rápido
porque o funil está na ordem certa.

---

## 7. Mudanças necessárias no app

### 7.1 Elixir (API)

1. **`LoggerJSON`** como formatter em produção. Dev fica como está — texto colorido é melhor para
   humano.
2. **Carimbo de contexto no [`LoadScope`](../api/lib/api_web/plugs/load_scope.ex#L34).** É o ponto
   certo: já resolve `actor` e `clinic_id`, e **toda rota de domínio passa por ele**. Um
   `Logger.metadata(clinic_id: ..., actor_id: ...)` ali dá contexto a todo log daquela requisição de
   graça, inclusive aos 19 sítios de `Logger.*` que existem hoje sem contexto nenhum.
3. **Consolidar as 2 linhas em 1 evento.** Desligar o logger de requisição do Phoenix
   (`config :phoenix, :logger, false`) e anexar um handler ao `[:phoenix, :endpoint, :stop]` que
   emite **um** evento com `method`, `route`, `status`, `duration_ms`. Corta o volume pela metade
   (medido: 2 linhas → 1) e, mais importante, entrega um evento completo em vez de dois pela metade
   que precisam ser correlacionados na consulta.
4. **`Oban.Telemetry.attach_default_logger(:info)`.** Fecha a lacuna da §1 por custo desprezível.
5. **`/api/ready`** de verdade (`SELECT 1` + migrations + pool), com `/api/health` seguindo como
   liveness sem I/O — e **corrigir o path do health check do Traefik**, que hoje aponta para
   `/health` e devolve 404 ([`compose.dokploy.yml:145`](../compose.dokploy.yml#L145); medido:
   `/health` → 404, `/api/health` → 200). Não é logging, mas está no caminho do mesmo deploy e hoje
   é um bloqueador.

### 7.2 Node (BFF)

1. **`handleError` em [`hooks.server.ts`](../web/src/hooks.server.ts)** emitindo JSON. Hoje erro de
   servidor do SvelteKit simplesmente evapora — é a lacuna mais barata do projeto inteiro.
2. **Não logar requisição bem-sucedida no BFF.** A API já loga tudo; duplicar dobraria o volume por
   quase nenhuma informação nova. Logar do BFF só **erro** e **requisição lenta** (acima de um
   limiar).

### 7.3 A redação, que precede o embarque

Uma vez que o log sai da máquina, o que vazou já vazou. Então isto entra **antes** de ligar o envio,
não depois:

1. **Consertar o [`send_job.ex:150`](../api/lib/api/messaging/send_job.ex#L150)** para registrar
   código de erro, não a string crua do provedor. É PII de titular indo para o log **hoje**.
2. **Serializador de erro do Ash** que redige o `value` de campo sensível, mantendo `field` e código
   — a `Ash.Error.Invalid` carrega o valor reprovado, e um erro de validação em `tags` traria
   diagnóstico para dentro da mensagem ([`05` §2.4](05-observabilidade-e-producao.md)).
3. **Allowlist, não denylist.** Loga-se o que foi marcado como seguro. Allowlist erra fechado;
   denylist erra aberto, e com dado de saúde errar aberto é incidente reportável.
4. **Teste de CI** que reprova se nome proibido (`cpf`, `tags`, `obs`, `crm`, `telefone`, `email`)
   aparecer em chamada de log. O projeto já tem cultura de gate no CI; este entra no mesmo lugar.
5. **Estágio de redação no agente**, como rede de segurança: regex de CPF e de telefone, dropando o
   campo antes de escrever. É defesa em profundidade — a camada 1 deveria bastar, mas um `dbg/1`
   esquecido não pode virar vazamento.

### 7.4 Traefik e o driver do Docker

- Access log do Traefik em JSON, **com as rotas de health filtradas** (§2.1). Ele é o único registro
  de requisição que nunca chegou ao app — erro de TLS, 404 na borda, rate limit.
- **`logging:` driver com rotação** no [`compose.dokploy.yml`](../compose.dokploy.yml), que hoje não
  existe: herda `json-file` sem limite. Mesmo com envio funcionando, a rotação local é o piso que
  impede o disco encher se o agente morrer.

---

## 8. Rede e segurança

- As duas VMs na **mesma VCN**; o Loki escuta só na sub-rede privada. A porta de ingestão **nunca**
  é exposta à internet — log agregado é um alvo de reconhecimento (rotas, ids, versões).
- **Grafana atrás de autenticação**, e de preferência alcançável só por VPN. Se for publicado, entra
  atrás do Traefik com TLS e MFA.
- **Lembrete do `59`: a OCI tem dois firewalls.** Abrir a security list não basta — a imagem já vem
  com regras de `iptables` que bloqueiam tudo menos 22. Os dois precisam ser ajustados, e esquecer o
  segundo é o erro que faz "está aberto mas não conecta".
- Credencial do R2 do bucket de logs **escopada só a esse bucket**, nunca a chave dos anexos.

---

## 9. Alerta: por que ele não mora aqui

Duas camadas, e só uma delas é deste plano:

- **Interna** — regras no Grafana sobre o log (taxa de `level=error`, ausência de evento esperado).
  Sai de graça depois que a stack estiver de pé.
- **Externa (dead-man's switch)** — serviço de terceiro batendo em `/api/ready` e recebendo
  heartbeat dos crons. É o **único** componente que precisa sobreviver à perda total da tenancy, e
  por isso não pode viver na `obs`. Carrega zero risco de PHI: só bate numa URL.

A externa é mais urgente que este plano inteiro. Fecha inclusive o buraco que o
[`59` §13](59-deploy-dokploy-oci.md) nomeou e deixou aberto — o `backup-cron` que morre em silêncio.

### 9.1 Heartbeat dos crons — construído

O lado do código está pronto; falta **criar os checks no monitor** e colar as URLs nas envs.

**Elixir** ([`Api.Heartbeat`](../api/lib/api/heartbeat.ex)) — o gancho é o telemetry do Oban, então
nenhum job precisou ser tocado: `[:oban, :job, :stop]` → `GET <url>`,
`[:oban, :job, :exception]` → `GET <url>/fail`. Distinguir os dois importa porque "não rodou" e
"rodou e falhou" pedem investigações diferentes. Uma env por job (§`runtime.exs`), ausente =
desligado:

| Job | Env | Por que monitorar |
|---|---|---|
| `Api.Messaging.ReminderJob` | `HEARTBEAT_URL_REMINDER` | O único que fala com o **paciente** |
| `Api.Notifications.DailyDigestJob` | `HEARTBEAT_URL_DIGEST` | Resumo diário da equipe |
| `Api.Notifications.SessionSoonJob` | `HEARTBEAT_URL_SESSION_SOON` | Aviso de sessão em 15 min |
| `Api.Housekeeping.PruneTrail` | `HEARTBEAT_URL_PRUNE_TRAIL` | Falha devagar: tabela só cresce |
| `Api.Housekeeping.PruneNotifications` | `HEARTBEAT_URL_PRUNE_NOTIFICATIONS` | idem |
| `Api.Housekeeping.PruneAttachments` | `HEARTBEAT_URL_PRUNE_ATTACHMENTS` | idem, + bytes órfãos no R2 |

**Backup** ([`backup.sh`](../deploy/backup/backup.sh)) — `HEARTBEAT_URL_BACKUP`, com
`trap 'sinal /fail' ERR` para pegar estouro no meio (o `set -e` sai calado), e o sinal de sucesso
**depois** do upload confirmado — sinalizar antes diria "estou vivo" para um backup que não subiu,
que é pior que não monitorar. Verificado ao vivo contra um servidor real: sucesso → `/hb`,
falha → `/hb/fail` com `exit=1` preservado, sem env → nada.

### 9.2 Duas armadilhas do `:telemetry` que este trabalho expôs

**Handler que levanta é DESANEXADO pelo `:telemetry`** — em silêncio, e até o próximo boot. Não
afeta só a si mesmo: o `ApiWeb.RequestLogger` nasceu com `rota/1` guardada por `when is_binary`, e
uma conexão abortada antes da resposta (com `request_path` nulo) teria derrubado **o log de
requisição do sistema inteiro**, deixando um painel vazio que ninguém desconfia. Os dois handlers
agora têm `rescue`, e o `rota/1` tem cláusula de fallback.

**Handler roda no processo que emitiu o evento** — para o Oban, o processo do job. Um `Req.get`
síncrono ali seguraria o slot da fila pelo tempo da rede alheia. O ping sai numa `Task`
desacoplada; o teste crava que o handler retorna em menos de 200 ms mesmo com o monitor
inalcançável.

### 9.3 Os dois tipos de check externo, e para que cada um serve

São mecanismos **opostos**, e é por isso que os dois são necessários:

| | Quem chama quem | Detecta | Não detecta |
|---|---|---|---|
| **Uptime** (HTTP check) | O monitor **chama** você | "está fora do ar" — processo morto, TLS vencido, deploy quebrado, banco inalcançável | cron parado (não há requisição para falhar) |
| **Heartbeat** (dead man's switch) | Você **avisa** o monitor | "deixou de acontecer" — cron parado, worker morto, backup falhando calado | site fora do ar entre execuções |

O heartbeat inverte a lógica: em vez de perguntar "está de pé?", ele **espera** um sinal e reclama
quando ele não chega dentro do prazo. É a única forma de detectar ausência — nenhum log registra o
que não rodou, e nenhuma requisição falha quando não há requisição.

**Ambos precisam ser de terceiro.** Um vigia hospedado na nossa infra morre junto com o que
deveria vigiar, e o alerta que importa é justamente o que ele nunca chegaria a mandar. Nenhum dos
dois carrega risco de PHI: um faz GET numa URL nossa, o outro recebe GET numa URL opaca.

### 9.4 Criando os checks — runbook

**São dois serviços, não um.** Uma versão anterior desta seção dizia que o healthchecks.io fazia
os dois tipos — está errado, e a doc deles é explícita: *"Healthchecks.io is not the right tool
for: monitoring website uptime by probing it with HTTP requests."* Ele é **só inbound** (recebe
pings). Para o uptime, que exige alguém **chamar** a nossa URL, é preciso um segundo serviço
(UptimeRobot, BetterStack Uptime, Hetrix — todos com plano grátis).

| Papel | Serviço | Quantos |
|---|---|---|
| Heartbeat dos crons | **healthchecks.io** (20 no grátis) | 14 (7 × 2 ambientes) |
| Uptime do produto | **UptimeRobot** ou equivalente | 2 (prod e HML) |

**Passo 1 — conta e canal de alerta.** Crie a conta e configure ao menos **um canal que acorde
alguém**. Só e-mail é o erro clássico: alerta às 3h da manhã que chega numa caixa lida às 9h não é
alerta, é registro histórico.

**Passo 2 — a chave é do PROJETO, não de um check.**

Este é o passo em que é fácil pegar a coisa errada, e o erro é caro. Há dois tipos de URL no
healthchecks.io, e só um serve aqui:

| | Formato | Exemplo | Serve? |
|---|---|---|---|
| **Ping URL de um check** | `hc-ping.com/<uuid>` | `hc-ping.com/00000000-1111-2222-3333-444444444444` | **Não** — endereça UM check só |
| **Ping Key do projeto** | `hc-ping.com/<ping-key>` | `hc-ping.com/fqOOd6-F4MMNuCEnzTU01w` | **Sim** — endereça o projeto; o slug escolhe o check |

Repare no formato: a Ping Key **não** tem a cara de UUID (`8-4-4-4-12`). Se a string que você
copiou tem essa cara, é o UUID de um check — e usá-la como base faria toda ping virar
`hc-ping.com/<uuid>/reminder`, que não endereça nada. Resultado: os sete checks alarmando "não
rodou" para sempre.

A Ping Key fica em **Project Settings → Ping Key** (pode ser preciso gerá-la na primeira vez).

**Passo 3 — os checks.** O **nome do check tem de ser exatamente o slug**: é assim que a URL o
encontra. *Period* é de quanto em quanto tempo o sinal deve chegar; *Grace* é a tolerância antes de
alarmar — precisa cobrir a duração normal do job mais a variação, senão a primeira execução lenta
vira alarme falso.

| Slug (= nome do check) | Period | Grace | Quem sinaliza |
|---|---|---|---|
| `backup` | 1 h | 20 min | `backup.sh` |
| `reminder` | 1 h | 15 min | `Api.Messaging.ReminderJob` |
| `digest` | 1 h | 15 min | `Api.Notifications.DailyDigestJob` |
| `session-soon` | 5 min | 5 min | `Api.Notifications.SessionSoonJob` |
| `prune-trail` | 1 dia | 2 h | `Api.Housekeeping.PruneTrail` |
| `prune-notifications` | 1 dia | 2 h | `Api.Housekeeping.PruneNotifications` |
| `prune-attachments` | 1 dia | 2 h | `Api.Housekeeping.PruneAttachments` |

**Prod e HML precisam de checks distintos** — compartilhar esconde qual dos dois parou e, pior, o
sinal do HML mantém o check verde com a produção morta. Duas formas, e o código aceita as duas:

- **Um projeto só, com prefixo** (funciona sempre): 14 checks nomeados `prod-reminder`,
  `hml-reminder`, `prod-backup`… Uma Ping Key, e `HEARTBEAT_SLUG_PREFIX` diferencia.
- **Dois projetos** (`cinetra-prod` e `cinetra-hml`): 7 checks em cada, nomes sem prefixo, uma Ping
  Key por projeto. Isola melhor — chave vazada do HML não alcança os checks de produção. *(A doc do
  plano grátis não diz se há limite de projetos; se houver, use a opção acima.)*

**Passo 4 — as variáveis no Dokploy.**

```bash
# stack prod
HEARTBEAT_BASE_URL=https://hc-ping.com/<ping-key>
HEARTBEAT_SLUG_PREFIX=prod-        # só na opção "um projeto"; omita se forem dois projetos

# stack hml
HEARTBEAT_BASE_URL=https://hc-ping.com/<ping-key>
HEARTBEAT_SLUG_PREFIX=hml-
```

O código monta o resto: `<base>/<prefixo><slug>` no sucesso e `.../fail` quando o job estoura. São
**duas variáveis por stack** em vez de 14 colagens de UUID — e o que distingue os ambientes passa a
ser a configuração, não a disciplina de não errar nenhuma.

> **A Ping Key é credencial.** Quem a tem consegue pingar no seu lugar e manter tudo verde com o
> sistema morto. Vai na aba Environment do Dokploy, nunca no repositório — mesma regra dos demais
> segredos do `compose.dokploy.yml`.

> Slug digitado errado **não fica calado**: o serviço cria um check novo para o nome desconhecido,
> e o check real deixa de receber sinal e alarma no primeiro ciclo. O erro aparece de imediato em
> vez de virar um monitor verde que não observa nada.

Para sobrescrever um job específico (URL por UUID, ou outro monitor) as envs
`HEARTBEAT_URL_<JOB>` continuam existindo e têm precedência.

**Passo 5 — o check de uptime, no OUTRO serviço.** Um por ambiente, apontando para:

```
https://<WEB_HOST>/ready
```

**Não** aponte para a raiz do site. Com o desenho BFF-only, a home é servida pelo Node e responde
**200 com a API inteiramente fora** — o monitor ficaria verde com o produto inutilizável. O
`/ready` do BFF atravessa a rede interna até o `/api/ready` da API, que por sua vez toca banco e
pool; é a única URL pública que fica vermelha se qualquer elo quebrar. (Verificado na prática: com
a API fora, `/health` respondeu 200 e `/ready` respondeu 503.)

Intervalo de 1 min é suficiente; o endpoint tem teto de 3 s.

**Passo 6 — provar que alarma.** Um monitor nunca testado é hipótese, não monitor — a mesma regra
que o [`59` §13](59-deploy-dokploy-oci.md) aplica ao backup. Pause o container do `api` e confirme
que o check de uptime fica vermelho e que o alerta chega **no canal**, não só na tela. Para um
heartbeat, basta esperar `Period + Grace` sem que o job rode.

### 9.5 O que falta (humano)

1. Executar os passos 1–6 acima.
2. Decidir a repartição de disco antes de provisionar (§3.2) — **já decidida: 100/100**.

---

## 10. Ordem de execução

| # | Passo | Depende de | Esforço |
|---|---|---|---|
| 1 | Corrigir o path do health check do Traefik + `/api/ready` | — | horas |
| 2 | Uptime externo + heartbeat dos crons | 1 | horas |
| 3 | **Redação** (§7.3): `send_job`, serializador de erro do Ash, lint de CI | — | 1 dia |
| 4 | Decidir a repartição de disco **antes** de provisionar (§3.2) | — | minutos, irreversível depois |
| 5 | `LoggerJSON` + carimbo no `LoadScope` + consolidar em 1 evento + Oban logger | 3 | 1 dia |
| 6 | `handleError` no BFF | 3 | horas |
| 7 | Provisionar a VM `obs`; subir Loki + Grafana com R2 e retenção de 720 h | 4 | 1 dia |
| 8 | Alloy na VM do app, com os filtros de ruído da §2.1 | 5, 6, 7 | horas |
| 9 | `logging:` driver com rotação no compose | — | minutos |
| 10 | **Verificar a retenção no dia 31** | 7 | minutos, inadiável |

O passo 3 vem antes do 7 de propósito: enquanto o log não sai da máquina, um vazamento é local e
reversível. Depois que sai, não é.

---

## 10.1 O que já foi construído (2026-07-28)

Os passos 1, 3, 5, 6, 8 e 9 estão feitos e verificados contra a stack rodando. O que falta é
humano ou depende de provisionar a VM.

| # | Estado | Onde |
|---|---|---|
| 1 | **Feito** — `/api/ready` novo (banco + pool), `/api/health` vira liveness sem I/O, ambos fora do `:authenticated`; Traefik aponta para `/api/ready` | [`health_controller.ex`](../api/lib/api_web/controllers/health_controller.ex), [`router.ex`](../api/lib/api_web/router.ex), [`compose.dokploy.yml`](../compose.dokploy.yml) |
| 2 | **Pendente** — uptime externo + heartbeat dos crons (§9) | — |
| 3 | **Feito** — `send_job` loga a frase classificada; barreira coberta por teste que morde | [`send_job.ex`](../api/lib/api/messaging/send_job.ex), [`falhas_test.exs`](../api/test/api/messaging/falhas_test.exs) |
| 4 | **Pendente, e é decisão irreversível** — repartição de disco antes de criar os volumes (§3.2) | — |
| 5 | **Feito** — `logger_json`, carimbo no `LoadScope`, 1 evento por requisição, Oban falando | [`request_logger.ex`](../api/lib/api_web/request_logger.ex), [`load_scope.ex`](../api/lib/api_web/plugs/load_scope.ex), [`prod.exs`](../api/config/prod.exs) |
| 6 | **Feito** — `handleError` server + client, `POST /api/client-error`, 4 catches silenciosos eliminados | [`hooks.server.ts`](../web/src/hooks.server.ts), [`hooks.client.ts`](../web/src/hooks.client.ts), [`client-error/+server.ts`](../web/src/routes/api/client-error/+server.ts) |
| 7 | **Construído e rodando local**; falta provisionar a VM | [`deploy/observability/`](../deploy/observability/) |
| 8 | **Feito** — Alloy com allowlist de projeto, corte de ruído e redação | [`alloy.alloy`](../deploy/observability/alloy.alloy) |
| 9 | **Feito** — `json-file` com `max-size: 20m`, `max-file: 3` nos 6 serviços | [`compose.dokploy.yml`](../compose.dokploy.yml) |
| 10 | **Pendente** — verificar a retenção no dia 31 após ligar em produção | — |

### O que a execução ensinou (e o plano não previa)

Quatro achados que só apareceram por rodar, não por escrever:

**O `/api/ready` nasceu levando 21 segundos.** Passar `timeout:` para o `Ecto.Adapters.SQL` limita
a *query*, não a espera na fila do pool — e o DBConnection tem backoff adaptativo. Medido com o
Postgres pausado: `queue=17003ms` até o 503. Num endpoint batido a cada 10s isso empilha e vira
carga sobre um banco já doente. O teto passou a ser cravado por fora, com `Task.yield/2` +
`Task.shutdown/2`; remedido: **2,04s**, estável em chamadas repetidas.

**A allowlist do coletor não é preferência, é correção.** A primeira versão do Alloy filtrava por
lista negra (`drop` em "alloy|loki|grafana") e vazou duas classes de container: o próprio stack de
observabilidade — porque o regex do relabel é **ancorado** e não casa com `observability-alloy-1` —
e, pior, containers de **outros projetos** na mesma máquina (um `educatizzy-postgres` inteiro), já
que o agente lê o daemon do Docker e não um diretório. Virou allowlist por projeto do compose.

**Sanitizar o campo `route` dava a impressão de barreira sem a barreira.** No teste ponta a ponta,
`route` saiu corretamente como `/pacientes/:id` — e o **stack** foi inteiro, com o id do paciente
dentro (`at Ficha (/pacientes/019f7c5b-…)`). Todo stack de browser cita a URL da página. Faltava
sanitizar o texto livre, e isso não pode ser feito no coletor: uma redação de UUID sobre a linha
toda apagaria também `clinic_id` e `actor_id`, que o doc 05 §1.3 **permite** de propósito. A troca
tem de ser cirúrgica, de dentro da aplicação.

**A janela de rejeição do Loki mais curta que a retenção perde dado sem avisar.** Com
`reject_old_samples_max_age: 168h`, o agente reiniciado releu o histórico dos containers e mandou
lotes misturando entradas antigas e novas. O Loki responde **400 ao lote inteiro**, e o Alloy o
descarta por completo — matando junto as linhas válidas que vinham no mesmo pacote. O sintoma foi
o pior possível: stack de pé, `/ready` verde, e a consulta devolvendo vazio sem nada em lugar
nenhum dizendo que dado estava sendo perdido. Casar a janela com `retention_period` (720h) elimina
a classe inteira.

**Recusar sem registrar recria o problema que o plano existe para resolver.** A primeira versão do
`/api/client-error` devolvia 413 e esquecia. Mas o cliente trunca stack em 2 KB, então corpo acima
do teto significa cliente modificado, laço ou abuso — as três coisas que se quer saber. Agora recusa
**e** registra o tamanho, sem o conteúdo.

### 10.2 Como verificar — [`deploy/observability/verificar.sh`](../deploy/observability/verificar.sh)

Roda contra qualquer ambiente e cobre 21 asserções: health checks dos dois serviços, Grafana e
datasource, o log chegando de fato, as quatro barreiras de PII, os filtros de ruído, a retenção e
o readiness reprovando com o banco fora.

```bash
# local
./deploy/observability/verificar.sh

# produção
WEB=https://cinetra.com.br GRAFANA=https://grafana.exemplo \
GRAFANA_AUTH=admin:senha ./deploy/observability/verificar.sh

# inclui o teste destrutivo (pausa o banco por segundos)
PAUSAR_DB=1 ./deploy/observability/verificar.sh
```

**Escrever o verificador achou quatro defeitos que a inspeção não tinha achado** — todos da mesma
família: coisas que *pareciam* funcionar.

**A redação comia dado operacional.** O regex de CPF era `\d{3}\.?\d{3}\.?\d{3}-?\d{2}` — com todo
separador opcional e sem delimitador, ele casa com **qualquer corrida de 11 dígitos** e ainda
atravessa hífen. Medido: `verificar-1785259312-344832` (um timestamp unix) virou
`verificar-1[CPF]4832`. Pior que não redigir: destrói o dado **e** deixa um `[CPF]` sugerindo que
havia PII onde havia um id. Corrigido com delimitadores `\b` e separadores obrigatórios.

**A redação de telefone parecia funcionar e não funcionava.** No `stage.replace` o que é
substituído são os **grupos de captura**, não o match inteiro. Com grupos internos
(`(\+55…)?(\(\d{2}\)|\b\d{2})`), o resultado medido foi `fone [TELEFONE] 98765-4321`: só o DDD
saiu, o número ficou. Uma redação que aparenta ter funcionado é pior que nenhuma — ninguém relê a
linha. Corrigido com um único grupo externo e `(?:…)` por dentro.

**O próprio verificador passava por vazio.** Os quatro greps de PII rodavam sobre a resposta do
Loki; quando o evento não chegava, "não achei CPF" num corpo inexistente contava como aprovação.
Ele dizia "tudo verde" exatamente no cenário em que nada estava sendo verificado. Agora há uma
guarda: sem o evento localizado, a seção inteira reprova.

**E gritava lobo.** A leitura da config do Loki (~80 KB) expirou com timeout curto e o script
concluiu "retention não é 30d" com a config correta. "Não consegui checar" e "checado e errado"
são fatos diferentes; conflati-los é a mesma classe de erro do passe por vazio, na direção oposta.

> **Gotcha de operação:** editar um arquivo de config montado por bind mount e rodar
> `docker compose restart` **não** aplica a mudança — e no Docker Desktop/WSL o container nem
> volta (o inode do arquivo mudou e o mount quebra; sai com código 127). Use
> `docker compose up -d --force-recreate <serviço>`.

### 10.3 Dashboards

Três, provisionados **por arquivo** em [`deploy/observability/dashboards/`](../deploy/observability/dashboards/).
Painel montado na UI morre com o container, e a VM obs é descartável de propósito; em arquivo ele é
versionado, revisável em PR e reaparece igual depois de um `--force-recreate`.

| Dashboard | Responde |
|---|---|
| **Visão geral** | "dá para trabalhar agora?" — erros/min, requisições/min, p95, crashes de browser, status ao longo do tempo, últimos erros |
| **Requisições** | "onde foi o tempo e quem reclama?" — volume e p95 por rota, rotas que mais falham, volume por clínica, lista das lentas |
| **Erros e jobs** | as duas classes que sumiam — crash no browser (por origem e por tela) e jobs do Oban (executados e falhados) |

> **Continuado em [`73`](73-dashboards-do-log-ao-banco.md) (2026-07-29).** Estes três esgotam quase
> tudo que o log sabe responder. O doc 73 acrescenta sete dashboards e uma **segunda fonte** — o
> banco, por views `metrics_*` —, porque a pergunta que abriu este plano ("por que o lembrete não
> saiu na terça") continuava sem resposta: trabalho que **não** aconteceu não produz linha de log,
> produz linha parada numa tabela.

**Variável `$parser`** (`json` | `logfmt`): produção emite JSON, dev emite texto legível. Sem ela os
painéis da API só poderiam ser conferidos depois do deploy — e dashboard que só dá para verificar
em produção não é verificável. Com ela, os mesmos painéis foram exercitados em dev contra dado
real.

**Dois defeitos que só apareceram ao rodar os painéis:**

*O stat de p95 devolvia 115 séries.* `quantile_over_time(… | unwrap duration_ms […])` sem `by ()`
produz **uma série por combinação de labels** — e o painel, que é um número, viraria um emaranhado.
`by ()` agrega corretamente (42,7 ms medido). O atalho tentador, `max()` por fora, dá 177,8 ms:
é o máximo dos p95 por stream, não o p95 do conjunto — estaria errado e parecendo certo.

*A sintaxe de agrupamento estava no lugar errado.* `| unwrap duration_ms by (route) […]` não
agrupa; o `by` vai **depois** do range: `quantile_over_time(…[…]) by (route)`.

**O que não deu para verificar em dev:** os dois painéis de Oban. Nenhum job rodou na janela de
teste (`job:stop` não aparece no log de dev), então eles só se provam com tráfego real. Ficam
marcados aqui em vez de declarados prontos.

### 10.4 Como isso sobe no servidor

Tudo na **mesma máquina** (§3.1), em **dois** stacks do Dokploy — que não é o mesmo que "tudo num
deploy só", e a diferença é deliberada:

| Stack | Arquivo | Sobe quando |
|---|---|---|
| App (db · api · web · backup) | `compose.dokploy.yml` | push em `main` / `develop` |
| Observabilidade (loki · grafana · alloy) | [`compose.obs.yml`](../deploy/observability/compose.obs.yml) | quando a config de observabilidade mudar |

Separar os **stacks** (não as máquinas) é o que impede um deploy da aplicação de reiniciar a
coleta de log — inclusive o deploy que quebra e cujos logs você vai precisar ler.

**Um erro que custou uma rodada:** a primeira versão usava `profiles:` para escolher o que subia
em cada máquina. `--profile` é flag de linha de comando, e a UI do Dokploy não a passa — o coletor
ficaria fora do deploy automático e seria esquecido no primeiro redeploy, justamente o componente
que mais precisa acompanhar o app. Sem `profiles`, o arquivo sobe inteiro em qualquer ferramenta.

**Nomes de projeto explícitos** — e a diferença entre eles é funcional, não estética:

| Projeto | Arquivo | Containers |
|---|---|---|
| `cinetra` | `docker-compose.yml` (dev) / `compose.dokploy.yml` (prod, ×2 ambientes) | `cinetra-api-1`, `cinetra-db-1`, `cinetra-web-1` |
| `cinetra-obs` | `compose.obs.yml` | `cinetra-obs-loki-1`, `cinetra-obs-grafana-1`, `cinetra-obs-alloy-1` |

A allowlist do agente (`OBS_PROJETOS=cinetra`) usa a regex do relabel, que é **ancorada**: `cinetra`
casa só com `cinetra`, nunca com `cinetra-obs`. É essa âncora que impede o Loki de coletar a si
mesmo — o log da ferramenta de log consumindo a retenção do produto. Um curinga como `cinetra.*`
quebraria isso.

*(Antes de 2026-07-28 o projeto de dev herdava o nome do diretório, `moving`. Fixá-lo no compose
desacopla os nomes do caminho onde o repositório foi clonado, ao custo de recriar os volumes —
o banco de desenvolvimento é perdido no rename.)*

**Projeto separado ≠ máquina separada.** Os dois rodam no mesmo servidor; o que a separação compra
é ciclo de vida próprio. Fundir também não seria possível: o Dokploy sobe o `compose.dokploy.yml`
duas vezes (prod e HML), e a observabilidade lá dentro viraria dois Lokis e dois Grafanas.

**Editou config? `--force-recreate`, não `restart`.** Bind mount de arquivo único não é recriado
por `restart` — e no Docker Desktop/WSL o container nem volta (sai com código 127).

### Achado fora de escopo, de segurança

Ao instalar a dependência, o `mix hex.audit` acusou **`bandit` 1.12.0 com CVE-2026-65623 (HIGH)** —
blow-up quadrático de CPU ao remontar mensagens WebSocket fragmentadas. Importa aqui porque o
projeto **expõe WebSocket publicamente** (`/socket` é um dos dois paths que chegam à API pelo
Traefik), o que torna a falha um vetor de DoS remoto alcançável. Corrigido subindo para **1.12.4**;
o `mix hex.audit` passou a devolver limpo. Vale acrescentar `mix hex.audit` ao CI — este achado foi
acidental, e o próximo pode não ser.

---

## 11. Usando o Grafana: achar problema, alertar, medir latência

### 11.1 Achar problema — o caminho de sempre

Sempre o mesmo funil, e a ordem importa porque cada passo reduz o volume do seguinte:

1. **"Cinetra · Visão geral"**, últimas 6 h. Quatro números respondem "há incidente?".
2. O número que acendeu diz **onde olhar**: erro 5xx → *Requisições*; crash → *Erros e jobs*;
   p95 → *Requisições · Rotas mais lentas*.
3. No dashboard de detalhe, **agrupe** — por rota, por clínica, por origem. Uma rota isolada é bug
   localizado; várias juntas é infra; uma clínica só costuma ser dado daquela clínica.
4. **Explore** (menu lateral) para a linha bruta. Comece estreito e afrouxe:
   `{env="prod", level="error"}` → `| json` → `| clinic_id="..."`.
5. Peguei uma linha ruim? O `request_id` dela amarra **todas** as linhas daquela requisição:
   `{env="prod"} |= "GMZfOQmO363e6FUABILB"`.

Filtre **primeiro por label** (`env`, `service`, `level`) e só depois por conteúdo. Label estreita
para poucos streams; `|=` e `| json` trabalham sobre o que sobrou. A ordem inversa varre tudo.

### 11.2 Latência — o que dá para medir hoje, e o que não

**Dá:** latência de *aplicação*, por requisição, do campo `duration_ms`.

```logql
# p95 geral — `by ()` agrega. SEM ele vêm ~115 séries, uma por combinação de labels.
quantile_over_time(0.95, {env="prod", service=~".*api.*"} | json | unwrap duration_ms [5m]) by ()

# as 10 rotas mais lentas
topk(10, quantile_over_time(0.95, {env="prod", service=~".*api.*"} | json | route != ""
     | unwrap duration_ms [5m]) by (route))

# quem está esperando: as requisições acima de 1s, com clinic_id e actor_id
{env="prod", service=~".*api.*"} | json | duration_ms > 1000
```

**Não dá — e isto é uma lacuna real, não um detalhe.** "Latência do servidor" no sentido de
**CPU, memória, I/O de disco, saturação de rede, pool do Postgres** não está aqui. Log registra o
que a aplicação fez; não registra o estado da máquina. Um p95 subindo mostra o *sintoma*, e sem
métricas de host não dá para dizer se a causa foi CPU saturada, disco lento ou o banco.

Fechar isso é a **fase de métricas**: `node_exporter` (host) + PromEx (BEAM, Ecto, Oban) →
Prometheus, na mesma máquina e no mesmo Grafana. É o doc irmão, e o dimensionamento da §3.2 já
reservou memória para ele.

### 11.3 Validar que o Loki está sendo ALIMENTADO

**"De pé" e "recebendo" são perguntas diferentes**, e a diferença custou duas depurações num só
dia: Loki `healthy`, `/ready` 200, Grafana no ar — e nada chegando. Liveness não detecta ausência
de dado. Três contadores detectam, e a comparação entre eles diz **onde** quebrou:

| Contador | Onde | Significa |
|---|---|---|
| `loki_source_docker_target_entries_total` | Alloy | o agente **leu** N linhas do daemon do Docker |
| `loki_write_dropped_entries_total` | Alloy | o agente **não conseguiu entregar** N (com `reason`) |
| `loki_distributor_lines_received_total` | Loki | o Loki **recebeu** N |

Leitura sem descarte e sem recepção = a rede entre agente e Loki. Leitura zero = allowlist
(`OBS_PROJETOS`) errada ou socket inacessível. Descarte alto = lote recusado — foi assim que
**25.577 entradas sumiram** com `reject_old_samples_max_age` menor que a retenção.

As portas de métrica não são publicadas (nem devem ser); a leitura passa por dentro do container:

```bash
D="docker compose -f deploy/observability/compose.obs.yml --env-file deploy/observability/.env.local"

$D exec -T loki wget -qO- http://localhost:3100/metrics | grep loki_distributor_lines_received_total
$D exec -T loki wget -qO- http://alloy:12345/metrics    | grep -E 'loki_(source_docker_target_entries|write_dropped_entries)_total'
```

**Contador é cumulativo — o que alarma é o delta.** Um descarte antigo já resolvido deixaria a
checagem vermelha para sempre. O `verificar.sh` §9 mede a janela: reporta o total como *contexto*
e o crescimento em 10 s como *alarme*.

**E o sinal do dia a dia é FRESCOR, não contagem.** O contador pode crescer com o agente horas
atrás relendo backlog — a consulta devolve o passado sem avisar. O verificador compara o timestamp
da linha mais recente com o relógio; acima de 2 min, reprova.

```bash
deploy/observability/verificar.sh    # seção 9 cobre os quatro sinais
```

### 11.3.1 "Não vejo nada no Loki" — o diagnóstico

A pergunta se divide em duas, e confundi-las manda investigar o lugar errado:

**Está gravando?** Olhe os arquivos, não a interface:

```bash
D="docker compose -f deploy/observability/compose.obs.yml --env-file deploy/observability/.env.local"
$D exec -T loki sh -c 'find /loki/chunks -type f | wc -l; du -sh /loki/chunks /loki/index /loki/wal'
```

Chunks existindo + `verificar.sh` §9 verde = o pipeline está bem, e o problema é de **consulta**.

**A consulta está olhando para o lugar certo?** As duas causas mais comuns, e as duas foram
defeito meu:

- **`env` errado.** Os dashboards nasceram com `env = prod` fixo. Numa instalação onde só existe
  `dev`, todo painel abre vazio e parece quebrado. Agora `env` é **variável de consulta**
  (`label_values(env)`): o Grafana pergunta ao Loki quais ambientes existem e preenche sozinho —
  o dashboard se adapta ao que há, em vez de ao que se esperava haver.
- **`parser` errado.** Produção emite JSON, dev emite texto. Painel de API com `json` num ambiente
  que loga `logfmt` volta vazio sem erro. O seletor está no topo do dashboard.

Confira o que existe antes de suspeitar do pipeline:

```bash
curl -su admin:SENHA localhost:3300/api/datasources/proxy/uid/loki/loki/api/v1/label/env/values
```

### 11.4 Alertas — cinco, provisionados

Em [`grafana-alertas.yml`](../deploy/observability/grafana-alertas.yml), por arquivo pela mesma
razão dos dashboards. **Regra montada na UI não sobrevive a recriar o container** — e alerta é
justamente o que precisa de revisão em PR, porque limiar errado treina a equipe a ignorar o aviso.

| Alerta | Dispara com | `for` | Por que esse `for` |
|---|---|---|---|
| **Pipeline de log parado** | 0 linhas em 10 min | 10m | o alerta que este projeto aprendeu a precisar — ver §11.3 |
| Erros 5xx | > 10 em 5 min | 5m | pico de 30 s é deploy ou blip, não incidente |
| Latência p95 | > 1 s | 10m | o alvo é 400 ms; 1 s é quando a recepção sente |
| Crashes no browser | > 5 em 15 min | 15m | crash isolado é navegador estranho; rajada é deploy ruim |
| Job do Oban falhando | > 3 em 10 min | 10m | complementa o heartbeat: aqui o job **rodou** e falhou |

O `for` é o que separa alerta de ruído: a condição precisa **persistir** para disparar.

**Estes quatro não cobrem "morreu" nem "parou de rodar"** — os dois vivem no monitor externo (§9),
porque alerta hospedado na máquina que caiu não é enviado. Duas camadas, nenhuma substitui a outra.

**Antes de confiar:** configure o contato (`GF_SMTP_*` no compose, ou um webhook) e **prove que
chega**. Alerta que dispara e fica só na tela é painel, não alerta.

**`noDataState` é metade da regra, e eu errei nas cinco.** Com o padrão do Grafana, uma consulta
sem resultado vira um `DatasourceNoData` **permanente** — medido: quatro alertas falsos ativos numa
instalação sem tráfego de `prod`, dentro do arquivo que este plano usa para pregar contra alarme
falso. A correção não é silenciar, é dizer o que a ausência significa em cada caso:

- nas quatro regras de comportamento (5xx, latência, crashes, jobs), *sem dado* = **sem erro** →
  `noDataState: OK`;
- em "Pipeline de log parado", *sem dado* **é** o sintoma → `noDataState: Alerting`.

E esse último não pode fixar `env="prod"`: a pergunta é "chegou log de **algum** lugar?". Fixado,
ele acende sozinho em toda instalação que não seja produção.

> Um arquivo de alerta inválido **impede o Grafana de subir** — medido: um `labels:` aninhado no
> lugar errado derrubou o container inteiro. É a falha alta certa (melhor que subir sem alerta
> nenhum), mas depois de editar, confira que o serviço voltou.

## 12. O que este plano não faz

- **Métricas e tracing.** Ficam para o doc irmão. A ordem é deliberada: com log estruturado
  carregando `request_id` e `clinic_id`, respondem-se quase todas as perguntas de diagnóstico sem
  trace nenhum — e trace é o item de maior custo, menor ganho marginal com apenas dois serviços, e
  **maior superfície de vazamento** (todo atributo de span é dado exportado). O Prometheus está
  reservado no dimensionamento da §3.2 para que a fase seguinte não exija redimensionar a VM.

  > **Os dois foram construídos depois** — métricas no [doc 74](74-signoz-vs-hyperdx.md) e traces
  > no [doc 76](76-traces.md), ambos no mesmo Grafana, como esta seção previa. Sobre o argumento
  > do vazamento: ele valia contra SaaS, e o desenho escolhido não é esse — o span passa pelo
  > **mesmo Alloy** que já processa este log e para num volume da mesma máquina. O que sobrou do
  > argumento é volume de detalhe, tratado por poda de atributos no agente (doc 76 §4).
- **RUM / telemetria de browser.** Fora de escopo pelo [`05` §1.2](05-observabilidade-e-producao.md)
  — o risco é justamente vazar identificador para script de terceiro.
- **Mexer no nível do Ecto.** Ver §1.
