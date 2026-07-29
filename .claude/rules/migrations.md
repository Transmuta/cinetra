# Migrations, DDL e RLS: três regras do projeto

Regra própria do projeto (não é usage_rules de pacote — essas ficam em
[`ash_postgres.md`](ash_postgres.md), que é derivado do pacote e pode ser re-sincronizado).

As duas primeiras nasceram de achados medidos no bate-volta de 2026-07-23; o diagnóstico completo
está em [`docs/35-plano-execucao-backlog.md`](../../docs/35-plano-execucao-backlog.md). A terceira é
de 2026-07-29 ([`docs/77`](../../docs/77-bate-volta-observabilidade-e-pacotes.md)) e existe porque o
CLAUDE.md aponta para cá quando fala de RLS — e o texto não estava aqui.

## 1. Elixir escrito à mão não mora em `priv/`

`priv/` é **ponto cego de todos os gates** do projeto. Medido:

- **fora do formatter** — `.formatter.exs` tem `inputs: ["*.{ex,exs}", "{config,lib,test}/**/*.{ex,exs}"]`;
  `priv/` não entra, então `mix format --check-formatted` nunca olha;
- **fora do compilador** — `.exs` rodado por `mix run` não é compilado, então
  `mix compile --warnings-as-errors` não vê função inexistente, alias morto nem typo;
- **fora da cobertura** — o ExCoveralls só instrumenta módulo compilado.

Um script de 164 linhas chegou a viver ali sem nenhuma checagem automática. Pior: **`priv/` é
embarcado no release** (`Dockerfile.prod`: `COPY priv priv`), então um script de dado de dev viaja
para a imagem de produção e é alcançável por `bin/api eval`.

**Onde as coisas vão, então:**

- gerador de dado para teste/carga → `test/support/` (não vai para a imagem) ou `Ash.Generator`,
  que é o que [`ash.md`](ash.md) manda usar e o repo ainda não usa;
- tarefa operacional de verdade → `Mix.Task` em `lib/mix/tasks/` (compilada, formatada, coberta);
- migration → `priv/repo/migrations/`, que é a **exceção legítima**: é artefato gerado pelo
  `mix ash.codegen`, não código escrito à mão. Por isso também **não** se adiciona `priv/` ao
  formatter: o gerador produziria arquivo já reprovado no `--check-formatted`, e reformatar
  migration que já rodou em produção é churn sem ganho.

## 2. `CREATE INDEX` em tabela quente pede `CONCURRENTLY`

`CREATE INDEX` comum toma **`ShareLock`** na tabela, que conflita com `RowExclusiveLock` — todo
`INSERT`/`UPDATE`/`DELETE` fica na fila enquanto o índice é construído. Medido em `appointments`
com 10.185 linhas: **167 ms**, e escala linearmente com o volume real. Como
`Api.Release.setup/0` roda as migrations no `release_command`, essa janela cai **no deploy**.

Para índice em tabela que já tem volume, use:

```elixir
@disable_ddl_transaction true
@disable_migration_lock true

def up do
  execute "CREATE INDEX CONCURRENTLY IF NOT EXISTS nome_do_indice ON tabela (colunas)"
end

def down do
  execute "DROP INDEX CONCURRENTLY IF EXISTS nome_do_indice"
end
```

As duas anotações são **obrigatórias**: `CONCURRENTLY` não roda dentro de transação, e a migration
do Ecto abre uma por padrão. Em tabela nova ou vazia não vale a pena — `CONCURRENTLY` faz duas
varreduras e é mais lento; a regra é sobre tabela **com dado**.

> Antes de criar índice de **expressão**, leia a lição em
> [`docs/35`](../../docs/35-plano-execucao-backlog.md) ("D-A — o diagnóstico correto"): um índice
> de expressão só anexa se a expressão bater **byte a byte** com o SQL que o Ash emite — e o
> AshPostgres injeta casts (`::timestamp`). Meça sempre pelo caminho da aplicação
> (`pg_stat_user_indexes.idx_scan` antes/depois), nunca por SQL digitado no `psql`.

## 3. O gate `:rls` prova a porta de entrada, **não** cada leitura interna

A regra de sempre continua valendo: **toda leitura por-tenant precisa de `Api.Tenancy.in_clinic/2`
(ou `Api.Repo.with_clinic/2`)**. Sem ela, sob o role do servidor, a RLS não levanta erro — ela
devolve **zero linhas**. Medido, a mesma chamada sob os dois roles:

```
cinetra_app (role do servidor), SEM in_clinic : 0 profissionais
cinetra_app, COM in_clinic                    : 1 profissional
postgres (role do mix test)                   : 1 profissional
```

O que esta regra acrescenta é o **alcance do gate**, porque acreditar nele além disso já quase
custou um bug:

> `mix test --only rls` roda como `cinetra_app`, mas o sandbox roda o teste inteiro dentro de **uma
> transação**. Como a GUC é `SET LOCAL`, a primeira escrita do setup a deixa **pendurada** até o fim
> do teste, e qualquer leitura posterior a herda de graça. Logo: o gate pega a leitura que abre o
> caminho; ele **não** pega uma leitura interna, mais adiante no mesmo fluxo, que esqueceu a GUC.

**Como isso foi medido** (doc 77 §5.7 → débito D-15): removi o `in_clinic` de
`Api.Packages.checar_profissional/2` — leitura por-tenant nova dentro do caminho de escrita de
`adjust_grade/3` — e rodei o gate como `cinetra_app`. Resultado: **0 falhas**. Nem chamar o
`sem_guc/0` do próprio arquivo resolve, porque a ação torna a setar a GUC antes de chegar lá.

### O que fazer, então

**Leitura por-tenant nova em caminho de escrita se prova por `psql`, sob o role restrito** — não
pelo gate:

```bash
# sem a GUC: tem de dar 0
docker compose exec -T -e PGPASSWORD=cinetra_app db \
  psql -U cinetra_app -d cinetra_dev -c "select count(*) from professionals;"

# com a GUC: tem de dar N
docker compose exec -T -e PGPASSWORD=cinetra_app db psql -U cinetra_app -d cinetra_dev \
  -c "begin; select set_config('cinetra.clinic_id','<uuid-da-clinica>',true);
      select count(*) from professionals; commit;"
```

E vale para qualquer teste de RLS que você escreva: **mute a regra e confira que o teste fica
vermelho.** Se ele continuar verde com o `in_clinic` removido, ele não está provando o que o nome
dele diz — e é melhor descobrir isso agora do que no servidor, onde o sintoma é a operação recusar
**tudo** (a leitura volta vazia, o código lê isso como "não existe").

Corolário do mesmo espírito da nota do índice acima: em RLS, como em plano de query, **a suíte não
é a medida — o caminho da aplicação é.**
