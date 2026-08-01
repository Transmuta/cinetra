defmodule Api.Housekeeping.PodaTest do
  @moduledoc """
  O mecanismo comum das podas (`Api.Housekeeping.Poda`), testado direto.

  Os três jobs que o usam têm testes próprios, e eles cobrem o **resultado** (a linha velha some,
  a recente fica). O que nenhum deles alcança é o **laço**: com o teto de produção (5.000) um
  único `DELETE` sempre dá conta, então a recursão — a parte que existe para uma clínica com anos
  de histórico não virar uma transação só — nunca dava a segunda volta em teste nenhum.

  Por isso o teto é configurável. Aqui ele desce para 2 e o laço passa a ser exercitado de fato.

  ## O que este arquivo NÃO consegue provar

  Que cada lote roda na **própria transação** (doc 96, P-3). Sob o sandbox do Ecto o teste inteiro
  já corre dentro de uma transação, e `Repo.transaction/1` aninhado vira `SAVEPOINT` — de dentro,
  "estou numa transação?" responde `true` antes e depois da mudança. É a mesma cegueira estrutural
  do débito **D-15**, por um caminho diferente. O que resta como rede é o gate `mix test --only
  rls`, que roda como `cinetra_app` e reprova se algum lote perder a GUC.
  """
  use Api.DataCase, async: false

  alias Api.Housekeeping.Poda

  setup do
    anterior = Application.get_env(:api, Poda, [])
    Application.put_env(:api, Poda, Keyword.put(anterior, :lote, 2))
    on_exit(fn -> Application.put_env(:api, Poda, anterior) end)
    :ok
  end

  defp semear_eventos(clinic_id, quantos) do
    for _ <- 1..quantos do
      Api.Repo.query!(
        """
        INSERT INTO webhook_events (id, provider, digest, inserted_at)
        VALUES (uuid_generate_v7(), 'zernio', $1, now() - interval '400 days')
        """,
        ["#{clinic_id}-#{System.unique_integer([:positive])}" |> hash()]
      )
    end
  end

  defp hash(texto), do: :sha256 |> :crypto.hash(texto) |> Base.encode16(case: :lower)

  defp quantos_eventos do
    {:ok, %{rows: [[n]]}} = Api.Repo.query("SELECT count(*) FROM webhook_events", [])
    n
  end

  describe "em_lote_global/3" do
    test "drena TODOS os lotes, não só o primeiro" do
      semear_eventos("a", 5)
      assert quantos_eventos() >= 5

      # Com teto 2 e 5 linhas velhas são três voltas: 2, 2, 1. Se o laço parasse no primeiro
      # `DELETE` — que é o que uma recursão quebrada faz — sobrariam 3.
      apagados = Poda.em_lote_global("webhook_events", "inserted_at < now()", [])

      assert apagados >= 5
      assert quantos_eventos() == 0
    end
  end

  describe "por_clinica/1" do
    test "soma o que cada clínica devolveu" do
      clinica()
      clinica()

      total = Poda.por_clinica(fn _clinic_id -> 3 end)

      assert total >= 6
    end
  end
end
