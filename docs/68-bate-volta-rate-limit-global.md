# Bate-volta — rate limit global (200 req/min)

Auditoria da fatia "rate limit global" em três eixos paralelos (segurança, performance,
refatoração), todos provados contra a stack rodando. **Parou na rodada 5**: as duas caças acharam
12 achados, a consolidação os reduziu a 6 causas, cinco foram corrigidas e a rodada 5 achou mais
duas coisas — uma no meu próprio conserto.

O ponto de partida importa: a fatia entregue **passava** em 1.475 testes, 90,4% de cobertura,
formatação e `--warnings-as-errors` limpos. Nada do que está abaixo apareceu por leitura do diff.

---

## 1. A varredura

| Eixo | Itens | CONFIRMADO | REFUTADO | NÃO SE APLICA |
|---|---|---|---|---|
| Segurança (`quality-specialist`) | 23 | 5 | 6 | 12 |
| Performance (`data-engineer`) | 16 | 4 | 2 | 10 |
| Refatoração / rules (`test-engineer`) | 27 | 10 | 9 | 8 |

**O que a caça adversarial achou que a checklist não tinha achado:** os dois achados de maior
alcance prático não vieram de item de lista nenhum. O primeiro foi seguir a chamada do BFF em vez
do endpoint da API (causa B); o segundo foi perguntar "o que a tela faz quando a API devolve 429?"
em vez de "o 429 está correto?" (causa D). A checklist achou o que estava nela; o ângulo
adversarial achou o que derrubava o login do produto inteiro.

**O teste de mutação** (eixo de refatoração) merece nota própria: 11 mutações no código novo,
**5 mortas, 6 sobreviventes**, com o plug reportando **100% de cobertura de linha**. Cobertura de
linha mediu que o código roda, não que a suíte o defende.

---

## 2. As causas-raiz

Doze achados, seis causas.

### A. O limitador global reusou uma engine dimensionada para 3 endpoints de auth — CRÍTICA

`Api.RateLimiter` usa `sliding_window`, escolhido para os endpoints de auth, onde o volume é
baixíssimo. No Hammer esse algoritmo grava **uma linha por requisição** e resolve cada `hit/3` com
`:ets.select` cuja chave vai no *guard*, não no *head* — ou seja, **varre a tabela inteira**.
Aplicá-lo ao tráfego todo inverteu o propósito do plug:

```
tabela vazia        14,3 µs por hit
100 mil linhas   31.110 µs por hit      (4× o custo de um request inteiro)
1 milhão        472.229 µs por hit
```

Duas agravantes medidas: a linha entra **mesmo quando a requisição é barrada** (o `insert_new`
roda antes da checagem), então N cresce com o tráfego *recebido* e a enxurrada financia a própria
amplificação; e a API inteira satura em **275 req/s** a 100 mil linhas, antes de qualquer trabalho
de aplicação. Como a tabela era compartilhada com o `RateLimitAuth`, o login degradava junto — um
ataque que não era contra ele o derrubava de lado.

### B. A chave do limite não identifica o cliente — CRÍTICA

Três achados, uma causa: *quem* está sendo limitado nunca foi bem estabelecido.

1. **`fly-client-ip` no topo da cadeia de confiança, lido do valor mais à esquerda** — o que o
   cliente escreveu. Na Fly isso é seguro (a edge sobrescreve), mas este mesmo working tree está
   migrando para Traefik/Dokploy, onde ninguém escreve nem remove esse header. Sonda: 30
   requisições com limite 2 rodando o header, **nenhuma barrada** — e ele vence mesmo com o
   `x-forwarded-for` honesto do BFF presente.
2. **Dois call sites do BFF não repassavam o IP do cliente** (`/auth/callback` e
   `/confirmar/[token]`) porque não usam `apiFetch`. Sem ator e sem header, a API só tinha o IP do
   *container do BFF*: um balde só para o produto inteiro.
3. **`ClientIp` foi extraído sem teste** — apagar o header do topo ou inverter a ordem deixava a
   suíte verde.

O (2) fecha uma cadeia de exploração completa, provada de ponta a ponta:

```
[S7] /api/reply x2  ->  callback do magic link de OUTRO usuário = 429
     corpo do login: {"error":"rate_limited"}
```

