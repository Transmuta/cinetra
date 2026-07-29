# 72 — Dashboards: o que o log responde, e o que só o banco responde

> Execução, 2026-07-29. Estende o [`62-plano-de-logs.md`](62-plano-de-logs.md) §10.3, que entregou
> três dashboards sobre log. Este acrescenta **sete** e, mais importante, uma **segunda fonte**: o
> banco da aplicação, lido por views dedicadas. Tudo verificado contra a stack rodando.

---

## 1. A pergunta que o log não alcança

O doc 62 abriu justificando o pipeline com um exemplo: *"por que o lembrete não saiu na terça"*.
Com a agregação de pé, essa pergunta **continua sem resposta** — e não por falta de retenção:

> **Trabalho que não aconteceu não produz linha de log.** Ele produz uma **linha parada numa
> tabela.** Um job que nunca foi executado, um lembrete `pendente` cuja hora passou, uma entrada de
> fila que ninguém atendeu: nada disso emite evento, porque evento é o registro do que ocorreu.

Log responde *o que o sistema fez*. Banco responde *em que estado o negócio está*. As duas
perguntas de plantão mais caras são da segunda categoria, e nenhum painel do doc 62 as cobria.

Some-se a isso que o `oban_jobs` perde a evidência para o Pruner em 7 dias: quando alguém pergunta
por que o lembrete não saiu, com frequência a linha já nem existe.

---

## 2. O que existe agora

Onze dashboards, todos provisionados **por arquivo** em
[`deploy/observability/dashboards/`](../deploy/observability/dashboards/) — painel montado na UI
morre com o container, e a máquina é descartável de propósito.

| Dashboard | Fonte | Responde |
|---|---|---|
| **00 · Plantão** | log | consultas prontas de incidente ([`72`](72-consultas-de-plantao.md)) |
| **01 · Visão geral** | log | "dá para trabalhar agora?" |
| **02 · Requisições** | log | "onde foi o tempo e quem reclama?" |
| **03 · Erros e jobs** | log | crash de browser e eventos de job |
| **04 · Atrito (4xx)** | log | onde o produto briga com quem o usa — 422, 409, 403, 429, 401 |
| **05 · Uso e clínicas** | log | quem usa, quanto, e **qual clínica parou** |
| **06 · Infraestrutura** | log + banco | boot/crash/FATAL, cache, conexões, tamanho, índice sem uso |
| **07 · Mensagens** | banco | o funil de entrega e **o lembrete que não saiu** |
| **08 · Agenda e fila** | banco | volume, falta, cancelamento, encaixe, fila de espera |
| **09 · Trabalho em segundo plano** | banco + log | fila do Oban, atraso, descartados, duração |
| **10 · Auditoria e acesso** | banco | acesso negado, leitura desproporcional, poda de 90 dias |

Os cinco painéis que respondem coisa que **antes não dava para perguntar**:

1. **`04` · 409 por rota** — dupla marcação de agenda. O [`71`](71-analise-de-ruido-nos-logs.md) §3.1
   já a tinha encontrado no log do Postgres, onde ela chega **sem** `request_id`, `clinic_id` ou
   `actor_id` — e ainda contaminada como "erro". Pelo status HTTP ela vem com contexto inteiro.
2. **`07` · lembretes atrasados** — `status = 'pendente'` com `agendado_para` no passado. Qualquer
   valor acima de zero é alguém que não foi avisado.
3. **`09` · espera do job mais antigo** — a contagem da fila não distingue "50 que entraram agora"
   de "5 parados desde ontem"; a idade distingue. O heartbeat externo detecta *parou*; este detecta
   *atrasou*, que é o estado anterior e o único em que ainda dá para agir.
4. **`10` · `action_type = deny`** — tentativa de acesso recusada pela policy. É o sinal de
   segurança mais barato que o sistema produz e ninguém olhava.
5. **`06` · índices com `idx_scan = 0`** — a lição do [`35`](35-plano-execucao-backlog.md) virada
   painel, depois de um índice GiST ter sido entregue sem nunca ser usado.

---

## 3. A segunda fonte, sem transformar o Grafana em visor de prontuário

O risco de ligar o Grafana ao banco é óbvio e grande: um datasource com `SELECT` nas tabelas põe
`patients.cpf`, o texto livre da observação e o nome de todo titular a um clique numa UI web —
exatamente o dado que o `RequestLogger` sanitiza e que o Alloy redige com três regexes.

