defmodule Api.Audit.FeedQueriesTest do
  @moduledoc """
  O teto de queries do feed (bate-volta, causa C6).

  Duas regras que o bate-volta mediu e que nada travava:

    * o feed lê `audit_events` **uma vez por página**, não duas. A segunda era o `COUNT(*)` do
      `count: true` — medido em **265×** o custo da própria página (23,9 ms · 191 buffers contra
      0,090 ms · 9 buffers, num recorte de 84 mil linhas);
    * o **enriquecimento** (resolver paciente e profissional por nome) é feito em LOTE: duas
      leituras por página, independentemente do tamanho dela. Se algum dia virar uma leitura por
      entrada, é N+1 na tabela que mais cresce — que é o que o doc 25 §11.4 já proibia.
  """
  use Api.DataCase, async: false

  alias Api.Audit
  alias Api.QueryCounter

  defp com_eventos(ctx, n) do
    for i <- 1..n do
      {:ok, _} =
        Api.Records.update_patient(ctx.paciente, %{genero: "G#{i}"}, scope: ctx.scope)
    end
  end

  test "uma página custa UMA leitura de audit_events, não duas" do
    ctx = clinica(paciente: "Caio")
    com_eventos(ctx, 3)

    {_, n} = QueryCounter.count(fn -> Audit.list_events(ctx.scope) end, "audit_events")

    assert n == 1,
           "o feed leu audit_events #{n}x — a segunda leitura é o COUNT(*), que custa 265x a página"
  end

  test "o enriquecimento é em lote: o custo não cresce com o tamanho da página" do
    ctx = clinica(paciente: "Caio")
    com_eventos(ctx, 10)

    {_, pequena} = QueryCounter.tally(fn -> Audit.list_events(ctx.scope, limit: 2) end)
    {_, grande} = QueryCounter.tally(fn -> Audit.list_events(ctx.scope, limit: 200) end)

    assert pequena["patients"] == grande["patients"]
    assert pequena["professionals"] == grande["professionals"]
  end

  # O contexto da agenda (de quem era a sessão, com qual profissional) custa mais DUAS leituras,
  # e elas seguem a mesma regra: uma por página, não uma por entrada. Numa página de 50 linhas de
  # agenda a diferença entre lote e N+1 é 2 contra 100 queries — na tabela que mais cresce.
  test "o contexto da agenda também é em lote" do
    ctx = clinica(prof: "Dra. Bea", paciente: "Caio")

    for hora <- ["08:00", "09:00", "10:00", "11:00"] do
      {:ok, dt} = Api.Scheduling.LocalTime.to_utc(~D[2026-07-20], hora, "America/Sao_Paulo")

      {:ok, _} =
        Api.Scheduling.schedule_appointment(
          %{
            starts_at: dt,
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )
    end

    {_, tally} = QueryCounter.tally(fn -> Audit.list_events(ctx.scope, limit: 200) end)

    # Quatro blocos numa página só: em lote são duas leituras, uma de cada tabela. Fosse uma por
    # entrada, seriam oito — e cresceriam com a página.
    assert tally["appointments"] == 1
    assert tally["attendances"] == 1
  end
end