`GET /auth/callback?token=qualquer-coisa` 200×/min, sem conta, sem token válido, sem sessão:
**nenhum usuário entra no sistema** e **nenhum paciente confirma consulta** pelo resto da janela.
Custa um laço de `curl` e é renovável indefinidamente.

### C. O limite rodava depois da autenticação, logo não a protegia — ALTA

O plug vinha depois de `:authenticated`, então o 429 cortava o trabalho do controller e não o da
stack de sessão. Medido pelo pipeline HTTP real:

```
BLOQUEADO (429): 5 queries -> %{"memberships" => 1, "tokens" => 3, "users" => 1}
5 queries | tempo de BANCO = 2,758 ms
```

Um ator com sessão válida mandando 10 mil req/min gerava **49 mil queries descartadas por minuto**
— amplificação de **42×** sobre o que "200 req/min" dá a entender, e 27 s de banco por minuto
jogados fora, contra um pool de 16 conexões.

O repo já havia decidido o contrário do outro lado da fronteira: *"rate limit primeiro, antes de
qualquer outra checagem: ele é a guarda que também protege as guardas"*
(`web/src/routes/api/client-error/+server.ts`).

### D. O BFF tratava 429 como "sem sessão" — ALTA

`loadMe` fazia `if (!res.ok) return null`, e o layout do app faz `if (!me) redirect('/entrar')`.
Ou seja: **o rate limit deslogava quem tinha sessão válida**, indistinguível de um 401. A pessoa
perdia o contexto sem entender por quê. Rate limit tem de degradar, não deautenticar.

### E. A suíte cobria 100% de linha e 45% de mutação — ALTA

As seis mutações sobreviventes, todas no código novo:

```
M2  janela 1min -> 90min                  SOBREVIVEU
M2b janela -> 60 (ms — o bug histórico)   SOBREVIVEU
M3b retry-after em ms (não segundos)      SOBREVIVEU
M7  default do enabled? false -> true     SOBREVIVEU
M8  remove fly-client-ip da cadeia        SOBREVIVEU
M8b inverte a ordem de confiança          SOBREVIVEU
```

O teste chamado *"o default de produção é 200 requisições por minuto"* provava o **200** e não
provava o **por minuto** — inclusive contra a troca da janela por 60 **milissegundos**, que é
exatamente o bug que o `RateLimitAuth` documenta em caixa alta como *"só a app viva pegou"*. O
projeto já havia pago por ele uma vez.

### F. O DRY parou cedo, e o `deny` já tinha divergido — MÉDIA

`ClientIp` resolveu 1 de 5 verdades compartilhadas entre os dois plugs. A que mais custava: cada
um tinha o seu `deny`, e eles **já divergiam** — o global mandava `retry-after`, o de auth não. Um
cliente educado ficava sem orientação justo no endpoint mais sensível e faria retry cego. Também
ficaram duplicados `client_key`, o literal `{"error":"rate_limited"}` e `enabled?` — e a flag
única acoplava o desligamento dos dois limitadores, de modo que apagar o teto global num incidente
apagaria junto o anti-brute-force do magic link.

---

## 3. O que foi corrigido

### A — engine O(1) e tabela separada

`Api.RateLimiter.Global` novo, com `algorithm: :fix_window`: uma linha **por chave** (não por
requisição) e `update_counter` na chave completa. O `Api.RateLimiter` original fica como está,
servindo o anti-brute-force de auth, onde a precisão da janela deslizante é regra de segurança e
o volume é baixo.

Re-sonda, o mesmo benchmark que achou o problema:

```
ANTES  (sliding_window): 5.591,46 µs/hit | 12.101 linhas na tabela
DEPOIS (fix_window):         2,20 µs/hit | 100.001 linhas na tabela
```

**2.542× mais rápido — e a comparação é conservadora**, porque o motor antigo foi medido com 8×
menos linhas (a poda dele rodou durante o enchimento, que é lento justamente por causa do defeito).
A tabela nova ocupa 15,4 MB com 100 mil chaves.

O preço aceito é o burst de virada de janela (até 2× o teto num instante), irrelevante para um
teto grosso de infraestrutura.