O desenho tem três camadas, e a ordem importa:

### 3.1 Views `metrics_*` — a lista de colunas é o contrato

[`MetricsViews`](../api/priv/repo/migrations/20260729060000_metrics_views.exs) cria treze views que
listam, **coluna a coluna**, o que pode sair. Coluna nova numa tabela não aparece sozinha do outro
lado: erra fechado.

O que **nunca** entra, e por quê:

| Fora | Motivo |
|---|---|
| `patient_id`, em qualquer grão | é o único identificador que o [`05`](05-observabilidade-e-producao.md) §1.3 proíbe de sair — liga o registro a um titular. Paciente aqui só existe como contagem (`metrics_patients_resumo`) |
| texto livre (`obs`, `motivo`, `cancel_reason`, `title`/`body`, `packages.nome`) | campo digitado por humano carrega o que o humano quis. "Maria faltou de novo" é dado de saúde num campo que ninguém classificou |
| `messages.destino` e `messages.erro` | ver §4.2 — o `erro` é o **texto cru do provedor** |
| `audit_events.label`, `user_label`, `diff`, `meta` | o `diff` guarda o valor **antes/depois**, ou seja o conteúdo do campo alterado |
| `oban_jobs.args` e `errors` | `args` carrega ids de domínio; `errors` carrega stacktrace, que é texto livre por natureza |

Entram de propósito: `clinic_id` e `user_id` (o [`05`](05-observabilidade-e-producao.md) §1.3
permite — é o que torna qualquer coisa investigável) e o **rótulo do profissional**, sem o qual
"taxa de falta por profissional" vira uma lista de UUID que ninguém usa.

### 3.2 O role — e por que a RLS **não** é a barreira aqui

`cinetra_metrics` é `NOSUPERUSER NOBYPASSRLS`, sem `GRANT` em tabela nenhuma: só `SELECT` nas
views. Provisionado por [`Api.Release.setup_metrics_role/0`](../api/lib/api/release.ex) em produção
e por [`priv/sql/setup_metrics_role.sql`](../api/priv/sql/setup_metrics_role.sql) em dev — mesmo
molde do role do app, com **duas diferenças deliberadas**:

- **sem `ALTER DEFAULT PRIVILEGES`** — tabela criada por um `ash.codegen` futuro **não** deve nascer
  legível. Só entra o que passar por view nova;
- **ausente = desligado** — sem `DATABASE_METRICS_PASSWORD`, o role não é criado e os painéis de
  banco ficam com erro de conexão **visível**, em vez de painel vazio que ninguém desconfia.

E aqui está a peça que engana: **a view roda com os direitos do dono** (`security_invoker` é falso
por padrão), e o dono é `postgres`, que bypassa RLS. Ou seja, a view atravessa a RLS de propósito —
é isso que faz o painel enxergar todas as clínicas, que é o que um painel de operação do produto
precisa. A consequência tem de ficar escrita:

> **A RLS não protege nada nesta superfície.** Quem protege é a lista de colunas da view e a
> ausência de `GRANT` nas tabelas. Por isso a asserção do verificador é sobre o `GRANT` (§5), e não
> sobre quantas linhas voltaram.

### 3.3 A rede — a única coisa que pode derrubar o stack

O Grafana entra na rede da aplicação para alcançar o Postgres
([`compose.obs.yml`](../deploy/observability/compose.obs.yml), rede `app`, `external: true`).
Consequência que precisa ser dita alto: **nome errado em `APP_NETWORK` não degrada, impede o stack
inteiro de subir** — o compose valida rede externa antes de criar container, e junto com o Grafana
ficariam de fora o Loki e o Alloy, isto é, a coleta de log por causa de um painel. É falha alta e
imediata (aparece no deploy), mas confira com `docker network ls` antes do primeiro.

Em produção há **dois** stacks da aplicação, cada um com um serviço chamado `db`. Por isso
`METRICS_DB_HOST` é o **nome do container** (`cinetra-prod-db-1`), que é único, e não `db`.

---

## 4. O que a execução ensinou

Cinco achados. Nenhum deles apareceu escrevendo o painel; todos apareceram rodando a consulta.

