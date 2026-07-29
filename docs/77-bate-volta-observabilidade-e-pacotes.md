# Bate-volta — observabilidade, pacotes e a leva de 2026-07-29

Alvo: **tudo que estava no `git status`** (209 arquivos versionados + 38 não-rastreados,
~20.700 linhas inseridas) **mais o commit anterior** (`a500e7e`, a máscara de telefone).

Sondado contra a stack rodando: `psql` como `postgres` **e** como `cinetra_app` **e** como
`cinetra_metrics`, `mix test` no container, `npm run build` de verdade, e `mix format
--check-formatted`.

---

## 1. Onde parou, e por quê

Parou na **5**, o percurso inteiro. A rodada 1 achou dois defeitos confirmados; a rodada 2
achou o que tornava um deles **muito mais grave do que a rodada 1 media** — e é o achado que
justifica o ângulo adversarial nesta leva.

---

## 2. A varredura

### Segurança

| Item | Estado | Prova |
| --- | --- | --- |
| Bypass do BFF / ataque direto na API | NÃO SE APLICA | Nenhuma rota nova confia em garantia do BFF; `/api/access-matrix` entra pelo `:authenticated` como as demais. |
| Tenant vindo do cliente | **CONFIRMADO** | `adjust_grade` aceita `professional_id` do corpo sem conferir a clínica — ver causa-raiz A. |
| IDOR / BOLA | REFUTADO | Rotas novas de pacote passam por `with_member_scope` + `get_patient_package!` (404 pelo escopo). `GET /packages/:id/sessions` relê o pacote pela porta de sempre antes de listar. |
| Broken Function Level Authorization | REFUTADO | `PackageSchedule` tem policy de `create/update` por papel; `AccessMatrixController` usa `with_member_scope`; tripwire em `access_matrix_test.exs` amarra 10 das 14 linhas às `can_*?`. |
| Mass assignment | **CONFIRMADO (parcial)** | `PackageSchedule.update` aceita `professional_id` sem validação de tenant — causa-raiz A. |
| CORS / CSRF | NÃO SE APLICA | Nenhuma mudança em cookie, origem ou verbo de mutação. |
| Brute force / enumeração no magic link | NÃO SE APLICA | Nenhuma superfície de auth no diff. |
| Token de magic link / capability | NÃO SE APLICA | Idem. |
| OAuth (Google) | NÃO SE APLICA | Idem. |
| Sessão / revogação | NÃO SE APLICA | Idem. |
| Ataque de timing | NÃO SE APLICA | Nenhuma comparação de segredo nova. |
| XSS (inclui e-mail transacional) | REFUTADO | `git diff HEAD -- web/` + grep nos não-rastreados: **zero** ocorrências de `{@html}` no diff, incluindo as páginas legais novas. |
| SQL injection | REFUTADO | A única SQL montada por interpolação é a das views `metrics_*`, e o insumo é uma **lista estática** (module attribute), não entrada. |
| SSRF | NÃO SE APLICA | O único `fetch` novo do servidor é o exportador OTLP, cujo destino vem de env, não de request. |
| Open redirect | NÃO SE APLICA | Nenhum parâmetro de destino novo. |
| Path traversal | NÃO SE APLICA | Nenhum caminho de arquivo derivado de entrada. |
| Vazamento de `clinic_id` | REFUTADO | `clinic_id` nas views `metrics_*` é deliberado (doc 05 §1.3 permite); não há novo serializer expondo tenancy. |
| Vazamento em log / erro | REFUTADO (com ressalva) | `OpentelemetryEcto` com `db_statement: :enabled` carrega SQL **parametrizado** — o valor não viaja. Ressalva registrada no §5. |
| Secrets em código | **CONFIRMADO → corrigido** | `setup_metrics_role.sql` embutia `PASSWORD 'cinetra_metrics'` e `compose.obs.yml` caía no mesmo default. Ver §5.2. |
| Headers de segurança | NÃO SE APLICA | Sem mudança em CSP/HSTS. |
| DoS | REFUTADO | Porta 4021 do PromEx **não é publicada** em `docker-compose.yml` nem em `compose.dokploy.yml` — conferido nos dois arquivos. |
| Dependência vulnerável | REFUTADO | Suítes verdes com as deps novas de OTel/axe; nenhum aviso de auditoria no build. |
| **Exposição de código-fonte por source map** | REFUTADO | `npm run build` real: `[sourcemaps] 117 mapa(s) movidos` e `find build/client -name '*.map'` → **0**. A guarda do `Dockerfile.prod` existe e o estágio final não copia `sourcemaps/`. |
| **Barreira de privilégio do role de métricas** | REFUTADO | `psql -U cinetra_metrics`: `permission denied for table patients` e `for table audit_events`; a view agregada responde. A barreira é o GRANT, como o doc afirma. |