### B — a chave passa a identificar o cliente

- `ClientIp` ganhou `trusted_client_ip_headers` **configurável**, com o default preservando a
  topologia atual (Fly). Um header só é confiável se a topologia garante que alguém o sobrescreve
  — isso é decisão de deploy, não constante de código.
- `clientIpHeaders` extraído em `web/src/lib/server/api.ts` e aplicado nos **dois** call sites que
  não usam `apiFetch`. São justamente os que mais dependem dele: sem ator, o IP é a única chave
  que existe.
- Cinco testes novos fixam a ordem de confiança (`api/test/api_web/client_ip_test.exs`), que não
  tinha nenhum, e um teste no web prova que a página do paciente leva o IP.

### C — dois estágios

`stage: :edge` (por IP, **antes** da stack de sessão) + `stage: :actor` (por ator, depois do
`LoadScope`). Teste vermelho primeiro, com o número exato que a sonda mediu:

```
a requisição barrada não pode tocar o banco (custou 5 queries)
```

Depois do conserto: **0 queries**. A borda corta a enxurrada antes do banco; o estágio de ator
mantém a precisão de quem consumiu o quê.

### D — 429 deixa de deslogar

`loadMe` levanta 429 (página de erro, sessão intacta) em vez de devolver `null`. O `catch`
distingue o que ele mesmo levantou de uma falha de rede real — e o outro lado dessa bifurcação
também virou teste, porque é o que mantém a home de pé quando a API cai.

### E — os testes que matam as mutações

Janela (que a janela *é* uma janela, e que a unidade é ms), unidade do `retry-after` (`in 1..60`,
não `>= 1`), default da flag sem `put_env`, ordem de confiança do `ClientIp`, e o `refute 429` do
webhook trocado por `assert 401` exato — o frouxo aceitaria um 500 como prova de isenção.

### F — `ApiWeb.RateLimit` compartilhado

`client_key/1`, `deny/2` (com `retry-after`, agora nos **dois** plugs) e `enabled?/1`. O
`RateLimitAuth` encolheu; a divergência do `deny` fechou. `client_key/1` casa na cabeça da função,
como manda a rule.

### Resultado

| Gate | Antes | Depois |
|---|---|---|
| Testes API | 1.475 (2 falhas alheias) | **1.507 (as mesmas 2 falhas alheias)** |
| Cobertura API | 90,4% | **90,5%** (piso 80) |
| Testes web | — | **163 arquivos verdes** |
| Cobertura web (branch) | 74,63% ✗ | **76,21%** (piso 75) |
| `mix format` / `--warnings-as-errors` / `svelte-check` | limpo | limpo |

As duas falhas do `Api.RlsSmokeTest` são **pré-existentes e alheias** a esta fatia — provado com
`git stash`: elas ocorrem igual sem nenhuma mudança desta sessão. São da massa por pacote (Fase 2,
outra sessão).

---

## 4. O que a rodada 5 achou (e não consertou por decisão, não por esquecimento)

### 4.1 O teto de borda que eu mesmo escolhi estava apertado demais — **corrigido**

Ao auditar o próprio conserto: o estágio de borda conta por **IP**, e uma clínica inteira sai por
um IP só. Com 400/min, dez pessoas na recepção (cada uma com direito aos seus 200/min) estourariam
o teto e "o consultório está movimentado" viraria 429 para todo mundo. Subido para **2.000/min**,
derivado de 10 atores × o teto de cada um. Está documentado no plug, porque o número não é
arbitrário e a próxima pessoa precisa saber de onde ele veio.

### 4.2 Válvula de incidente separada — **corrigido**

`rate_limit_global_enabled` permite derrubar o teto global sem derrubar o anti-brute-force do
login. Com teste provando que o de auth continua de pé quando o global cai.

---

## 5. O que fica para você

### 5.1 A migração `_dev` é de outra sessão e tem um `DROP`+`CREATE` sem `CONCURRENTLY`

**O que é.** `20260728170142_migrate_resources1_dev.exs` (untracked, gerada por
`mix ash.codegen --dev` de outra sessão) faz `drop_if_exists` + `create index` do
`audit_events_feed_index`, sem `CONCURRENTLY` e dentro de transação.

