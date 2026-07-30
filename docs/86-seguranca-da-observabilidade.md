# O que a observabilidade custou em segurança — análise honesta

Análise do perímetro **depois** de trazer o stack `cinetra-obs` (Loki, Grafana, Alloy, Prometheus,
node-exporter, cAdvisor, Tempo — docs [62](62-plano-de-logs.md), [73](73-dashboards-do-log-ao-banco.md),
[74](74-metricas-do-servidor.md), [76](76-traces.md)).

Não é um bate-volta do diff: o [doc 77](77-bate-volta-observabilidade-e-pacotes.md) já fez isso e
achou o que achou (senha do role de métricas num default publicado, `--web.enable-admin-api`
ligada). Aqui a pergunta é outra e mais desconfortável: **o que passou a ser possível na máquina
que não era antes**, independentemente de haver bug no diff. As duas listas quase não se cruzam —
o doc 77 varreu código novo, e a maior parte do que está abaixo é consequência de *topologia*, que
diff nenhum acende.

Tudo que está marcado como **medido** foi medido em 2026-07-29 contra o stack de dev rodando. O que
não foi, está dito.

---

## 1. O tamanho da mudança, em uma frase

Antes: **dois** processos alcançáveis pela internet (Traefik → `web`/`api`), nenhum com acesso ao
host.

Depois: os mesmos dois, **mais sete serviços de longa duração** na mesma máquina — três deles com o
sistema de arquivos do host montado, um deles com o socket do Docker, e **um deles publicando porta**.

O saldo não é "ficou menos seguro porque tem mais coisa". É mais específico: o stack de
observabilidade é, por natureza, **o componente que lê tudo**. Ele foi projetado para atravessar as
fronteiras que o resto do sistema passou dois meses erguendo (RLS, policies, escopo por tenant), e
por isso comprometê-lo vale mais do que comprometer a aplicação. A RLS que protege 100 clínicas não
protege nada de quem lê o log das 100.

---

## 2. Os achados, por severidade

### A1 — `docker.sock:ro` no Alloy é root na máquina, e o `:ro` não faz o que o comentário diz (ALTO, **medido**)

O `compose.obs.yml` monta o socket do Docker no Alloy e justifica assim:

> Somente leitura no socket do Docker. O agente precisa LER os logs; não precisa criar, parar nem
> inspecionar segredo de container nenhum. Socket do Docker montado com escrita é equivalente a root
> na máquina.

A última frase está certa. A primeira não protege: **`:ro` é uma flag do *arquivo* de socket, não da
API que trafega por ele.** Socket unix é bidirecional; o `ro` impede alterar o inode, não impede
mandar `POST`. Medido, através de um socket montado exatamente como o do Alloy:

```
POST /v1.44/containers/create  →  HTTP 400
{"message":"config cannot be empty in order to create a container"}
```

**400, não 403.** O handler de criação foi alcançado e recusou por corpo vazio — a permissão nunca
foi questionada. Com um corpo válido (`Binds: ["/:/host"], Privileged: true`) o resultado é root no
host. E o Alloy roda como **uid 0** dentro do container (medido: `uid=0(root)`), com o socket
gravável (`test -w` passa) apesar do `ro` no `/proc/mounts`.

