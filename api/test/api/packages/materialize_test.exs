defmodule Api.Packages.MaterializeTest do
  @moduledoc """
  A materialização da série (Fatia 3, passo 4): `create_series/2` decide antes de escrever e
  enfileira `Api.Packages.Materializer`, que cria os N agendamentos reais e carimba `package_id`
  na presença (o vínculo que `usadas` conta).

  Oban roda em `testing: :manual`: os testes enfileiram e executam o job à mão
  (`Oban.Testing.perform_job/2`).
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Packages
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp setup_clinic, do: clinica(tipo: [nome: "Pilates #{unico()}"])

  defp params(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        nome: "Pilates 4",
        total: 4,
        falta_punitiva: true,
        cor: "#0FB5A6",
        data_inicio: @segunda,
        patient_id: ctx.paciente.id,
        appointment_type_id: ctx.tipo.id,
        grade: %{
          dows: [1, 3],
          horarios: %{"1" => "08:00", "3" => "09:00"},
          professional_id: ctx.prof.id
        }
      },
      attrs
    )
  end

  defp drain(ctx) do
    # Executa os jobs enfileirados da fila housekeeping, no contexto de tenant do teste.
    Oban.drain_queue(queue: :housekeeping)
    ctx
  end

  describe "create_series — o portão" do
    test "série limpa cria o pacote e enfileira a materialização" do
      ctx = setup_clinic()
      assert {:ok, pkg} = Packages.create_series(ctx.scope, params(ctx))
      assert pkg.status == :ativo

      assert_enqueued(worker: Api.Packages.Materializer, args: %{package_id: pkg.id})
    end

    test "grade fora do expediente é recusada de saída, sem criar pacote nem job" do
      ctx = setup_clinic()

      p =
        params(ctx, %{
          grade: %{dows: [0], horarios: %{"0" => "10:00"}, professional_id: ctx.prof.id},
          total: 2
        })

      assert {:error, {:fora_expediente, previa}} = Packages.create_series(ctx.scope, p)
      assert previa.bloqueios > 0
      refute_enqueued(worker: Api.Packages.Materializer)
      assert [] == Packages.list_packages!(scope: ctx.scope)
    end

    test "conflito sem forçar pede confirmação; com forçar cria" do
      ctx = setup_clinic()

      # ocupa a primeira ocorrência
      Ash.Seed.seed!(
        Api.Scheduling.Appointment,
        %{
          starts_at: at("08:00"),
          ends_at: at("08:50"),
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          status: :agendado,
          encaixe: false,
          version: 1,
          pkg_hold: false
        },
        tenant: ctx.clinic.id
      )

      assert {:error, {:precisa_confirmar, _}} = Packages.create_series(ctx.scope, params(ctx))
      refute_enqueued(worker: Api.Packages.Materializer)

      assert {:ok, _pkg} = Packages.create_series(ctx.scope, params(ctx), forcar: true)
      assert_enqueued(worker: Api.Packages.Materializer)
    end
  end

  describe "Materializer — a escrita" do
    test "materializa as 4 sessões, cada uma com a presença carimbada com o pacote" do
      ctx = setup_clinic()
      {:ok, pkg} = Packages.create_series(ctx.scope, params(ctx))

      drain(ctx)

      # 4 agendamentos criados no profissional
      appts =
        Scheduling.list_appointments!(at("00:00"), at_date(~D[2026-08-30], "00:00"),
          scope: ctx.scope
        )

      assert length(appts) == 4

      # cada presença carimbada com o package_id; usadas ainda 0 (todas :prevista)
      pkg = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:usadas, :restantes])
      atts = Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [package_id: pkg.id]])
      assert length(atts) == 4
      assert pkg.usadas == 0
      assert pkg.restantes == 4
    end

    test "feriado pula: a série entrega 4 úteis estendendo o calendário" do
      ctx = setup_clinic()

      {:ok, _} =
        Scheduling.create_clinic_exception(ctx.scope, %{
          data: ~D[2026-07-22],
          nome: "Feriado",
          tipo: :fechado
        })

      {:ok, pkg} = Packages.create_series(ctx.scope, params(ctx))
      drain(ctx)

      atts = Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [package_id: pkg.id]])
      # 4 sessões úteis (o feriado não virou sessão)
      assert length(atts) == 4
      # nenhuma delas cai no feriado
      datas =
        Scheduling.list_appointments!(at("00:00"), at_date(~D[2026-08-30], "00:00"),
          scope: ctx.scope
        )
        |> Enum.map(&Scheduling.LocalTime.to_local_date(&1.starts_at, "America/Sao_Paulo"))

      refute ~D[2026-07-22] in datas
    end

    test "re-executar o job é idempotente — não duplica sessões" do
      ctx = setup_clinic()
      {:ok, pkg} = Packages.create_series(ctx.scope, params(ctx))

      drain(ctx)

      antes =
        Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [package_id: pkg.id]])
        |> length()

      # roda o mesmo job de novo, à mão
      assert :ok =
               perform_job(Api.Packages.Materializer, %{
                 package_id: pkg.id,
                 clinic_id: ctx.clinic.id,
                 forcar: false
               })

      depois =
        Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [package_id: pkg.id]])
        |> length()

      assert antes == 4
      assert depois == 4
    end

    test "forçar materializa o conflito como encaixe" do
      ctx = setup_clinic()

      Ash.Seed.seed!(
        Api.Scheduling.Appointment,
        %{
          starts_at: at("08:00"),
          ends_at: at("08:50"),
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          status: :agendado,
          encaixe: false,
          version: 1,
          pkg_hold: false
        },
        tenant: ctx.clinic.id
      )

      {:ok, pkg} = Packages.create_series(ctx.scope, params(ctx), forcar: true)
      drain(ctx)

      # as 4 sessões do pacote entram; a que conflita nasce encaixe
      atts = Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [package_id: pkg.id]])
      assert length(atts) == 4

      encaixe? =
        Scheduling.list_appointments!(at("08:00"), at("09:00"), scope: ctx.scope)
        |> Enum.any?(& &1.encaixe)

      assert encaixe?
    end
  end

  describe "orçamento de queries (B4)" do
    @describetag :b4

    # O invariante da série — clínica, expediente do profissional na janela, tipo de atendimento,
    # paciente, dono do pacote — é o MESMO para as N sessões. Sem `Api.Scheduling.Warm` cada sessão
    # o relia: é o achado B4 da análise arquitetural (doc 101 §4.5), o mesmo defeito que o doc 43
    # §5a mediu na massa e que o `Warm` resolvia lá — e só lá.
    #
    # **A asserção é invariância em N, não um teto.** Um teto seria um número escolhido a dedo, que
    # envelhece e se afrouxa sozinho no primeiro PR que o esbarra. Comparar duas séries de tamanhos
    # diferentes pergunta exatamente o que importa: esta leitura cresce com o tamanho do lote? O que
    # cresce legitimamente (as escritas) fica de fora da lista, e a asserção de `appointments`
    # abaixo é o controle positivo — sem ela, um caminho que não materializasse nada passaria com
    # zero leitura em tudo.
    @invariante ~w(clinics appointment_types professionals clinic_hours professional_hours
                   schedule_exceptions patients packages package_schedules)

    test "o custo do invariante não cresce com o tamanho da série" do
      quatro = materializar_e_contar(4)
      dez = materializar_e_contar(10)

      assert quatro["appointments"] == 4
      assert dez["appointments"] == 10

      for tabela <- @invariante do
        assert Map.get(dez, tabela, 0) == Map.get(quatro, tabela, 0),
               "#{tabela}: #{Map.get(quatro, tabela, 0)} leituras numa série de 4 e " <>
                 "#{Map.get(dez, tabela, 0)} numa de 10 — está sendo relido por sessão.\n" <>
                 "  4  → #{inspect(Enum.sort(quatro))}\n" <>
                 "  10 → #{inspect(Enum.sort(dez))}"
      end
    end

    # Clínica nova a cada chamada: o `Api.Accounts.ClinicTimezone` guarda o fuso por clínica em
    # `:persistent_term`, então reusar a mesma faria a segunda medição nascer com cache quente e a
    # comparação mediria o cache, não o warm.
    defp materializar_e_contar(total) do
      ctx = setup_clinic()
      {:ok, _pkg} = Packages.create_series(ctx.scope, params(ctx, %{total: total}))

      {_, por_tabela} = Api.QueryCounter.tally(fn -> drain(ctx) end)
      por_tabela
    end
  end

  defp at(hhmm), do: at_date(@segunda, hhmm)

  defp at_date(date, hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(date, hhmm, "America/Sao_Paulo")
    dt
  end
end