### Performance

| Item | Estado | Prova |
| --- | --- | --- |
| N+1 | REFUTADO | `sessions_by_package/2` foi escrito justamente para evitá-lo: uma query com `package_id in ^ids` para todos os pacotes da ficha. |
| Seq scan onde devia haver índice | REFUTADO | `attendances(clinic_id, package_id)` e `attendances(package_id)` cobrem a trilha; `messages(clinic_id, appointment_id, inserted_at)` cobre o descarte de pendentes. |
| Query sem `LIMIT` / paginação | NÃO SE APLICA | As leituras novas são por pacote (cardinalidade do total do pacote, teto 120). |
| `SELECT *` desnecessário | NÃO SE APLICA | — |
| Aggregate / calculation caro | NÃO SE APLICA | — |
| Índice faltando em FK | REFUTADO | `package_schedules_professional_id_index` e `..._clinic_id_package_id_index` existem no banco. |
| Índice faltando no predicado | REFUTADO | `messages.agendado_para` **não é predicado de nenhuma query** — só é gravado e exibido (grep em `api/lib`). Índice ali seria custo de escrita puro. |
| Índice redundante / não usado | REFUTADO | `messages_appointment_id_index` (só FK) não é prefixo de `messages_appointment_index` (começa por `clinic_id`) — servem a coisas diferentes. |
| Pool de conexões | NÃO SE APLICA | Nenhum trabalho concorrente novo segurando conexão. |
| Transação longa segurando a GUC | REFUTADO | `descartar_pendentes/2` roda dentro de `with_clinic/2` e não faz I/O externo lá dentro. |
| Crescimento sem poda | NÃO SE APLICA | Prometheus com `retention.time` **e** `retention.size`; Tempo com volume próprio. |
| Front: waterfall / bundle | REFUTADO | A trilha do pacote é carregada **sob demanda** por rota própria, não no `load` da ficha. |

### Refatoração / rules

| Item | Estado | Prova |
| --- | --- | --- |
| Lógica duplicada | REFUTADO | `remove_session` reusa `Bulk.alvos/3` (mesma resolução de "futuras não resolvidas"). |
| Duas funções com o mesmo papel | REFUTADO | `motivo_do_descarte/1` é a autoridade única do par ação→motivo, e as três cláusulas passam por ela. |
| Constante/literal repetida | REFUTADO | `LIMITE_PLUG` é constante exportada e testada, em vez de número mágico. |
| Regra de negócio fora da action | REFUTADO | A matriz de acesso mora no backend ao lado das policies, com tripwire — exatamente para não virar prosa no web. |
| Comentário que duplica e contradiz | **CONFIRMADO (baixo)** → corrigido | `config.exs` citava `Api.PromEx.metrics_server_spec/0`; a função chama-se `metrics_server_children/0`. |
| Elixir: pattern matching, erros como valor, armadilhas | REFUTADO | Sem `String.to_atom` em entrada, sem `case` aninhado, sem process dictionary no diff. |
| Ash: policies, code interface, actor no changeset | REFUTADO | Ações novas expostas por code interface; `actor`/`scope` na chamada da action. |
| Docs e saída | **CONFIRMADO (baixo)** → corrigido | Números de doc **colidiam**: 73, 74 e 76 tinham 2–3 arquivos cada, e o código referenciava "doc 73" sem desambiguar. Renumerados (§5.4). |
| **Gate de formatação** | **CONFIRMADO** | `mix format --check-formatted` reprovava em **3 arquivos do diff** — o CI quebraria. |
| **Artefato de build versionado** | **CONFIRMADO** | 14 arquivos / 507 linhas de `.svelte-kit/` e `node_modules/.vite/` **staged para commit**. |

