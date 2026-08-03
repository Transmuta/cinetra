defmodule Api.Scheduling.FutureConflictsRecorteTest do
  @moduledoc """
  **M1 (doc 101)** — a análise de impacto lê **só o que a mudança pode alcançar**.

  `Api.Scheduling.future_conflicts/2` roda dentro da transação que escreve o expediente (é o gate
  A3/D12, e ele é assim de propósito: entre analisar e gravar cabe um agendamento novo). O que ele
  não podia continuar fazendo era varrer a agenda futura **inteira** da clínica para, logo depois,
  descartar quase tudo em Elixir no `afetado_por?/2`.

  Medido antes do conserto, numa clínica com 10.000 blocos futuros, para uma **folga de um
  profissional num único dia** — a mudança mais recortável que existe:

      future_conflicts inteiro : 372,0 ms
      soma do tempo em SQL     : 106,0 ms  (40 consultas a appointments)
      resto (BEAM)             : 266,0 ms

  Os 40 são o `stream?` paginando de 250 em 250; os 266 ms são montar struct de bloco que o
  filtro seguinte jogaria fora. O plano da consulta estava **certo** (Index Scan em
  `appointments_clinic_id_starts_at_index`, 0,2 ms por página) — o problema era o volume pedido,
  não o caminho.

  Este teste prende as duas metades:

    * o **recorte declarado** pelo motor puro (`ImpactAnalysis.recorte/1`), incluindo as formas
      que chegam da fronteira HTTP como string;
    * o **efeito na leitura**, contando as consultas a `appointments` numa clínica com mais
      blocos futuros do que cabe numa página do `stream`.

  E prende o que não pode mudar: os conflitos encontrados continuam os mesmos.
  """
  use Api.DataCase, async: false

  alias Api.QueryCounter
  alias Api.Scheduling
  alias Api.Scheduling.ImpactAnalysis

  describe "ImpactAnalysis.recorte/1" do
    test "exceção do profissional recorta pelas duas dimensões" do
      assert %{date: ~D[2027-03-15], professional_id: "p1"} =
               ImpactAnalysis.recorte({:professional_exception, "p1", %{data: ~D[2027-03-15]}})
    end

    test "exceção da clínica recorta pelo dia, e por ninguém mais (vale para todos)" do
      assert %{date: ~D[2027-03-15], professional_id: nil} =
               ImpactAnalysis.recorte({:clinic_exception, %{data: ~D[2027-03-15]}})
    end

    test "grade do profissional recorta pela coluna; o dia-da-semana não vira SQL" do
      assert %{date: nil, professional_id: "p1"} =
               ImpactAnalysis.recorte({:professional_hours, "p1", [%{dow: 1}]})
    end

    test "semana da clínica não recorta nada — alcança o futuro inteiro" do
      assert %{date: nil, professional_id: nil} =
               ImpactAnalysis.recorte({:clinic_hours, %{1 => []}})
    end

    # A mesma armadilha do doc 49: da fronteira HTTP tudo chega como string. Se o recorte não
    # normalizasse igual ao `afetado_por?/2`, ele filtraria por uma data que o motor não reconhece
    # — e aí a leitura traria menos do que a simulação precisa, que é o modo de falha CARO (some
    # conflito real, o feriado entra por cima da agenda).
    test "a data vem como string da fronteira, e é normalizada igual" do
      assert %{date: ~D[2027-03-15]} =
               ImpactAnalysis.recorte(
                 {:clinic_exception, %{"data" => "2027-03-15", "tipo" => "fechado"}}
               )
    end

    test "data malformada não recorta — quem se abstém é o motor, não a leitura" do
      assert %{date: nil} = ImpactAnalysis.recorte({:clinic_exception, %{"data" => "não é data"}})
      assert %{date: nil} = ImpactAnalysis.recorte({:clinic_exception, %{}})
    end
  end

  describe "a leitura recorta no banco (M1)" do
    setup do
      ctx = clinica()
      outro = profissional!(ctx, "Dr. Outro")

      # Mais blocos futuros do que cabe numa página do `stream?` (250): sem o recorte, a leitura
      # da análise pagina duas vezes. É esse o sinal que o teste prende — contar linha a linha
      # exigiria instrumentar o repo; contar IDA AO BANCO basta e é o que dói.
      blocos = insere_blocos(ctx, [ctx.prof, outro], 15)

      %{ctx: ctx, outro: outro, blocos: blocos}
    end

    test "folga de um profissional num dia: uma consulta a appointments, não a agenda inteira",
         %{ctx: ctx} do
      dia = Date.add(dia_util_base(ctx), 3)

      {analise, consultas} =
        QueryCounter.count(
          fn ->
            Scheduling.future_conflicts(
              ctx.scope,
              {:professional_exception, ctx.prof.id, %{data: dia, tipo: :fechado, periods: []}}
            )
          end,
          "appointments"
        )

      assert consultas == 1,
             "a análise de UM dia de UM profissional fez #{consultas} consultas a `appointments` " <>
               "— ela está varrendo a agenda futura inteira da clínica (doc 101, M1)"

      # E continua achando o que tem de achar: os blocos daquele profissional naquele dia. São 9
      # dos 10 horários: o das 12:00 cai no almoço do expediente semeado (08–12 e 13–18), então
      # ele já não cabia ANTES da folga — e o gate só acusa quem cabia e deixa de caber.
      assert analise.total == 9
      assert Enum.all?(analise.conflicts, &(&1.professional_id == ctx.prof.id))
      assert Enum.all?(analise.conflicts, &(&1.date == dia))
    end

    test "feriado da clínica: uma consulta, e pega os DOIS profissionais do dia", %{ctx: ctx} do
      dia = Date.add(dia_util_base(ctx), 3)

      {analise, consultas} =
        QueryCounter.count(
          fn ->
            Scheduling.future_conflicts(
              ctx.scope,
              {:clinic_exception, %{data: dia, tipo: :fechado, periods: []}}
            )
          end,
          "appointments"
        )

      assert consultas == 1
      # Os mesmos 9 horários, agora nas duas colunas: o feriado da clínica vale para todos.
      assert analise.total == 18
    end

    # O contraexemplo, e ele é parte do contrato: a semana da clínica alcança um conjunto de
    # dias-da-semana espalhado pelo futuro inteiro. Recortá-lo exigiria converter fuso dentro do
    # SQL. Este teste existe para a decisão ficar visível — não para celebrar a varredura.
    test "semana da clínica continua lendo tudo (e é decisão, não esquecimento)", %{ctx: ctx} do
      {_analise, consultas} =
        QueryCounter.count(
          fn ->
            Scheduling.future_conflicts(ctx.scope, {:clinic_hours, %{1 => [["08:00", "12:00"]]}})
          end,
          "appointments"
        )

      assert consultas > 1
    end
  end

  # 10 blocos por dia por profissional, em `dias` dias úteis seguidos, escritos direto no banco:
  # a fábrica de agendamento passa pelo domínio inteiro (validação de expediente, exclusion
  # constraint, notifier) e 300 deles levariam minutos. O que este teste precisa é de VOLUME, não
  # de blocos com história.
  defp insere_blocos(ctx, profs, dias) do
    base = dia_util_base(ctx)

    linhas =
      for p <- profs, d <- 0..(dias - 1), h <- 8..17 do
        dia = Date.add(base, d)
        {:ok, inicio} = Scheduling.LocalTime.to_utc(dia, hora(h), ctx.clinic.timezone)

        [
          DateTime.to_naive(inicio),
          NaiveDateTime.add(DateTime.to_naive(inicio), 50 * 60),
          ctx.clinic.id,
          p.id,
          ctx.tipo.id
        ]
      end

    {vs, ps} =
      linhas
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {[ini, fim, cid, pid, tid], i}, {vs, ps} ->
        b = i * 5

        {vs ++ ["($#{b + 1},$#{b + 2},$#{b + 3}::uuid,$#{b + 4}::uuid,$#{b + 5}::uuid)"],
         ps ++ [ini, fim, Ecto.UUID.dump!(cid), Ecto.UUID.dump!(pid), Ecto.UUID.dump!(tid)]}
      end)

    {:ok, %{num_rows: n}} =
      Api.Repo.query(
        "INSERT INTO appointments (starts_at, ends_at, clinic_id, professional_id, appointment_type_id) " <>
          "VALUES " <> Enum.join(vs, ","),
        ps
      )

    n
  end

  defp hora(h), do: String.pad_leading(Integer.to_string(h), 2, "0") <> ":00"

  # Todos os dias do bloco precisam ser dias em que a clínica ABRE (o seed do onboard abre
  # seg–sex): um bloco no sábado já não cabia antes da mudança e, por definição, não é conflito.
  # Começar numa segunda garante 5 dias úteis seguidos nos 15 do teste.
  defp dia_util_base(ctx) do
    hoje = DateTime.to_date(DateTime.shift_zone!(DateTime.utc_now(), ctx.clinic.timezone))
    proxima_segunda(Date.add(hoje, 1))
  end

  defp proxima_segunda(data) do
    if Date.day_of_week(data) == 1, do: data, else: proxima_segunda(Date.add(data, 1))
  end
end
