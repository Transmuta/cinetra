# Migrations e DDL: duas regras do projeto

Regra própria do projeto (não é usage_rules de pacote — essas ficam em
[`ash_postgres.md`](ash_postgres.md), que é derivado do pacote e pode ser re-sincronizado).

Ambas nasceram de achados medidos no bate-volta de 2026-07-23; o diagnóstico completo está em
[`docs/35-plano-execucao-backlog.md`](../../docs/35-plano-execucao-backlog.md).

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