### O que a rodada 2 achou que a 1 não tinha achado

A rodada 1 mediu a causa-raiz A pelo ângulo de **tenancy**: "aceita `professional_id` de outra
clínica". Isso descreve um atacante que precisa conhecer o UUID de um profissional alheio.

A rodada 2 fechou as listas e perguntou o que um operador faria por acidente — e a resposta
mudou a severidade: **um profissional ARQUIVADO da própria clínica dispara o mesmo estrago**,
sem nenhum conhecimento cross-tenant. Sai do terreno de "ataque" e entra no de "terça-feira no
balcão". Medido:

```
--- ANTES: %{"agendado" => 4}
--- adjust_grade p/ profissional INATIVO: :ok
--- DEPOIS: %{"cancelado" => 4}
--- sessões VIVAS depois: 0 (o pacote foi vendido com 4)
```

Foi também a rodada 2 que localizou a **segunda metade** da causa (o silêncio), lendo o
`Materializer` em vez do `Packages`.

---

## 3. As causas-raiz

### A — `adjust_grade` destrói antes de validar, e a falha é silenciosa

Duas metades, e é a combinação que faz o dano:

1. **`Api.Packages.adjust_grade/3` cancelava as sessões futuras antes de saber se a grade nova
   materializa.** O `professional_id` vinha do corpo e ninguém perguntava se era desta clínica
   nem se estava ativo. `Api.Directory.professional_inactive?/2` não cobre: é uma pergunta
   **negativa** — para um id que não existe na clínica ela responde `false`, ou seja "pode".
2. **`Materializer.create_sessions/3` descartava o erro.** `Enum.each` ignorava o
   `{:error, _}` de `create_and_stamp/5` e devolvia `:ok`; o Oban registrava **sucesso** com
   zero linha escrita e nenhum registro em lugar nenhum.

Resultado: pacote vendido com 4 sessões fica com **0 na agenda**, `total` intacto, sem erro na
tela, sem linha de log, sem job falhado.

Três entradas para o mesmo buraco, todas confirmadas por sonda:

* `professional_id` de outra clínica → grava referência cross-tenant em `package_schedules` **e**
  perde as sessões;
* `professional_id` de profissional arquivado da própria clínica → perde as sessões (a entrada
  acessível);
* `professional_id` ausente com o profissional da grade arquivado desde então → mesma perda.

E a **mesma falta de validação pela porta da criação**: `create_series` com profissional de outra
clínica estourava `MatchError` em `Preview.availability_by_date/5` → **500** em vez de 422.

### B — Artefato de build entrando no commit

`.svelte-kit/` (8 arquivos) e `node_modules/.vite/` (6) na **raiz** do repositório, staged. O
`web/.gitignore` cobre `web/.svelte-kit`, mas não alcança a raiz, e o `.gitignore` da raiz não
tinha as entradas. São 507 linhas de arquivo gerado.

### C — O diff reprovava no gate de formatação

`mix format --check-formatted` falhava em `lib/api/accounts/access_matrix.ex`,
`test/api/records/patient_test.exs` e `test/api_web/controllers/patients_controller_test.exs`.
O job `api` do CI roda esse comando.

---

## 4. O que foi corrigido

### A — a validação vem antes da destruição

**Sonda que encontrou:** teste de domínio com duas clínicas, medindo o estado das sessões no SQL
cru depois da chamada.

**Testes vermelhos primeiro** (`api/test/api/packages/lifecycle_test.exs`, no
`describe "ajustar a grade"`), 4 novos:

```
1) recusa profissional INATIVO da própria clínica — e não cancela as futuras
   left:  {:error, :profissional_inativo}   right: {:ok, %Api.Packages.Package{...}}
2) create_series recusa profissional de OUTRA clínica sem estourar
   ** (MatchError) no match of right hand side value: {:error, :professional_not_found}
3) recusa profissional de OUTRA clínica — e não cancela as futuras
   left:  {:error, :profissional_invalido}  right: {:ok, %Api.Packages.Package{...}}
4) recusa quando o profissional que FICA na grade foi arquivado
   left:  {:error, :profissional_inativo}   right: {:ok, %Api.Packages.Package{...}}
36 tests, 4 failures
```

