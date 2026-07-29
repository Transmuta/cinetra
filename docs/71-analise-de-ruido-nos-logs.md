# 71 — Análise do ruído nos logs: o que não deve ser enviado

> Medição, 2026-07-28. Refina a §2.1 do [`62-plano-de-logs.md`](62-plano-de-logs.md), que listou o
> ruído por raciocínio (health check e assets) **antes de haver pipeline rodando**. Agora há: o
> Alloy coleta, o Loki indexa, e este documento classifica o que efetivamente chegou.
>
> A §2.1 acertou nos dois itens que previu — os dois já estão filtrados e não aparecem na amostra.
> O que ela não podia prever é o que está abaixo, e a maior fonte de desperdício **não é a API**.

---

## 1. A amostra

5.000 linhas / 956 KiB, janela de 3 h, colhidas do Loki pelo proxy do Grafana (`{env="dev"}`),
ambiente de desenvolvimento com uso real da agenda.

| Classe | Linhas | KiB | % do volume | Veredito |
|---|---:|---:|---:|---|
| SQL do Ecto (`SELECT`/`INSERT`/`begin`/`commit`) | 2.178 | 724,8 | **75,8 %** | ruído — dev |
| `[debug] QUERY OK source=…` | 2.178 | 102,4 | **10,7 %** | ruído — dev |
| `STATEMENT:` do Postgres | 79 | 39,7 | **4,2 %** | **ruído — prod também** |
| `requisição` (evento HTTP da API) | 188 | 35,9 | 3,7 % | **é o produto** |
| `DETAIL:` do Postgres | 71 | 24,5 | **2,6 %** | **risco de PII — prod também** |
| `ERROR:` do Postgres | 79 | 9,7 | **1,0 %** | **falso positivo — prod também** |
| resto | 131 | 9,2 | 1,0 % | misto |
| `plugin:stop` do Oban | 50 | 5,2 | 0,5 % | ruído — prod também |
| HMR do Vite | 40 | 4,0 | 0,4 % | ruído — dev |
| `LOG:` do Postgres (checkpoint) | 6 | 1,1 | 0,1 % | manter |

Por serviço: **API 91,4 %**, **db 7,9 %**, **web 0,7 %**.

A leitura de primeira vista — "a API é 91 %, o problema está nela" — é a leitura errada, e a
próxima seção explica por quê.

---

## 2. O achado que reordena as prioridades

