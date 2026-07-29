# 72 — Consultas de plantão: colar no Explore

> Referência de uso, 2026-07-28. O dashboard **"00 · Plantão"**
> ([`dashboards/00-plantao.json`](../deploy/observability/dashboards/00-plantao.json)) já traz tudo
> isto em painel. Este arquivo existe para o caso em que se quer investigar no Explore, onde é
> preciso digitar a consulta.

Todas funcionam **em dev e em produção**, apesar de a API logar texto em dev e JSON em produção.
Duas escolhas fazem isso:

- **`detected_level`** — o Loki 3 deduz o nível da linha nos dois formatos. O rótulo `level`, que
  sai do campo `severity`, só existe onde há JSON (produção e o BFF).
- **separador tolerante** — `status[=":]+5\d\d` casa com `status=500` (dev) e `"status":500` (prod).

O Explore **exige um seletor de stream**: sem pelo menos um `{rótulo="valor"}` ele responde vazio,
sem erro. Rótulos existentes: `env` (`dev`, `prod`), `service` (`cinetra-api-1`, `cinetra-web-1`,
`cinetra-db-1`), `level` (só em produção).

---

## A ordem em que se pergunta

**1. Está chegando log?** Antes de concluir "não há erro", confirme que há dado.

```logql
sum(count_over_time({env="dev"} [5m]))
```

Zero aqui significa agente parado, rede ou máquina — não app saudável. É o único painel em que
**zero é o alarme**, e por isso ele é o primeiro.

**2. Onde dói.**

```logql
sum by (service) (count_over_time({env="dev"} | detected_level="error" [5m]))
```

Se o pico for em `cinetra-db-1`, desconfie antes de agir: conflito de constraint é fluxo normal da
agenda ([doc 71 §3.1](71-analise-de-ruido-nos-logs.md)) e o Postgres o registra como `ERROR`.

**3. É falha nossa?**

```logql
{env="dev", service=~".*api.*"} |= "requisição" |~ "status[=\":]+5\\d\\d"
```

4xx fica de fora de propósito: 401 de sessão expirada e 422 de formulário são rotina.

---

## Cenários

### Serviço dando erro 500

```logql
{env="dev", service=~".*api.*"} |= "requisição" |~ "status[=\":]+5\\d\\d"
```

Cada linha traz `request_id`, `method`, `route` e `duration_ms`. Com o `request_id` em mãos, o
resto da requisição:

```logql
{env="dev"} |= "GMad2LyYYsqNyPEAAO3B"
```

**Por que a 500 aconteceu** raramente está na linha da requisição — está no que o domínio
registrou por conta própria, logo antes:

```logql
{env="dev", service=~".*api.*"} | detected_level=~"error|warn"
```

### Fila travada

Fila travada **não emite mensagem de erro** — ela para de emitir. Por isso se detecta pela
ausência, e são três perguntas diferentes:

```logql
# a) a fila está entregando? (se cair a zero com trabalho entrando, travou)
sum by (queue) (count_over_time({env="dev", service=~".*api.*"} |= "job:stop" [5m]))

# b) os jobs estão quebrando? (rodou e estourou — diferente de travar)
{env="dev", service=~".*api.*"} |= "job:exception"

# c) está acumulando antes de parar? queue_time em µs; 7+ dígitos é ≥1s de espera
{env="dev", service=~".*api.*"} |= "job:stop" |~ "queue_time[=\":]+ ?\\d{7,}"
```

**Ressalva honesta:** o log não mostra a **profundidade** da fila — quantos jobs estão parados em
`available`. Isso só existe na tabela `oban_jobs`. O log mostra o que *saiu* da fila; se nada sai,
você vê silêncio, não um número. Para o número:

```sql
SELECT queue, state, count(*) FROM oban_jobs GROUP BY 1,2 ORDER BY 3 DESC;
```

### Integração não entregou (WhatsApp, e-mail, storage)

```logql
{env="dev", service=~".*api.*"} |~ "(?i)(zernio|storage|webhook|mensagem|entrega).*(falhou|recusad|não aplicou|sem messageId)"
```

Ancorada nos textos que o código escreve de fato — as chamadas de `Logger.*` em
`api/lib/api/messaging/`, `/storage/` e nos controllers de webhook.

### Lentidão que o usuário sente

```logql
{env="dev", service=~".*api.*"} |= "requisição" |~ "duration_ms[=\":]+\\d{4,}"
```

4+ dígitos = acima de 1s. Vem antes do erro: rota que degrada costuma virar timeout depois.

### Tela quebrando no navegador

```logql
{env="dev"} |= "erro no browser"
```

Chega pelo `/api/client-error` do BFF. É o único sinal do que o usuário viu — nada disso aparece
no log da API.

### Banco fora, reiniciando, recusando conexão

```logql
{env="dev", service=~".*db.*"} |~ "(FATAL:|shutdown|ready to accept|could not|out of memory)"
```

`ERROR:` e `DETAIL:` do Postgres ficam de fora de propósito: são fluxo normal e vazam conteúdo de
linha ([doc 71 §3](71-analise-de-ruido-nos-logs.md)).

### Alguém sem permissão batendo onde não deve

```logql
{env="dev", service=~".*api.*"} |= "requisição" |~ "status[=\":]+403"
```

403 isolado é rotina (usuário clicou onde não podia). 403 em rajada, na mesma rota, merece olhar.

---

## Duas armadilhas

**`{level="error"}` não funciona em dev.** O rótulo vem do `severity` de uma linha JSON, e a API
loga texto em dev. Dois painéis dos dashboards antigos e um alerta usam esse rótulo, e em dev eles
abrem vazios com o log inteiro presente. Use `detected_level` — ou consulte os dashboards antigos
só contra produção. ([doc 71 §7.3](71-analise-de-ruido-nos-logs.md) descreve o conserto.)

**Os dashboards 01/02/03 abrem em `json`.** Eles têm um seletor **"Formato do log"** no topo; em
dev é preciso trocar para `logfmt`, senão os painéis de rota, status e latência abrem vazios. O
dashboard **00 · Plantão** não tem esse seletor porque não precisa — é essa a razão de ele existir
separado.