### 4.1 Somar a coluna certa pelo nome errado desenha um painel vazio — sem erro

`appointments.duration_minutos` **não** é a duração do bloco: é o *override* de A-D8, e vem **NULO**
no caso comum (a duração real mora no tipo de atendimento). O painel "horas agendadas por dia"
somava a coluna crua; medido, ele devolvia linhas com `value` inteiramente nulo — um gráfico vazio
que qualquer pessoa leria como "não houve agendamento nesse período".

É a mesma família de defeito que o doc 62 §10.2 já tinha catalogado três vezes: **coisas que
parecem funcionar**. O conserto foi na view, não no painel — `duracao_minutos` passou a ser derivada
de `ends_at - starts_at`, e o override nem é exposto, para ninguém tropeçar de novo. O verificador
ganhou a asserção correspondente.

### 4.2 O motivo da falha de mensagem não pode ir para o painel

A intuição diz que "falhas por motivo" é o painel mais útil do dashboard de mensagens. Mas
`messages.erro` guarda o **texto cru do provedor** — [`webhooks.ex`](../api/lib/api/messaging/webhooks.ex)
grava `reason` do Resend e `error.message` da Zernio direto na coluna; a classificação em frase
fechada acontece **na leitura**, no `Falhas.para_tela/1` do controller. Num bounce, o texto cru
costuma citar o destinatário: e-mail ou telefone do paciente.

Então o painel conta **quantas** falharam, por canal e por template; o *motivo* se lê na tela da
clínica, sob RLS, que é onde ele é útil e onde o acesso já é controlado.

### 4.3 A asserção de PII precisa esperar **erro**, e isso foi provado quebrando

A checagem do §5 espera `permission denied` ao ler `patients`. Para não ser uma asserção decorativa,
o buraco foi aberto de propósito (um `GRANT SELECT ON patients` mais uma view com `patient_id`) e o
verificador ficou **vermelho nas duas linhas**; revertido, voltou a verde.

E o experimento ensinou algo a mais: com o `GRANT` aberto, o `SELECT` devolveu **`0`** — porque a
RLS, aí sim, se aplica (o role lê a tabela diretamente, sem GUC). Ou seja, **"voltou zero" não
prova barreira nenhuma**: um verificador que só olhasse a contagem teria passado com a PII exposta.
Ele olha o *erro*.

### 4.4 "0 linhas" não é aprovação

Das 96 consultas, oito devolveram vazio. Cada uma foi conferida contra o banco antes de ser aceita:
sem `faltou`/`concluida` no dev não há taxa de falta; sem entrada na fila não há painel de fila; sem
mensagem entregue não há latência de entrega. É o mesmo cuidado que o `verificar.sh` já teve de
aprender quando **passava por vazio** (doc 62 §10.2) — e a checagem de coluna 100% nula (§5) existe
justamente porque o vazio *silencioso* é o defeito mais caro deste tipo de ferramenta.

### 4.5 O `now` como limite direito esconde a informação principal da agenda

Todo dashboard nasceu com janela terminando em `now` — e no de agenda isso é errado: o que ainda vai
acontecer **é** o assunto. Com o limite no presente, o painel escondia exatamente a semana que vem.
A janela do `08` vai até `now+30d`.

---

## 5. Como verificar

Duas ferramentas, e elas cobrem coisas diferentes.

**[`verificar.sh`](../deploy/observability/verificar.sh) — §11 e §12 (novas).** A barreira e o
provisionamento:

```
11. Banco no Grafana — e a barreira que impede o painel de virar visor de prontuário
  ✓ datasource do banco responde (metrics_appointments: 8 linha(s))
  ✓ tabela patients negada ao role do Grafana
  ✓ tabela messages negada ao role do Grafana
  ✓ tabela audit_events negada ao role do Grafana
  ✓ tabela appointments negada ao role do Grafana
  ✓ nenhuma view metrics_* expõe patient_id nem coluna de texto livre
  ✓ todas as views metrics_* estão concedidas ao role do Grafana
  ✓ duração efetiva presente em todo bloco com fim definido
12. Dashboards provisionados
  ✓ 11 dashboards carregados para 11 arquivo(s) em dashboards/

34 ok, 0 falhou
```