**A sonda.**

```
[xid=2213452] CREATE INDEX "audit_events_feed_index" ON "audit_events" ("clinic_id","at","id")
        mode         | granted |     obj
---------------------+---------+--------------
 AccessExclusiveLock | t       | audit_events
 ShareLock           | t       | audit_events

linhas=500000  -> janela de ACCESS EXCLUSIVE = 938,7 ms
NOTICE: SELECTs concorrentes: n=60 | PIOR espera=206,5 ms | media=5,13 ms
```

`AccessExclusiveLock` bloqueia **leitura** também — pior que o `ShareLock` que a rule descreve. E
o índice resultante é byte a byte idêntico ao que `20260728140000` já criou com `CONCURRENTLY`:
janela de lock no `release_command` do deploy para **zero** mudança de schema, na tabela mais
escrita do sistema.

**Por que não corrigi.** O arquivo não é meu — é o codegen pendente de outra sessão, e
`.claude/rules/ash_postgres.md` manda fechar com `mix ash.codegen <nome>` nomeado, que espremeria
essa migration e resolveria isto no mesmo movimento. Eu só a toquei para destravar o `mix test`
(ver 5.2).

**A correção.** Apagar as duas linhas do `feed_index` (a 11 e a 23, mais o par no `down`): em banco
zerado a `20260728140000` já deixa o índice certo, e em produção ele já está lá.

### 5.2 O `mix test` em banco zerado estava quebrado antes desta sessão

A mesma migration recriava dois índices que a `20260728150000` (à mão, `CONCURRENTLY`) já tinha
criado — `ERROR 42P07 duplicate_table`. Troquei por `create_if_not_exists` para conseguir rodar a
suíte; medido, é no-op barato em produção (0,455 ms e 0,190 ms) e cria normalmente em CI. Fica no
tree como parte do trabalho da outra sessão, **não commitado por mim**.

### 5.3 A isenção dos webhooks é por path, não por identidade

**O que é.** `/webhooks/*` não passa por limitador nenhum — e a isenção vale para qualquer um, não
só para o provider.

**A sonda.** Três POSTs de 6,7 MB sem assinatura: `status=400` nos três, corpo lido inteiro em
cada um, nenhum 429.

**Por que não corrigi.** É a decisão de negócio que você tomou explicitamente nesta sessão ("tira
o limite do webhook, daí elimina o risco"), e a alternativa exige uma peça que não existe: limite
condicionado à assinatura válida, ou teto de tamanho de corpo por rota.

**A correção.** Limitar só o que **falha** a assinatura (o caminho legítimo do provider fica
ilimitado), ou um teto de corpo no `Plug.Parsers` para essas duas rotas.

### 5.4 `/socket` não passa pelo router — nenhum limitador o alcança

**A sonda.** `endpoint.ex:30` monta o socket; `endpoint.ex:66` é o `plug ApiWeb.Router`.
`curl /socket/websocket?vsn=2.0.0 -> 403`, ilimitado.

**Por que não corrigi.** É estrutural: o limite teria de morar no `connect/3` ou antes do
Endpoint, não no router. E sob Dokploy `/socket` é um dos dois únicos paths públicos, o que torna
a decisão parte da migração de deploy, não desta fatia.

### 5.5 A tabela nova cresce com chaves distintas

15,4 MB por 100 mil chaves. Um atacante rotacionando IP ainda cria linhas — a diferença é que
agora custa O(1) por hit, então não há mais o efeito de realimentação. Um milhão de IPs distintos
numa janela dariam ~154 MB. Não é urgente; se virar, o teto é `:ets.info(:size)` com poda por
tamanho, não só por idade.

### 5.6 Bug alheio pré-existente: `POST /api/auth/strategy/user/magic_link/request` responde 500

**A sonda.** 5 tentativas, `500 500 500 500 500` —
`** (FunctionClauseError) no function clause matching in Api.Accounts.Invites.activate_pending/1`
(`api/lib/api/accounts/invites.ex:15`), antes de qualquer envio de e-mail. Fora do alvo desta
auditoria; registro porque a rota agora está sob o teto global, e o que ela compra ali é 2.000
stacktraces por minuto por IP no log.
