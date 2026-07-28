# 62 — Plano de logs: agregação, retenção de 30 dias e dimensionamento

> Plano de execução, 2026-07-28. Fecha a primeira das lacunas levantadas em
> [`05-observabilidade-e-producao.md`](05-observabilidade-e-producao.md), que segue como intenção
> desde antes de existir código. Escopo deste documento: **logs**. Métricas e tracing ficam para
> um doc irmão — a ordem é deliberada e está justificada na §11.

O estado de hoje em uma frase: o log é texto plano no stdout de um container, sem agregação, sem
retenção e sem ninguém olhando. Se a API cair de madrugada, o motivo está numa máquina que talvez
já tenha reiniciado. Este plano troca isso por uma agregação com 30 dias de retenção, rodando
**fora da caixa que ela observa** e **dentro do país**.

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

### 3.1 Duas VMs, não uma

A cota Always Free do Ampere A1 é **4 OCPU + 24 GB**, e pode ser dividida em até 4 instâncias
(confirmar no console da OCI antes de provisionar — os termos do free tier mudam). A divisão
recomendada, que mantém tudo em Vinhedo e custa R$ 0:

| VM | Shape | Papel |
|---|---|---|
| `app` | **3 OCPU / 18 GB** | Dokploy, Traefik, Postgres, API + web de prod e de HML |
| `obs` | **1 OCPU / 6 GB** | Loki, Grafana, Prometheus (quando a fase de métricas chegar) |

O A1 usa shape flexível na proporção de 6 GB por OCPU, então essa divisão é a natural.

**Por que não na mesma máquina.** Observabilidade que roda junto com o app fica cega exatamente
quando é necessária: OOM, disco cheio, crash loop, daemon do Docker travado. Esses são os modos de
falha mais prováveis numa máquina que já vai hospedar prod + HML + Postgres + Traefik — o próprio
[`59`](59-deploy-dokploy-oci.md) lista disco/memória como risco #5. A segunda VM não protege contra
a região inteira cair, e não precisa: esse caso é coberto pela camada externa da §9.

**18 GB sobram para o app?** Sobram. O consumo é da ordem de 1–2 GB de Postgres, 300–500 MB por
release Elixir, 150–300 MB por instância de SvelteKit, ~100 MB de Traefik e ~1 GB do Dokploy. O pico
real é o **build** da imagem Elixir, que é guloso; 18 GB absorve com folga.

### 3.2 Memória e disco da VM de observabilidade

| Componente | RAM em regime | Nota |
|---|---|---|
| Loki (single binary, monolítico) | 512 MB – 1 GB | Ingestão neste volume é trivial; o pico é consulta longa |
| Grafana | 256 – 512 MB | |
| Prometheus *(fase de métricas)* | 1 – 1,5 GB | Reservado agora para não precisar redimensionar depois |
| SO + daemon do Docker | 700 MB – 1 GB | |
| **Total em regime** | **≈ 3–4 GB** | Sobra em 6 GB deixa a porta aberta para o Tempo (traces) depois |

O agente coletor roda na **VM do app**, não nesta: some **128–256 MB** lá.

**Disco — a restrição escondida.** O Always Free dá **200 GB de block storage no total, somados
todos os volumes**. O [`59`](59-deploy-dokploy-oci.md) planejou 100–150 GB pensando em uma máquina
só; com duas, esse número precisa encolher. A repartição recomendada:

| VM | Boot volume | Consumo previsto |
|---|---|---|
| `app` | **100 GB** | imagens Docker de 2 ambientes, build cache, `pgdata`, logs locais rotacionados |
| `obs` | **100 GB** | SO + Docker ~10 GB · Loki ≤ 10 GB (teto de projeto) · Prometheus ~10 GB · folga |

**Decidido meio a meio (2026-07-28).** Cabe nos dois lados com folga larga: a `obs` usa ~30 GB dos
100 mesmo no teto do projeto, e a `app` fica na casa dos 30 GB em regime. A folga da `obs` não é
desperdício — é o que permite esticar a retenção ou acrescentar o Tempo (traces) depois sem
redimensionar nada.