**86,5 % do volume é SQL do Ecto, e ele já não existe em produção.**
[`prod.exs:22`](../api/config/prod.exs#L22) fixa o nível em `:info`; o Ecto loga em `:debug`. O
doc 62 §1 já havia registrado isso ("SQL do Ecto em produção: 0 linhas"). Confirmado na amostra.

Ou seja: **a classe que domina o gráfico não custa nada em produção.** Ela custa outra coisa, que
não é volume e não estava no radar do doc 62:

> Com 86,5 % do stream sendo SQL, o Explore em dev é ilegível. Abrir `{service="cinetra-api-1"}` e
> procurar um evento de requisição é procurar 3,7 % de sinal dentro de 96 % de ruído. Uma
> ferramenta que só é usável em produção não é conferível antes do deploy — e o mesmo argumento
> está escrito na descrição da variável `parser` dos dashboards.

Descontado o SQL de dev, o quadro real de produção fica:

| Fonte | % do que sobra | Destino |
|---|---:|---|
| `requisição` da API | ~48 % | **é o produto** |
| **Container do Postgres** | ~46 % | **quase tudo descartável** |
| Oban `plugin:stop` | ~7 % | descartável |

**Metade do log útil de produção virá do container do Postgres, e quase nada dele serve.** Esse é
o achado principal. Em produção o banco roda como container no mesmo stack (`cinetra`, rede
`data` — [`59`](59-deploy-dokploy-oci.md) §123), portanto **entra na allowlist do Alloy**
(`OBS_PROJETOS=cinetra`) exatamente como em dev. Não é um problema de ambiente de trabalho.

---

## 3. O Postgres: três classes, três problemas diferentes

O Postgres emite, para cada erro, um trio `ERROR:` + `DETAIL:` + `STATEMENT:`. Nenhum dos três
carrega `request_id`, `clinic_id` ou `actor_id` — **são incorrelacionáveis com o evento da API por
construção**. E cada um tem um defeito próprio.

### 3.1 `ERROR:` — fluxo normal da aplicação marcado como erro

Dos 79 `ERROR:` da amostra, **47 são `conflicting key value violates exclusion constraint`**: é a
checagem de conflito de agenda funcionando como projetada. Um recepcionista tentando marcar em
cima de um horário ocupado produz uma linha `ERROR` no Postgres. Outros 15 são
`violates check constraint` — validação de domínio, também esperada.

**Cerca de 78 % dos "erros" do banco são usuários usando o sistema corretamente.**

Hoje isso não dispara o alerta *Erros 5xx acima do normal*
([`grafana-alertas.yml:53`](../deploy/observability/grafana-alertas.yml#L53),
`{env="prod", level="error"}`) — mas **por acidente, não por desenho**: o rótulo `level` sai do
campo `severity` de uma linha JSON, e o Postgres não loga JSON, então ele simplesmente não ganha o
rótulo. A proteção é a ausência de um parser, não uma regra.

Isso é frágil de um jeito específico: o Loki 3 marca essas linhas com `detected_level="error"`
sozinho (medido: **120 linhas do db em 1 h**). Qualquer painel, consulta ou alerta que use
`detected_level` — e é exatamente o que se recomenda usar em dev, onde `level` não existe — passa
a contar dupla-marcação de agenda como incidente. A armadilha está armada, esperando a primeira
pessoa que escrever a consulta natural.

### 3.2 `DETAIL:` — despeja o conteúdo cru da linha

Medido: **24 ocorrências de `Failing row contains`**, e elas trazem a tupla inteira:

```
DETAIL:  Failing row contains (019fab79-6a3d-…, 2026-07-20 11:00:00, 2026-07-20 11:00:00,
         agendado, t, null, null, null, 1, f, …, 019fab79-69fe-…, 019fab79-6a2e-…)
```

Aqui é `appointments`, e já sai o `patient_id` — **o único identificador que o
[doc 05](05-observabilidade-e-producao.md) §1.3 diz que nunca pode sair**, porque liga o registro a
um titular. Todo o cuidado do [`RequestLogger`](../api/lib/api_web/request_logger.ex), que
sanitiza `/api/patients/<uuid>` para `/api/patients/:id` justamente por isso, é contornado pelo
container ao lado.

E a mesma constraint violada em `patients` despejaria nome, CPF, telefone, tags e o texto livre da
observação. A redação do [`alloy.alloy`](../deploy/observability/alloy.alloy) é por **padrão**:
pega CPF, e-mail e telefone; **não pega nome, endereço nem texto livre**, porque não há regex para
isso. A amostra já contém um `Failing row contains (…, Furão, …)` — um nome atravessando a rede de
segurança, exatamente como previsto.

A terceira camada de redação do doc 05 §2.4 existe para o que escapa da origem. **Ela não foi
projetada para uma origem que despeja tuplas inteiras** — e não há como projetá-la para isso: o
conteúdo de uma linha de banco não tem forma reconhecível.

### 3.3 `STATEMENT:` — eco puro

Repete o SQL que originou o erro. Em dev duplica o que o Ecto já logou; em produção o Ecto é mudo,
mas o `STATEMENT` também não ajuda: sem `request_id` não dá para ligá-lo à requisição, e o erro que
importa a API já registrou **com** contexto. É a maior das três classes (4,2 % do total, ~39,7 KiB
na amostra) e a de menor valor.

### 3.4 O que do Postgres vale manter

`LOG:` — checkpoint, autovacuum, `database system is ready`, `received fast shutdown request`.
São 6 linhas na amostra (0,1 %) e é o único material do banco que serve para diagnóstico de
infraestrutura: um checkpoint lento ou um restart não aparecem em lugar nenhum senão aqui.

**Recomendação: manter `LOG:` e `FATAL:`, descartar `ERROR:`, `DETAIL:`, `STATEMENT:` e `HINT:`.**
Um erro de banco que realmente seja um incidente (e não fluxo normal) chega pela API — com
`request_id`, `clinic_id`, `actor_id` e rota, que é o que se usa para investigar.

---

## 4. Oban: `plugin:stop` é ruído, `job:*` é sinal

[`application.ex:16`](../api/lib/api/application.ex#L16) anexa o logger padrão do Oban — item da
§7 do doc 62, feito. Junto com os eventos de job vêm os de **plugin**:

```
[info] [source: "oban", duration: 1343, event: "plugin:stop", plugin: "Oban.Plugins.Pruner",
       pruned_count: 0]
```

O `Pruner` e o `Cron` reportam a cada 30 s que não fizeram nada. São **50 linhas em 3 h por
instância** — projetando, **~2.880 eventos/dia** dizendo `pruned_count: 0`.

O que justificou ligar o logger foi responder *"por que o lembrete não saiu na terça"* (doc 62 §1).
Isso se responde com `job:start`, `job:stop` e `job:exception`. `plugin:stop` não participa dessa
resposta — e o painel *Jobs executados por worker* já filtra `|= "job:stop"`, o que confirma que
ninguém pretendia consultá-lo.

**Recomendação: descartar `event: "plugin:stop"`**, preservando os eventos de job. Nota: descartar
`plugin:exception` seria errado — um Pruner quebrado é um problema real, e ele é raro por
definição.

---

## 5. Ruído exclusivo de dev

Não custa produção; custa a legibilidade da ferramenta onde ela é conferida.

| Fonte | Volume | Observação |
|---|---|---|
| SQL do Ecto + `QUERY OK` | 86,5 % | Ver §2. **Não mexer no `prod.exs`** — é ele que torna 30 dias barato (doc 62 §1) |
| HMR do Vite (`[vite] page reload`, `hmr update`) | 0,4 % | Não existe em build de produção |
| `/dev/mailbox` (preview de e-mail) | pequeno | Rota só de dev |

Duas formas de tratar, com trade-offs opostos:

- **Descartar no Alloy** (`stage.drop` em `[debug] QUERY`, `[vite]`, `/dev/mailbox`) — o Explore
  fica legível em dev, e em produção os estágios são inertes porque as linhas não existem. Custo:
  o pipeline de dev deixa de ser byte-a-byte o de produção.
- **Não descartar** — o pipeline permanece idêntico nos dois ambientes, ao preço de conferir os
  painéis por cima de 96 % de ruído.

Recomendo descartar: o SQL do Ecto continua disponível no `docker logs`, que é onde se olha SQL em
dev de qualquer forma. O que se perde é uma cópia agregada de algo que ninguém consulta agregado.

---

## 6. O que **não** cortar

Registrado porque a tentação de cortar por volume é o erro clássico desta análise.

- **`requisição` da API (3,7 %)** — é o produto. O [`RequestLogger`](../api/lib/api_web/request_logger.ex)
  já consolidou 2 linhas em 1, já filtra health check 2xx e já sanitiza o path. **Não há gordura
  aqui**; a API está certa.
- **`LOG:` do Postgres** — ver §3.4.
- **`plugin:exception` do Oban** — ver §4.
- **Health check que FALHA** — o `registrar?/1` só silencia `status < 400`, deliberadamente: um
  health check falhando é o sintoma de que a instância saiu da rotação.
- **Linhas de `warning`/`error` da própria API** — são as 19 chamadas de `Logger.*` do domínio
  (doc 62 §1), concentradas em jobs, R2, webhooks e fan-out. É o material de diagnóstico.

---

## 7. Ordem de execução recomendada

Por impacto, não por facilidade. Os dois primeiros são de **produção** e valem independentemente
de volume.

| # | Ação | Onde | Ganho |
|---|---|---|---|
| 1 | Descartar `DETAIL:` e `HINT:` do Postgres | `alloy.alloy` | **fecha a fuga de PII** (§3.2) |
| 2 | Descartar `ERROR:` e `STATEMENT:` do Postgres | `alloy.alloy` | tira o falso positivo (§3.1) e ~5 % do volume |
| 3 | Descartar `event: "plugin:stop"` | `alloy.alloy` | ~2.880 eventos/dia/instância (§4) |
| 4 | Descartar `[debug] QUERY`, `[vite]`, `/dev/mailbox` | `alloy.alloy` | Explore legível em dev (§5) |

Todos são `stage.drop` no Alloy, com `drop_counter_reason` próprio — o mesmo padrão dos dois
filtros que já existem, e que mantém o descarte **contável** em vez de silencioso.

### 7.1 A ordem dentro do pipeline importa

O `alloy.alloy` documenta o desenho: `descoberta → rótulos → DESCARTE → redação → escrita`. Os
descartes novos entram **junto dos existentes**, antes da redação. Não é cosmético: descartar
`DETAIL:` antes de redigir significa que a tupla com o nome do paciente nunca é processada — em vez
de ser processada, escapar dos três regexes e ser escrita.

### 7.2 O gate precisa afirmar isso

O [`verificar.sh`](../deploy/observability/verificar.sh) não checa nada disto — foi por isso que os
achados desta análise sobreviveram à verificação. **Cada descarte acima precisa da sua asserção**,
no formato das que já existem ("health check não está no log"), e escrita **antes** do estágio,
para ver vermelho primeiro (regra do `CLAUDE.md`).

A asserção mais importante não é de volume, é a de PII:

```
{env="dev"} |= "Failing row contains"   →   deve devolver 0
```

Ela é a única que, se ficar vermelha, indica que dado de titular está saindo da máquina.

### 7.3 Duas lacunas que este documento não fecha

- **O rótulo `level` não existe em dev**, porque o `stage.json` só casa com linha JSON e a API loga
  texto em dev. `{level="error"}` — base de dois painéis e de um alerta — enxerga só o BFF. Um
  `stage.regex` de fallback extraindo `[error]`/`[warning]` do texto resolveria nos dois ambientes.
- **Os streams `moving-api-1`/`db-1`/`web-1`** são resíduo do rename do projeto. Sem linha nova,
  saem pela retenção, mas até lá poluem o autocomplete.
