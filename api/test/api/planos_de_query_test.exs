defmodule Api.PlanosDeQueryTest do
  @moduledoc """
  Os **acoplamentos de índice que quebram em silêncio** (doc 92, Onda 2).

  Um índice não desaparece quando deixa de servir: ele continua no catálogo, íntegro, pesando em
  toda escrita — e a query que ele existia para acelerar volta a varrer a tabela. Não há erro, não
  há falha de teste, e o sintoma (uma tela um pouco mais lenta) só aparece com volume, em
  produção. É o modo de falha mais caro que este schema tem, porque o custo de descobrir é alto e
  o de vigiar é este arquivo.

  ## Por que `enable_seqscan = off`

  O banco do sandbox é praticamente vazio, e num punhado de linhas o planejador escolhe `Seq Scan`
  por custo — sempre, com ou sem índice. Isso esconderia a única coisa que se quer afirmar aqui,
  que é **sargabilidade**: existe um índice que o planejador *consegue* usar para este predicado?
  Desligar o seqscan tira a decisão de custo do caminho e deixa só a de capacidade.

  O que este arquivo **não** faz é medir desempenho — para isso o projeto mede pelo caminho da
  aplicação com volume (`.claude/rules/migrations.md`). Aqui a pergunta é binária.

  ## Por que o SQL vem do Ash, e não escrito à mão

  Porque o risco que motivou o §4.1 do doc 92 é exatamente *o SQL mudar*. Um teste que digitasse o
  predicado com o cast continuaria verde para sempre, inclusive no dia em que o AshPostgres
  parasse de emiti-lo — que é o dia que importa.
  """
  use Api.DataCase, async: false

  require Ash.Query

  # `SET LOCAL` vale até o fim da transação do sandbox, e vai sozinho: o protocolo estendido não
  # aceita duas instruções num mesmo prepared statement.
  defp plano(sql, params) do
    Api.Repo.query!("SET LOCAL enable_seqscan = off")

    Api.Repo.query!("EXPLAIN (COSTS OFF) " <> sql, params).rows
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp sql_do_ash(query) do
    {:ok, ecto} = Ash.Query.data_layer_query(query)
    Ecto.Adapters.SQL.to_sql(:all, Api.Repo, ecto)
  end

  describe "notifications_unread_index — o índice parcial preso ao cast (P2-6)" do
    # O índice é parcial em `read_at::timestamp IS NULL`, e o cast NÃO é enfeite: `read_at` é
    # `timestamp(0)` e o AshPostgres emite a comparação com cast para `timestamp` (µs). O
    # Postgres só usa índice parcial quando prova que o predicado do índice implica o da query, e
    # ele não prova isso ATRAVÉS de uma conversão real de tipo.
    #
    # Medido nas duas direções em 2026-08-03: o índice com cast serve só a query com cast, e um
    # índice sem cast serve só a query sem cast. O casamento é exclusivo e bidirecionalmente cego.
    #
    # Consequência: um upgrade de AshPostgres/Ecto que pare de emitir o cast **desanexa o índice
    # sem sintoma nenhum**. É este teste que dá o sintoma.
    test "o SQL que o Ash emite para a caixa não-lida continua anexando ao índice parcial" do
      {sql, params} =
        Api.Notifications.Notification
        |> Ash.Query.for_read(:unread, %{}, authorize?: false)
        |> Ash.Query.set_tenant(Ash.UUID.generate())
        |> sql_do_ash()

      assert plano(sql, params) =~ "notifications_unread_index",
             """
             A caixa de não-lidas parou de usar `notifications_unread_index`.

             A causa provável é o AshPostgres ter mudado a forma do predicado — o índice é
             parcial em `read_at::timestamp IS NULL` e só casa com essa forma exata. O índice
             continua no catálogo, pesando em toda escrita de `notifications`, e o badge do sino
             passou a varrer a caixa inteira.

             Conserte recriando o índice na forma nova (ver `Api.Notifications.Notification`),
             não apagando este teste.

             SQL emitido:
                 #{sql}

             Plano:
                 #{plano(sql, params)}
             """
    end
  end

  describe "tokens — os dois caminhos que não passam por `jti` (P1-4)" do
    # `revoke_all_stored_for_subject` filtra por `subject` (é o "sair de todas as sessões"), e a
    # tabela tinha um único índice: o PK sobre `jti`. Medido em 200.000 tokens de 5.000 usuários:
    #
    #     sem índice   Seq Scan       2.131 buffers   13,116 ms
    #     com índice   Bitmap Index      42 buffers    0,118 ms
    #
    # `tokens` é uma das poucas tabelas cujo crescimento é proporcional a LOGINS, não a pacientes.
    # A asserção é sobre o NOME do índice, não sobre a forma do nó, e isso custou uma corrida:
    # `tokens` é tabela global e o que sobra nela depende de quais testes de auth rodaram antes.
    # Com poucas linhas o plano sai `Index Scan using tokens_subject_index`; com mais, `Bitmap
    # Index Scan on tokens_subject_index`. Casar a primeira forma deixava o teste vermelho a cada
    # três execuções — e o índice estava lá o tempo todo.
    test "a revogação por subject tem índice para usar" do
      plano = plano("SELECT jti FROM tokens WHERE subject = $1", ["user?id=x"])

      assert plano =~ "tokens_subject_index",
             """
             Revogar sessão voltou a varrer `tokens` — ver o `custom_indexes` de
             `Api.Accounts.Token`. Plano:

             #{plano}
             """
    end

    # O par negativo, e ele documenta uma decisão: `expunge_expired` NÃO ganhou índice, porque
    # medido ele não teria funcionado. O Ash emite `expires_at::timestamp < $1::timestamp`, e
    # `expires_at` é `timestamp(0)` — um btree comum sobre a coluna fica intocado, pelo mesmo
    # mecanismo do §4.1 acima. Com 200.000 linhas, criar o índice manteve o `Seq Scan`:
    #
    #     sem índice   Seq Scan   255 buffers   2,619 ms
    #     com índice   Seq Scan   255 buffers   2,293 ms   ← intocado
    #
    # Serviria um índice de EXPRESSÃO sobre `(expires_at::timestamp)`. Não foi criado: o expurgo
    # é job noturno, 2,6 ms em 200 mil linhas não é problema, e índice de expressão é justamente o
    # acoplamento que este arquivo existe para vigiar. Entra quando houver número de produção
    # pedindo — não por simetria com o de cima.
    test "o expurgo por expires_at NÃO tem índice, e isso é decisão registrada" do
      plano =
        plano("SELECT jti FROM tokens WHERE expires_at::timestamp < $1::timestamp", [
          NaiveDateTime.utc_now()
        ])

      refute plano =~ "expires_at_index",
             """
             Apareceu um índice sobre `tokens.expires_at`. Se ele foi criado de propósito, ótimo
             — mas então meça se ele é de fato usado (um btree comum NÃO é, por causa do cast) e
             atualize este teste com o número. Se apareceu sozinho, é peso de escrita sem leitura.
             """
    end
  end
end