**Conserto:**

* `Api.Packages.checar_profissional/2` — pergunta **positiva** ("existe nesta clínica e está
  ativo?"), rodando dentro de `in_clinic` para a RLS. É o que fecha o caso cross-tenant, que a
  pergunta negativa de `professional_inactive?/2` deixava passar.
* `profissional_efetivo/2` — valida o profissional que a grade **vai usar** (o do corpo quando
  veio, senão o que já estava lá), não só o que chegou no request.
* Em `adjust_grade/3` a checagem entra no `with` **antes** da escrita da grade e do
  cancelamento das futuras.
* Em `create_series/3`, **antes** do `Preview` — que é onde estourava.
* `Materializer.create_sessions/3` deixa de descartar o erro: registra cada sessão que não
  nasceu e um total. Continua devolvendo `:ok` de propósito (recusa por conflito é caso normal;
  virar erro de job poria a fila em retry eterno) — o que muda é que passa a ter registro.
* Mensagens de 422 no controller para os dois motivos novos.

**Re-sonda (rodada 5), com as mesmas sondas que acharam:**

```
--- create_series com prof de outra clínica: :error
--- adjust_grade p/ profissional INATIVO: :error
--- DEPOIS: %{"agendado" => 4}
--- sessões VIVAS depois: 4 (o pacote foi vendido com 4)
--- adjust_grade com prof de OUTRA clínica: {:error, :profissional_invalido}
3 tests, 0 failures
```

O caminho feliz continua reprojetando (4 canceladas → 4 novas na grade nova), medido antes e
depois — o conserto recusa o inválido sem endurecer o válido.

**A rodada 5 auditando o próprio conserto — e achando um teste vazio.** `checar_profissional/2`
é uma leitura por-tenant nova num caminho de escrita: exatamente a classe de bug que o gate
`:rls` existe para pegar. Escrevi um teste `@tag :rls` e ele passou como `cinetra_app`. Só que
teste verde não prova nada até a regra ser **mutada**: tirando o `in_clinic` da função, o teste
**continuou verde**.

A razão é o sandbox — a suíte roda tudo numa transação só, então a GUC que o `in_clinic` anterior
pendurou com `SET LOCAL` ainda valia quando a checagem rodava. É o limite conhecido deste gate
(prova a porta de entrada, não cada leitura interna), e o comentário do teste foi reescrito para
dizer isso em vez de prometer um tripwire que ele não entrega.

A necessidade do `in_clinic` ficou provada **fora** da suíte, por `psql` direto:

```
cinetra_app, SEM a GUC : 0 profissionais
cinetra_app, COM a GUC : 1 profissional
```

Sem ele, em produção (transação por ação, sem GUC herdada) **todo** ajuste de grade passaria a
recusar com `:profissional_invalido` — um conserto que teria trocado um bug por outro, e a suíte
inteira seguiria verde.

### B — artefato de build fora do índice

`git rm -r --cached .svelte-kit node_modules` (só do índice; os diretórios seguem em disco) e
entradas novas no `.gitignore` da raiz, com o porquê escrito. `git status` deixou de vê-los.

### C — formatação

`mix format` nos 5 arquivos (3 do diff + 2 meus). `mix format --check-formatted` sai `EXIT=0`, e
`mix compile --warnings-as-errors` compila limpo.

---

### Os gates, depois de tudo

| Gate | Antes | Depois |
| --- | --- | --- |
| `mix test` | 1635 testes, 0 falhas | **1640 testes + 18 doctests, 0 falhas** (5 novos) |
| `mix test --only rls` (como `cinetra_app`) | não rodava sem `SKIP_DB_SETUP` | **0 falhas**, 14 exercitados |
| `mix format --check-formatted` | **reprovava em 3 arquivos** | `EXIT=0` |
| `mix compile --warnings-as-errors` | limpo | limpo |
| `npm run test:unit` | 179 arquivos, 2095 testes, 0 falhas | inalterado (nada de `web/` foi tocado) |
| `npm run build` | — | 117 mapas movidos, **0** `.map` em `build/client` |

---

## 5. O que ficou para você

> **Revisado em 2026-07-29, com decisão tomada.** Sete dos oito itens abaixo foram resolvidos na
> mesma sessão, depois da leitura deste relatório. O único que **segue aberto** é o §5.7 (limite do
> gate `:rls`), que virou o débito D-15 — e o §5.1 fica parcial por ser estrutural. Cada seção
> resolvida diz o que foi feito.
>
> | Item | Decisão |
> | --- | --- |
> | §5.1 silêncio do materializador | **parcialmente resolvido** — o `+1` passou a ser síncrono e a devolver o motivo |
> | §5.2 senha do role de métricas | **resolvido** — `:?` no compose, `-v senha=` no `.sql`, sem default em lugar nenhum |
> | §5.3 `--web.enable-admin-api` | **resolvido** — flag removida |
> | §5.4 números de doc colidindo | **resolvido** — duplicados renumerados para 78–81 |
> | §5.5 átomo interno no 422 | **resolvido** — as duas portas passam por uma tradução só |
> | §5.6 comentário morto | **resolvido** |
> | §5.7 gate `:rls` | **aberto**, registrado como D-15 |
> | §5.8 tripwire da matriz | aceito, sem ação |

### 5.1 O silêncio do materializador — o `+1` foi resolvido; o resto segue estrutural

**O que é:** o job agora **registra** a sessão que não nasceu, mas continua devolvendo `:ok`. Um
pacote pode perder sessões por qualquer outro motivo (conflito, constraint) e o Oban seguirá
marcando sucesso.

**Sonda:** leitura de `create_sessions/3` — `Enum.each` sem inspeção do retorno, agora `reduce`
com log.

**Por que não foi corrigido:** é **decisão de arquitetura**. Fazer o job falhar poria a fila em
retry eterno num caso que é normal (recusa por conflito, que o `forcar`/encaixe existe para
resolver). A correção certa provavelmente não é o retorno do job, e sim **reconciliação**: o
pacote saber comparar `total` com as sessões vivas e sinalizar a divergência na ficha.

**Correção sugerida:** um campo derivado `sessoes_vivas` no pacote e um aviso na ficha quando
`sessoes_vivas < restantes`, em vez de confiar no job.

**O que foi feito (2026-07-29):** o caso que mais doía saiu do job. O `+1` (`add_session/2`) passou
a **materializar antes de somar ao total**, de forma síncrona, e a devolver o motivo quando a sessão
não nasce — o `Materializer` ganhou `materializar/3`, que é o mesmo caminho do `perform/1` com o
resultado subindo em vez de engolido. A ordem é o conserto: se a sessão não nasce, o total não
sobe, e não há o que desfazer (nada de transação em volta das duas escritas, que é o que quebra o
caminho de erro sob RLS). O teto do pacote passou a ser conferido **antes** de materializar, lendo
o `max` do próprio recurso, senão a sessão nasceria e só depois o `set_total` a recusaria.

**O que continua aberto:** a criação da série inteira segue assíncrona e segue engolindo o motivo —
lá é a resposta certa (40 escritas não podem segurar a requisição, e recusa por conflito é caso
normal). Para esse caso a reconciliação sugerida acima continua valendo, e é o que fecharia o
assunto de vez.

### 5.2 Senha do role de métricas caía num default conhecido — CORRIGIDO (aprovado 2026-07-29)

**O que era:** `deploy/observability/compose.obs.yml` usava
`METRICS_DB_PASSWORD: ${METRICS_DB_PASSWORD:-cinetra_metrics}` e
`api/priv/sql/setup_metrics_role.sql` embutia `PASSWORD 'cinetra_metrics'`. Ao lado, o Grafana usa
`${GRAFANA_ADMIN_PASSWORD:?defina GRAFANA_ADMIN_PASSWORD}` — que **recusa subir** sem a variável.
Duas posturas para dois segredos do mesmo stack.

O risco não era o dev: era o `.sql` ser aplicado contra **produção** (o comando do cabeçalho é o
que se copia e cola), criando lá um usuário de leitura com senha publicada no repositório. Como as
views `metrics_*` rodam com os direitos do dono e **ignoram RLS por construção**, esse usuário lê
o agregado de todas as clínicas.

**O conserto:** `:?` no compose, e no `.sql` a senha passa a vir de `-v senha=…`, com guarda de
mínimo 8 caracteres antes de qualquer DDL.

**Um detalhe que a implementação revelou:** variável **ausente** e variável **vazia** são casos
diferentes. Com `senha` não definida, o `psql` não substitui `:'senha'` — ele manda os caracteres
literais para o servidor, e o script morria em `ERROR: syntax error at or near ":"`. Aborta e não
cria nada (seguro), mas não diz a quem rodou o que fazer. Um `\if :{?senha}` define a variável como
vazia e a guarda é que responde.

**Re-sonda:**

```
sem a variável   → ERROR: senha do role de metricas ausente ou curta … EXIT=3
senha "abc"      → mesma mensagem, EXIT=3
senha válida     → ALTER ROLE / GRANT / DO, EXIT=0
```

E o `ALTER` aplica de fato — provado pelo hash em `pg_authid`, que muda entre execuções
(`SCRAM-SHA-256$4096:b4YAdj…` → `…bJCijF…`). **O teste por login não serviria:** o `pg_hba` do
container de dev tem `trust` para localhost, então a senha antiga continuava entrando pela porta
que eu estava usando. Quem exige senha é a linha `host all all all scram-sha-256`, que é por onde
o Grafana entra — de outro container, pela rede.

A barreira do GRANT segue intacta depois da mudança: `permission denied for table patients`, com a
view agregada respondendo.

**O que NÃO foi mexido, e continua sendo seu:** os nomes divergem —
`DATABASE_METRICS_PASSWORD` (`.env` da aplicação, quem **cria** o role) e `METRICS_DB_PASSWORD`
(`.env` da observabilidade, quem **conecta**). Unificar tocaria `release.ex`,
`compose.dokploy.yml`, `.env.example` e os docs; por ora o acoplamento está escrito nos dois
arquivos, onde quem opera o deploy vai ler.

**Correção sugerida:** trocar o default por `:?` no `compose.obs.yml` e tirar a senha literal do
`.sql`, exigindo-a por variável também em dev.

### 5.3 Prometheus com `--web.enable-admin-api` — RESOLVIDO (flag removida)

**O que é:** a flag permite apagar séries por HTTP. O Prometheus é `expose`, não `ports` —
alcançável só de dentro da rede `obs`.

**Sonda:** `compose.obs.yml` linhas 172 e 186.

**Decisão (2026-07-29): a flag saiu.** O que se ganhava — apagar série com label errado pela UI —
tem contorno barato: recriar o volume do Prometheus. Dado de série temporal é reconstituído pela
raspagem seguinte, ao contrário de log e trace, então o custo do contorno é baixo e o custo do
pior caso (qualquer container na rede `obs` zerando o histórico durante o incidente em que ele
seria lido) não é. O compose explica como religá-la para uma investigação pontual.

### 5.4 Números de doc colidiam, e o código referenciava por número — RESOLVIDO

**O que era:** `73`, `74` e `76` tinham 2–3 arquivos cada. O código citava "doc 73" sem caminho, e
o alvo **mudava conforme o arquivo**: em `release.ex`, "doc 73" era o de dashboards; em
`fingerprint.ts`, o do Sentry.

**Sonda:** `ls docs/ | grep '^7'` + grep de `doc 73|doc 74|doc 76` em `api/lib` e `web/src`.

**O que foi feito** (decisão de 2026-07-29): os duplicados foram renumerados. Em cada número
**ficou o documento que as referências do código já queriam dizer**, o que fez a maioria das
citações passar a estar certa sem edição:

| Número | Fica | Por quê |
| --- | --- | --- |
| 73 | `73-dashboards-do-log-ao-banco.md` | 5 das 9 citações a "doc 73" eram dele (`release.ex`, `metrics_views.exs`, `compose.dokploy.yml`) |
| 74 | `74-metricas-do-servidor.md` | **todas** as citações a "doc 74" eram dele (`prom_ex.ex`, `application.ex`, `mix.exs`, configs) |
| 76 | `76-traces.md` | **todas** as citações a "doc 76" eram dele (~18, de `otel.mjs` a `alloy.alloy`) |

Os quatro deslocados: `78-sentry-vale-a-pena.md`, `79-signoz-vs-hyperdx.md`,
`80-acessibilidade-auditoria.md`, `81-paginas-legais-e-aceite.md`.

**O que a escolha custa, dito com clareza:** a numeração deixa de ser estritamente cronológica
para esses quatro — 78 e 79 são estudos que precederam o que está em 73 e 74. Foi a troca
deliberada: numeração única e citação correta valem mais que ordem de escrita, e resequenciar
`70..81` inteiro moveria 5 documentos e toda referência cruzada a eles.

De quebra, dois erros de link apareceram na varredura e foram corrigidos: `docs/62` dizia
"métricas no doc 74" **apontando para o comparativo SigNoz**, e `docs/64` citava "doc 76 §3" para
uma decisão de paleta que mora no de acessibilidade.

### 5.5 `motivo_do_ciclo(outro) → to_string(outro)` — RESOLVIDO

**O que é:** cláusula catch-all no `packages_controller.ex` que transforma **qualquer** átomo
interno em mensagem de 422 para o usuário. Um erro interno novo vaza o nome do átomo para a tela.

**Sonda:** leitura de `packages_controller.ex`.

**O que foi feito (2026-07-29): as duas portas de uma vez**, que era a condição para não criar
divergência. `motivo_do_ciclo/1` deixou de ter `to_string(outro)` como default: átomo sem frase
vira uma mensagem genérica **e uma linha de `Logger.warning`** — o motivo não desaparece, muda de
público, e vai para quem pode agir sobre ele. `series_error/2` deixou de usar `inspect/1`: átomo
conhecido passa pela mesma tradução, e erro do Ash é encaminhado para `error_response/2`, que já
tem campo e mensagem próprios. Uma tabela, duas portas.

### 5.6 Comentário desatualizado em `config.exs` — RESOLVIDO

`config.exs` citava `Api.PromEx.metrics_server_spec/0`; a função é `metrics_server_children/0` — o
próprio moduledoc de `Api.PromEx` explica por que ela devolve **lista**. Corrigido em 2026-07-29:
quem grepasse pelo nome errado não acharia nada e concluiria que o servidor de métricas não está
ligado.

### 5.7 O gate `:rls` não alcança leitura interna (limite estrutural, medido aqui)

**O que é:** o gate roda como `cinetra_app`, mas dentro do sandbox tudo acontece numa transação
só. A primeira `SET LOCAL` de um teste deixa a GUC pendurada para o resto dele, então uma leitura
interna sem `in_clinic` **não** é detectada.

**Sonda:** mutação — removi o `in_clinic` de `checar_profissional/2` e rodei `mix test --only rls`
como `cinetra_app`: **0 falhas**. A necessidade só apareceu no `psql` (0 vs. 1 profissional).

**Por que não foi corrigido:** é estrutural. Fazer cada teste rodar em transação própria mudaria o
arnês inteiro (`DataCase`, sandbox, `async`).

**Correção sugerida:** para leitura por-tenant nova em caminho de escrita, a prova continua sendo
`psql` sob `cinetra_app` — e vale registrar isso no `.claude/rules/migrations.md`, ao lado da
lição que já está lá, porque hoje o texto sugere que o gate cobre mais do que cobre.

### 5.8 O tripwire da matriz cobre 10 das 14 linhas (aceito, registrado)

`access_matrix_test.exs` amarra às `can_*?` as áreas com sonda viável. As 4 restantes
(`comunicacao`, `relatorios`, `notificacoes`, e a leitura de `auditoria`) são exatamente as
células `:propria`/leitura, que `can_*?` não sabe medir porque **policy de read filtra em vez de
negar**. O teste documenta isso. Não é defeito — fica registrado que ~29% da matriz é garantida
por testes de recorte de outros arquivos, não pelo tripwire.