**[`verificar-paineis.py`](../deploy/observability/verificar-paineis.py) — novo.** Roda **toda
consulta de todo dashboard** pelo caminho real do Grafana. Existe porque painel quebrado não avisa:
sintaxe errada vira um retângulo com aviso pequeno num canto, e consulta certa sobre coluna errada
vira um gráfico vazio indistinguível de "não houve nada". Abrir onze dashboards à mão depois de cada
mudança não é verificação, é esperança.

```bash
./deploy/observability/verificar-paineis.py            # 96 consultas, 0 falha(s)
GRAFANA=https://grafana.exemplo GRAFANA_AUTH=admin:senha \
OBS_ENV_TESTE=prod PARSER=json ./deploy/observability/verificar-paineis.py
```

Ele reprova em três casos, e o terceiro é o que pegou o §4.1: consulta com erro, sintaxe recusada,
ou **coluna 100% nula** com linhas presentes. `nullif(` na consulta desliga o terceiro para aquela
linha — é a marca explícita de "este denominador pode não existir", e taxa sem base é nula por
decisão, não por defeito.

---

## 6. Manutenção: a armadilha da view contra o `ash.codegen`

View depende de coluna. Se um dia uma migration do Ash tentar **mudar o tipo** de uma coluna citada
nas views, o Postgres recusa com `cannot alter type of a column used by a view or rule`. O conserto
é mecânico:

```bash
docker compose exec db psql -U postgres -d movimento_dev \
  -c "DO \$\$ DECLARE v text; BEGIN FOR v IN SELECT viewname FROM pg_views WHERE viewname LIKE 'metrics\_%' LOOP EXECUTE format('DROP VIEW %I', v); END LOOP; END \$\$;"
mix ecto.migrate            # a migration é idempotente (CREATE OR REPLACE) e recria tudo
```

Acrescentar coluna, renomear tabela ou dropar coluna **não citada** não incomoda. E vale a
contrapartida: é essa mesma dependência que faz o `DROP` doer, ou seja, que **avisa** quando um
esquema muda debaixo de um painel — o contrário de um dashboard que continua verde mostrando número
errado.

---

## 7. O que falta (humano, produção)

1. **Três variáveis no Dokploy**, e o par de senhas precisa **bater**:
   - stack da aplicação: `DATABASE_METRICS_PASSWORD` (cria o role);
   - stack de observabilidade: `METRICS_DB_PASSWORD` (usa o role), `METRICS_DB_HOST`
     (= **nome do container**), `METRICS_DB_NAME`, `APP_NETWORK`.
2. **Conferir `APP_NETWORK` com `docker network ls` antes do deploy** — §3.3.
3. **Grafana atrás de autenticação forte / VPN.** O [`62`](62-plano-de-logs.md) §8 já pedia; agora
   pesa mais, porque a instância deixou de ter só log operacional e passou a ter agregado de
   negócio de todas as clínicas.
4. **Segundo datasource para HML**, se for para separar os ambientes no banco. Os dashboards já
   escolhem o datasource por variável (`${db}`), então é só provisionar — nenhum painel muda.
5. **Rodar o `verificar-paineis.py` contra produção** depois do primeiro deploy: em dev várias
   consultas passaram com zero linha por ausência de dado (§4.4), e só tráfego real prova o resto.

---

## 8. O que este documento não faz

- **Métrica de host.** CPU, memória, I/O e saturação continuam fora — nem log nem estas views os
  têm. É a fase de métricas do doc irmão ([`62`](62-plano-de-logs.md) §11.2), e o dimensionamento da
  §3.2 de lá já reservou memória para ela.
- **Alerta sobre os sinais novos.** "Lembrete atrasado > 0", "job descartado > 0" e "deny em rajada"
  são candidatos óbvios — e ficaram de fora de propósito: limiar sem base histórica vira alarme
  falso, e alarme falso treina a equipe a ignorar o aviso (doc 62 §11.4). Ligar depois de uma ou
  duas semanas de dado real, com o número na mão.
- **`role` do ator no log.** Uma linha no [`LoadScope`](../api/lib/api_web/plugs/load_scope.ex)
  (cardinalidade 4) abriria o corte por papel em todo painel de atrito — "recepção topa 422 três
  vezes mais que admin" é achado de produto. Não entra aqui porque muda a **aplicação**, não o
  painel; fica anotado como o próximo passo mais barato.