A segunda metade é pior porque não precisa nem de escrita. `GET /containers/<id>/json` devolve o
`Env` de qualquer container. Medido contra `cinetra-api-1`, saíram em texto claro: as duas senhas do
Postgres (`DATABASE_PASSWORD`, `DATABASE_APP_PASSWORD`) e **as duas chaves do R2**
(`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) — as mesmas que assinam as URLs dos anexos de paciente
([doc 51](51-ficha-anexos-e-storage.md)). Em produção sairia junto `SECRET_KEY_BASE`, o token do Zernio e a
`METRICS_DB_PASSWORD`. Ou seja: "não precisa inspecionar segredo de container nenhum" descreve uma
intenção que **nada aplica**.

Por que isso importa mais do que parece: o Alloy é o serviço que **parseia entrada influenciável pelo
atacante**. Ele roda regex (`stage.replace`, `stage.drop`) sobre linhas de log que vêm de uma
aplicação de internet, e recebe OTLP anônimo (A5). A cadeia é: requisição maliciosa → linha de log
ou span → bug de parser/ReDoS no Alloy → socket do Docker → **root no host, com todos os segredos e
o banco ao lado**. Cadeia longa (por isso ALTO e não CRÍTICO), impacto total.

O consolo honesto: essa mesma máquina já roda o Dokploy, que tem o socket por definição. O
argumento "já tinha um" é real, mas o Dokploy não parseia texto vindo da internet — a diferença é
essa, e é a única que conta.

**O que fazer** (em ordem de preferência):

1. **Socket proxy** — um `tecnativa/docker-socket-proxy` na frente, com `CONTAINERS=1` e todo verbo
   de escrita em `0`. Um container a mais, mantém o `discovery.docker` funcionando, mata o vetor de
   escrita. Custo: baixo. Resíduo: `GET /containers/{id}/json` continua sendo necessário para os
   labels do compose, então **o vazamento de `Env` permanece**.
2. Para o resíduo, a única solução real é **os segredos da aplicação deixarem de morar em `Env`** —
   `secrets:` do compose / arquivos montados, lidos pelo `runtime.exs`. Isso é uma decisão de
   tamanho médio, não um ajuste; vale abrir como débito separado em vez de embutir aqui.
3. Alternativa que dispensa o socket: `loki.source.file` sobre
   `/var/lib/docker/containers/*/*-json.log:ro`. Perde-se o enriquecimento por label do compose —
   isto é, a allowlist `OBS_PROJETOS` deixa de existir na forma atual. Provavelmente não vale.

### A2 — o Grafana publica porta, e a segunda camada de firewall não o cobre (ALTO)

O Grafana é o **único** serviço do stack com `ports:`, e ele publica em `0.0.0.0` (medido em dev:
`0.0.0.0:3300->3000/tcp, [::]:3300->3000/tcp`). Todo o resto usa `expose:`, corretamente.

O problema é o que o [doc 59 §4](59-deploy-dokploy-oci.md) promete como defesa em profundidade:

> O OCI tem **dois firewalls independentes**, e a porta precisa estar aberta **nos dois**.

Para porta publicada por container isso **não vale**. O Docker faz DNAT em `nat/PREROUTING` e libera
em `FORWARD` via a chain `DOCKER`, inserida no topo — o tráfego **nunca passa pela chain `INPUT`**,
que é onde ficam as regras restritivas que a imagem Ubuntu da Oracle traz. Portanto o segundo
firewall é decorativo aqui: **quem protege o Grafana é só a security list da VCN.** Um `allow` largo
aberto para depurar qualquer coisa põe o Grafana na internet, e o "mas o iptables ainda barra" que o
doc 59 autoriza a pensar é falso nesse caso específico. (Não medido na VM de produção — é o
comportamento padrão do Docker com `iptables: true`; confirmar com `iptables -t nat -L DOCKER -n` no
primeiro deploy.)

E o que estaria na internet: Grafana em **HTTP puro** (o TLS só existe se ele entrar atrás do
Traefik), com **usuário e senha únicos**, sem MFA e sem limite de tentativas.

**Bônus de colisão:** o default é `GRAFANA_PORT=3000`, e o doc 59 §4 registra `3000` como a porta do
**painel do Dokploy**. Subir o stack de obs em produção sem definir `GRAFANA_PORT` dá conflito de
bind — e o modo de falhar ruim é alguém "consertar" mexendo no painel em vez de no Grafana.

**O que fazer:** tirar `ports:` do Grafana e alcançá-lo por (a) Traefik com TLS + host próprio, ou
(b) `127.0.0.1:3300:3000` + túnel SSH / Tailscale. Se ficar publicado, `GRAFANA_PORT` explícito,
nunca 3000.

### A3 — o `secret_key` do Grafana é o default publicado (MÉDIO, **medido**)

`GF_SECURITY_SECRET_KEY` não é definida. Medido dentro do container:

```
/usr/share/grafana/conf/defaults.ini:371:secret_key = SW2YcwTIb9zpOOhoPsMm
env | grep SECRET_KEY  →  (vazio)
```

Esse valor é o mesmo em toda instalação do Grafana do mundo, e é a chave que cifra o
`secureJsonData` no `grafana.db` — hoje, a **senha do `cinetra_metrics`** e a senha do SMTP. Logo:
qualquer cópia do volume `grafana_data` (backup, snapshot da VM, `docker cp`) entrega essas senhas
sem esforço. É a mesma classe de achado do §5.2 do doc 77 — segredo protegido por um default
conhecido — só que uma camada abaixo, e o doc 77 não olhou aqui.

**O que fazer:** `GF_SECURITY_SECRET_KEY` com `:?` (mesma postura do admin e do
`METRICS_DB_PASSWORD`), valor aleatório de 32+ bytes. Trocar a chave invalida os segredos já
cifrados, então faça antes do primeiro deploy — ou reprovisione as datasources depois.

### A4 — o Grafana é a ponte entre o plano de observabilidade e o plano de dados (MÉDIO, por desenho)

O Grafana entra em duas redes: `obs` e, em produção, `data` — a rede que o próprio
`compose.dokploy.yml` documenta como *"só db + migrate + api — o web NÃO entra"*.

Isto é necessário (é como ele lê as views) e é o inverso de uma promessa do resto da arquitetura: o
serviço exposto ao operador humano ganhou acesso à rede que o serviço exposto à internet não tem.
Consequências concretas de um Grafana comprometido (por A2 ou por CVE — o histórico do Grafana em
authn bypass e path traversal não é curto):

- **SSRF autenticado para dentro da rede `data`**: admin do Grafana cria datasource nova apontando
  para qualquer coisa alcançável — `api:4000`, `api:4021`, o próprio Postgres. As datasources
  provisionadas são `editable: false`, o que não impede **criar outras**.
- **A senha do `cinetra_metrics`** (agravada por A3).
- **Leitura agregada de todas as clínicas** — ver §3.

**O que fazer:** aceitar a ponte (não há alternativa boa) e tratar o login do Grafana como **conta
privilegiada**, não como login de dashboard: senha longa e única no gerenciador, MFA se for publicado
(exige OAuth/OIDC no Grafana — o admin local não tem MFA), e nenhum acesso "só para dar uma olhada"
distribuído para a equipe. Se um dia houver mais de um humano lendo painel, aí vale
`GF_AUTH_ANONYMOUS` desligado (já está) + usuários com papel `Viewer`, que não criam datasource.

### A5 — ingestão anônima e leitura de métrica alcançáveis pelo container de internet (MÉDIO, **medido**)

`expose:` é documentação, não controle: quem está na mesma rede alcança qualquer porta. Medido de
dentro do `cinetra-web-1` — o container que atende a internet:

| destino | resultado | leitura |
| --- | --- | --- |
| `grafana:3000/login` | **HTTP 200** | tela de login alcançável de dentro |
| `alloy:4318/v1/traces` | **HTTP 405** (GET não permitido) | a porta responde → `POST` de span funciona |
| `prometheus:9090/-/healthy` | **HTTP 200** | API de consulta inteira alcançável |
| `loki:3100/ready` | sem resposta | segmentação funcionou |
| `tempo:3200/ready` | sem resposta | idem |
| `cadvisor:8080/healthz` | sem resposta | idem |

Em **produção** o mapa muda e não melhora: `web` está em `[app, dokploy-network]`, então continua
alcançando o Alloy (rede `app_otlp`) e o Prometheus (`app_metrics` = `dokploy-network`). O Grafana
sai do alcance do `web` (fica em `data`) — mas o Prometheus fica na `dokploy-network`, que é
**compartilhada pela máquina inteira**: todo container de todo stack o alcança.

Nem o Alloy nem o Loki nem o Tempo autenticam (`auth_enabled: false` no Loki, receptor OTLP sem
credencial). O que isso permite a partir de um `web` comprometido:

- **Envenenar a trilha** — empurrar spans e linhas forjadas, sujando a única fonte que se usaria
  para reconstruir o incidente.
- **Apagar a janela do incidente por diluição** — inundar até estourar
  `max_global_streams_per_user`/retenção e empurrar para fora o período que interessa. Note que o
  Prometheus perdeu a `admin-api` (doc 77 §5.3) justamente contra o apagamento *direto*; a diluição
  é a versão barata e continua aberta.
- **Reconhecimento** — a API do Prometheus entrega inventário: alvos, rotas, filas do Oban, volume
  por endpoint, versões.

Isto é integridade e disponibilidade de *evidência*, não confidencialidade de dado clínico. E a
mitigação principal já existe por decisão anterior: **a trilha com valor legal é a tabela
`audit_events` no Postgres, com backup horário** ([doc 63](63-auditoria-completa.md)) — não o Loki.
Vale escrever que isso deixou de ser só elegância arquitetural e passou a ser a defesa deste vetor.

**O que fazer:** aceitar, e registrar que log/trace **não são prova**. Se um dia importar, o caminho
é `basic_auth` no receptor OTLP do Alloy + `X-Scope-OrgID`/proxy autenticado na frente do Loki. Não
recomendo agora: o custo de operação é real e o ganho, dado que a trilha legal está no banco, é
pequeno.

### A6 — os traces não têm redação nenhuma, e são o sinal mais sensível do stack (MÉDIO)

Aqui a análise honesta contraria a impressão que o repositório passa. A redação de PII é
caprichada — três estágios no `alloy.alloy`, com regex corrigida a partir de erro medido (o
`\b` que impedia comer timestamp), e o comentário certo de que "uma redação que PARECE ter
funcionado é pior que nenhuma".

**Mas ela só existe no pipeline de log.** O pipeline de trace, no mesmo arquivo, tem a poda
**comentada de propósito**:

```
// ---- O LUGAR DA PRÓXIMA PODA ----
//     otelcol.processor.transform "poda" { ... delete_key(attributes, "url.path") ... }
// Deixado como comentário DE PROPÓSITO
```

A justificativa (processador vazio é código morto que parece proteção) é boa. O efeito colateral é
que, hoje, o Tempo guarda por 7 dias, sem redação:

- **`url.path` com os UUIDs na rota** — `/api/patients/<uuid>`, `/api/appointments/<uuid>`. Cruzado
  com o span do BFF, isso é **"qual usuário abriu a ficha de qual paciente, quando"**. É a mesma
  informação que a trilha de auditoria trata como sensível e redige — só que aqui sem policy, sem
  RLS e sem redação, atrás de um login de Grafana.
- A sequência completa de chamadas de cada requisição.

O que **não** vaza, e é um acerto: `db.statement` do `OpentelemetryEcto` é **parametrizado**, o valor
não viaja (o doc 77 já tinha checado isso).

Também vale dizer o que a redação de log **não** cobre, porque a lista de três formatos (CPF,
e-mail, telefone) é uma *denylist*: **nome de paciente não é redigido**, nem endereço, nem texto
livre (`fila.obs`, motivo de cancelamento). A primeira camada — allowlist na origem — é quem
sustenta isso, e ela é boa; mas a terceira camada existe justamente porque a primeira falha, e para
nome ela não existe. Um `dbg/1` esquecido num changeset de paciente sai inteiro.

**O que fazer:** ligar a poda que já está escrita ali. `url.path` sai, `http.route`
(parametrizada) fica — é ela que responde as perguntas de performance de verdade. Isso derruba a
sensibilidade do Tempo de "quem viu qual ficha" para "qual rota estava lenta", que é o que se quis
comprar. Cinco linhas, já redigidas, comentadas no arquivo.

### A7 — cAdvisor e node-exporter: o segundo caminho para os mesmos segredos (BAIXO)

Crédito onde é devido: o cAdvisor roda **sem `privileged`**, contra a recomendação da própria
documentação dele, e com justificativa escrita. É a decisão certa e não é comum.

O resíduo: `/:/rootfs:ro` e `/var/lib/docker/:/var/lib/docker:ro` dão leitura do host inteiro. E
`/var/lib/docker/containers/<id>/config.v2.json` contém **o `Env` de cada container** — o mesmo
conteúdo de A1, por outro caminho. `pid: host` no node-exporter, junto com `/proc`, permite ler
`/proc/<pid>/environ` de processos do host.

Nenhum dos dois é alcançável de fora da rede `obs` (medido em A5). É segundo grau: exige execução de
código já dentro deles. Mas o padrão importa — **o plano de observabilidade acumulou leitura ampla
dos segredos da máquina em três lugares independentes**, e nenhum deles precisa disso para desenhar
os painéis que desenha.

### A8 — cinco imagens novas, nenhum mecanismo de atualização (BAIXO, virando MÉDIO com o tempo)

As imagens estão **pinadas com versão exata** (`grafana:12.3.1`, `loki:3.5.7`, `alloy:v1.12.1`,
`prometheus:v3.13.1`, `tempo:2.10.7`, `node-exporter:v1.12.1`, `cadvisor:v0.55.1`) — certíssimo,
melhor que `latest`. O problema é o outro lado: pinado sem automação **envelhece em silêncio**. Não
há `dependabot.yml` nem Renovate no repositório (`.github/` só tem `workflows/`), e nada olha
`deploy/observability/*.yml`.

O precedente está no próprio doc 62 (§ sobre subir o Alloy para 1.12.4 por um DoS remoto
alcançável). Grafana e Loki produzem CVE com regularidade, e o Grafana é o único que publica porta.

**O que fazer:** Dependabot com ecossistema `docker` cobrindo `deploy/observability/` e a raiz. É um
arquivo de dez linhas e resolve a classe.

### A9 — o alerta não tem para onde ir (BAIXO em confidencialidade, ALTO em detecção)

O `grafana-alertas.yml` tem 16 KB de regras e **nenhum contact point configurado** — só o comentário
mandando configurar e "provar que chega". `GRAFANA_SMTP_ENABLED` default `false`. O monitor externo
do doc 62 §9 é plano, não código.

Não é vazamento; é que a metade que *detecta* não está ligada. Vale dizer com clareza porque a
narrativa cômoda ("agora temos observabilidade") sugere que sim: hoje o stack **mostra**, não
**avisa**. Para segurança isso é o que separa "temos log" de "vamos saber".

---

## 3. O que de fato fica exposto

Por sinal, assumindo o alvo mais provável — **um Grafana alcançável e uma senha**:

| Sinal | Conteúdo sensível | Retenção | Quem alcança hoje |
| --- | --- | --- | --- |
| **Loki** (log) | CPF/e-mail/telefone **redigidos**. **Nome, endereço e texto livre NÃO.** Rotas com UUID, mensagens de erro, `clinic_id`, `user_id` | 30 d | rede `obs` (sem auth) + Grafana |
| **Tempo** (trace) | **Sem redação.** `url.path` com UUID de paciente/agendamento = quem-abriu-qual-ficha. SQL parametrizado (sem valores) | 7 d | rede `obs` + Grafana; **escrita** anônima de qualquer app |
| **Prometheus** (métrica) | Sem PII. Inventário: rotas, filas, alvos, versões, volume por endpoint | 30 d | rede `obs` + `dokploy-network` (**máquina inteira** em prod) |
| **Postgres via views `metrics_*`** | Grão de linha para agendamento/presença/mensagem/**auditoria**, com `clinic_id` e `user_id`. Paciente **só agregado**, sem id. Sem CPF, sem nome, sem `destino`, sem `erro` | igual ao banco | Grafana (role `cinetra_metrics`) |
| **`/metrics` :4021** | Sem PII. BEAM, Oban, rotas parametrizadas | — | não publicada; rede interna, sem auth (decisão documentada, e correta) |

Duas leituras que merecem estar escritas:

**As views são o acerto de segurança do stack, e são cross-tenant por construção.** A barreira é
`GRANT`, não disciplina — verificado no doc 77 (`permission denied for table patients`), e o desenho
de allowlist por coluna é o que se deve fazer. Mas a view roda com os direitos do dono
(`security_invoker` off), então **um login de Grafana lê o agregado de todas as clínicas**, com grão
de linha em `metrics_audit_events` (quem fez o quê, em qualquer clínica). É intencional e está
documentado. A consequência que *não* está documentada: isso faz do login do Grafana uma conta com
visibilidade sobre a base de clientes inteira — mais parecida com um acesso administrativo do que
com um dashboard.

**LGPD.** O Tempo, hoje, guarda identificador de paciente ligado a "quem acessou e quando". Dado
pseudonimizado continua sendo dado pessoal, e o contexto é saúde (art. 11). Isso põe o stack de obs
**dentro** do escopo — retenção justificada, acesso restrito, entrada no registro de operações — em
vez de fora dele, que é onde a intuição costuma colocar "ferramenta de infra". Ligar a poda do A6 é
o que tira o Tempo dessa categoria, e é o argumento mais forte para fazê-lo.

---

## 4. Checklist para subir à produção, em ordem

Ordenado por (risco removido ÷ esforço). Os quatro primeiros são baratos e mudam a classe do
problema.

1. **`GF_SECURITY_SECRET_KEY` com `:?`** e valor aleatório — antes do primeiro deploy. (A3)
2. **Tirar `ports:` do Grafana.** Traefik com TLS, ou bind em `127.0.0.1` + túnel. Se publicar,
   `GRAFANA_PORT` explícito ≠ 3000. (A2)
3. **Ligar o `otelcol.processor.transform "poda"`** que já está escrito e comentado — `url.path`
   sai, `http.route` fica. (A6)
4. **`dependabot.yml`** com ecossistema `docker` sobre `deploy/observability/`. (A8)
5. **Socket proxy na frente do Alloy** (`CONTAINERS=1`, escrita em `0`). (A1)
6. **Confirmar na VM** que porta publicada não passa por `INPUT`: `iptables -t nat -L DOCKER -n` e
   `iptables -L FORWARD -n`. Se o Grafana ficar publicado, a regra de restrição precisa entrar em
   **`DOCKER-USER`**, não em `INPUT`. (A2)
7. **Configurar e provar o contact point** do alerta + o monitor externo do doc 62 §9. (A9)
8. **Rotacionar as chaves do R2** se as de dev já viajaram para qualquer lugar compartilhado — elas
   são legíveis por três componentes do stack (A1, A7).
9. **Débito para decidir depois:** segredos da aplicação saírem de `Env` para arquivo/`secrets:`. É
   o único conserto real do vazamento por `inspect`, e é grande. (A1, resíduo)

Como o [CLAUDE.md](../CLAUDE.md) manda que achado vire teste: os itens 1, 2 e 4 são **verificáveis
por script** e o lugar deles é o
[`verificar.sh`](../deploy/observability/verificar.sh), que já tem checagem de "porta não está
publicada no host" (§ das linhas 555 e 630). Acrescentar ali "Grafana não publica em 0.0.0.0",
"`secret_key` não é o default" e "poda de trace ativa" é o backstop automático desta análise —
sem isso, este doc é prosa que envelhece.

---

## 5. O que eu não medi

Honestidade sobre o alcance desta análise:

- **Nada foi medido na VM de produção** — ela não está provisionada
  ([memória do deploy](59-deploy-dokploy-oci.md)). O comportamento Docker↔iptables (A2) é o padrão
  documentado do Docker, não uma medição local; o item 6 do checklist existe para fechar isso.
- **Não tentei explorar A1 até o fim.** Parei no `HTTP 400`, que já prova que o handler de escrita é
  alcançável. Não criei container privilegiado na máquina do usuário.
- **Não auditei CVE por versão** das sete imagens — A8 é sobre a ausência de mecanismo, não um
  levantamento de vulnerabilidade conhecida.
- **Não revisei os 16 KB de `grafana-alertas.yml`** regra por regra; A9 é sobre o contato ausente,
  que é o que torna o resto inerte.
- **Não medi o conteúdo real do Tempo** por consulta (o `url.path` com UUID vem da leitura do
  `alloy.alloy` e do comentário do próprio arquivo, que diz que os atributos padrão incluem
  `url.path` com o UUID na rota). Uma consulta ao Tempo por `{name=~"GET /api/patients.*"}`
  confirmaria em um minuto — vale fazer antes de fechar o item 3.