A variável de verdade do lado da `app` não é o dado, é o **build cache do Docker**: o Dokploy
constrói na própria máquina, e release Elixir de dois ambientes acumula rápido. O
`docker system prune` agendado que o [`59`](59-deploy-dokploy-oci.md) já prevê (risco #5) deixa de
ser higiene e passa a ser o que mantém os 100 GB confortáveis.

Isso é uma **mudança ao `59`**, não um detalhe: provisionar a VM do app com 150 GB inviabiliza a
segunda VM sem pagar. E é **porta de mão única** — volume de boot na OCI cresce mas não encolhe, e
com o total travado em 200 GB não há de onde tirar depois. Decidir antes de criar.

### 3.3 Se o objeto de armazenamento for o R2

Recomendado: **os chunks do Loki vão para o R2**, não para o disco da VM. Três razões, e nenhuma é
espaço:

1. A VM de observabilidade vira **descartável**, igual à filosofia de máquina descartável que o
   [`59` §13](59-deploy-dokploy-oci.md) já adota para o app. Perder a VM deixa de perder os 30 dias.
2. O projeto **já usa R2** e já tem o padrão de bucket dedicado com chave escopada — anexos de
   paciente ([`51`](51-ficha-anexos-e-storage.md)) e dumps do banco. Um bucket a mais, `logs`, com
   credencial própria, não abre superfície nova.
3. Jurisdição: log é estritamente **menos** sensível que o que já está lá (o dump tem CPF). A decisão
   de usar R2 já foi tomada e aceita pelo projeto; isto não a reabre.

Com o R2 atrás, o disco da `obs` guarda só índice e cache — o que reduz o consumo de Loki na VM para
poucos GB mesmo no teto.

---

## 4. A stack

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

**Passo 2 — dois projetos no healthchecks.io: `cinetra-prod` e `cinetra-hml`.**

Projetos separados, não checks separados dentro de um só. É o que dá **uma chave por ambiente** —
e o que impede o erro caro: se prod e HML compartilhassem check, o sinal do HML manteria tudo
verde com a produção morta.

**Passo 3 — sete checks em cada projeto.** O **nome do check tem de ser exatamente o slug** da
tabela: é assim que a URL é endereçada. *Period* é de quanto em quanto tempo o sinal deve chegar;
*Grace* é a tolerância antes de alarmar — precisa cobrir a duração normal do job mais a variação,
senão a primeira execução lenta vira alarme falso.

| Slug (= nome do check) | Period | Grace | Quem sinaliza |
|---|---|---|---|
| `backup` | 1 h | 20 min | `backup.sh` |
| `reminder` | 1 h | 15 min | `Api.Messaging.ReminderJob` |
| `digest` | 1 h | 15 min | `Api.Notifications.DailyDigestJob` |
| `session-soon` | 5 min | 5 min | `Api.Notifications.SessionSoonJob` |
| `prune-trail` | 1 dia | 2 h | `Api.Housekeeping.PruneTrail` |
| `prune-notifications` | 1 dia | 2 h | `Api.Housekeeping.PruneNotifications` |
| `prune-attachments` | 1 dia | 2 h | `Api.Housekeeping.PruneAttachments` |

**Passo 4 — UMA variável por ambiente.** Em *Project Settings → Ping Key*, gere a chave do
projeto. No Dokploy, no stack correspondente:

```
HEARTBEAT_BASE_URL=https://hc-ping.com/<ping-key-do-projeto>
```

O código monta o resto: `<base>/<slug>` no sucesso e `<base>/<slug>/fail` quando o job estoura. São
**2 variáveis no total** (uma por stack) em vez de 14 colagens de UUID — e o que distingue produção
de homologação passa a ser a chave, não a disciplina de não errar nenhuma.

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

### Achado fora de escopo, de segurança

Ao instalar a dependência, o `mix hex.audit` acusou **`bandit` 1.12.0 com CVE-2026-65623 (HIGH)** —
blow-up quadrático de CPU ao remontar mensagens WebSocket fragmentadas. Importa aqui porque o
projeto **expõe WebSocket publicamente** (`/socket` é um dos dois paths que chegam à API pelo
Traefik), o que torna a falha um vetor de DoS remoto alcançável. Corrigido subindo para **1.12.4**;
o `mix hex.audit` passou a devolver limpo. Vale acrescentar `mix hex.audit` ao CI — este achado foi
acidental, e o próximo pode não ser.

---

## 11. O que este plano não faz

- **Métricas e tracing.** Ficam para o doc irmão. A ordem é deliberada: com log estruturado
  carregando `request_id` e `clinic_id`, respondem-se quase todas as perguntas de diagnóstico sem
  trace nenhum — e trace é o item de maior custo, menor ganho marginal com apenas dois serviços, e
  **maior superfície de vazamento** (todo atributo de span é dado exportado). O Prometheus está
  reservado no dimensionamento da §3.2 para que a fase seguinte não exija redimensionar a VM.
- **RUM / telemetria de browser.** Fora de escopo pelo [`05` §1.2](05-observabilidade-e-producao.md)
  — o risco é justamente vazar identificador para script de terceiro.
- **Mexer no nível do Ecto.** Ver §1.
