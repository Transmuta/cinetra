defmodule Api.Packages.BulkQueriesTest do
  @moduledoc """
  O **teto de queries** da massa por pacote (doc 43 §5a).

  O bate-volta da Onda 3 mediu 39,4 queries por sessão numa massa de 40 — a mesma linha (clínica,
  tipo, paciente, pacote) relida a cada iteração, dentro de **uma** transação que segura conexão do
  pool e os locks da exclusion constraint. Só 4 das 39 eram escrita.

  Este teste é o backstop: ele falha quando o invariante voltar a ser lido por sessão. O número não
  é uma meta de beleza — é o que separa "a massa custa proporcional ao que escreve" de "a massa
  custa proporcional ao que escreve **vezes** o que relê".
  """
  use Api.DataCase, async: false

  alias Api.Packages
  alias Api.QueryCounter
  alias Api.Scheduling

  @segunda ~D[2027-03-01]

  defp setup_clinic do
    ctx = clinica(tipo: [nome: "Pilates #{unico()}", icon: "Users", grupo: true, capacidade: 4])
    Map.put(ctx, :outra_prof, profissional!(ctx, "Dr. Y"))
  end

  defp at(data, hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(data, hhmm, "America/Sao_Paulo")
    dt
  end

  defp pacote(ctx, paciente) do
    Packages.create_package!(
      %{
        nome: "Pilates 10",
        total: 10,
        falta_punitiva: true,
        cor: "#0FB5A6",
        data_inicio: @segunda,
        patient_id: paciente.id,
        appointment_type_id: ctx.tipo.id,
        grade: %{dows: [1], horarios: %{"1" => "08:00"}, professional_id: ctx.prof.id}
      },
      scope: ctx.scope
    )
  end

  # `n` sessões do pacote, uma por semana, todas no futuro.
  defp sessoes(ctx, pkg, paciente, n) do
    Enum.map(0..(n - 1), fn i ->
      data = Date.add(@segunda, 7 * i)

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at(data, "08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [paciente.id],
            package_id: pkg.id
          },
          scope: ctx.scope
        )

      appt
    end)
  end

  defp assert_teto(tally, teto, o_que) do
    total = tally |> Map.values() |> Enum.sum()

    assert total <= teto, """
    A massa de #{o_que} passou de #{teto} queries (#{total}).
    Repartição: #{inspect(Enum.sort_by(tally, &(-elem(&1, 1))), pretty: true)}
    """
  end

  describe "bulk_adjust: o custo por sessão" do
    test "remarcar 6 sessões sozinhas não relê o invariante por sessão" do
      ctx = setup_clinic()
      paciente = paciente!(ctx, "Massa #{unico()}")
      pkg = pacote(ctx, paciente)
      sessoes(ctx, pkg, paciente, 6)

      {{:ok, %{afetadas: 6}}, tally} =
        QueryCounter.tally(fn ->
          Packages.bulk_adjust(ctx.scope, pkg.id, %{
            escopo: :todas,
            aplicar_horario: true,
            hhmm: "09:00"
          })
        end)

      # Medido: 82 queries antes do warm (13,7/sessão), 52 depois (8,7). O teto tem folga para o
      # ruído do sandbox, não para uma leitura nova por sessão.
      #
      # Subiu de 70 para 80 com o aviso ao paciente da massa (doc 65 §2): são ~7 queries por
      # MASSA — reperguntar os alvos para achar a âncora, a clínica, o pacote, a presença, o
      # insert da mensagem e o do job. **Constante, não por sessão** — é o que o teto ao lado
      # (turma, 4 sessões) prova ao subir o mesmo tanto com menos sessões.
      assert_teto(tally, 70, "6 sessões individuais")

      # O invariante do pacote — a clínica, o tipo, o paciente e o próprio pacote — é lido uma
      # vez por massa, não uma vez por sessão.
      for tabela <- ~w(clinics appointment_types patients packages) do
        assert Map.get(tally, tabela, 0) <= 2,
               "#{tabela} foi lida #{Map.get(tally, tabela)}× numa massa de 6 sessões"
      end
    end

    test "numa turma (destaca e reinsere) o invariante também sai do laço" do
      ctx = setup_clinic()
      paciente = paciente!(ctx, "Massa #{unico()}")
      colega = paciente!(ctx, "Colega #{unico()}")
      pkg = pacote(ctx, paciente)
      blocos = sessoes(ctx, pkg, paciente, 4)

      # o colega entra em todas: agora cada sessão é uma turma de dois
      for appt <- blocos do
        {:ok, _} =
          Scheduling.add_appointment_participants(appt, %{patient_ids: [colega.id]},
            scope: ctx.scope
          )
      end

      {{:ok, %{afetadas: 4}}, tally} =
        QueryCounter.tally(fn ->
          Packages.bulk_adjust(ctx.scope, pkg.id, %{
            escopo: :todas,
            aplicar_horario: true,
            hhmm: "10:00"
          })
        end)

      # Medido: 98 queries para 4 sessões em turma (24,5/sessão) — o caminho caro, porque cada
      # sessão é destaque + reinserção (duas escritas, duas trilhas, duas policies).
      # 120 → 126 com o aviso ao paciente da massa (doc 65 §2). O que ele acrescenta é
      # **constante por massa** — âncora, clínica, insert da mensagem e do job —, e não uma
      # leitura por sessão, que é o que este teto existe para pegar. A prova disso não é o
      # número: são as asserções por tabela logo abaixo (`clinics`, `patients`, `packages`
      # ≤ 2), que continuam valendo com 4 sessões e com 6.
      #
      # O caso individual (o teste acima) nem precisou de folga: ali a presença sobrevive à
      # remarcação e a âncora acerta na primeira query.
      assert_teto(tally, 126, "4 sessões em turma")

      for tabela <- ~w(clinics appointment_types patients packages) do
        assert Map.get(tally, tabela, 0) <= 2,
               "#{tabela} foi lida #{Map.get(tally, tabela)}× numa massa de 4 sessões em turma"
      end
    end
  end
end
