defmodule Api.Packages.PackageScheduleTest do
  @moduledoc """
  A **unicidade da grade** (Onda 1 da auditoria de banco, doc 92 P1-2).

  `Package` declara `has_one :schedule`, e o domínio inteiro lê a grade como se fosse uma só:
  `adjust_grade/3` carrega `[:schedule]`, decide sobre `pkg.schedule` e reescreve **aquela**
  linha. Com duas grades no banco, `has_one` devolve uma arbitrária — e a grade é o que decide
  para onde as sessões futuras do pacote são reprojetadas. Ou seja: o dano não é uma linha a
  mais, é a série cair no dia/horário/profissional errado, sem erro nenhum no caminho.

  O índice que existia era `package_schedules_clinic_id_package_id_index`, um `CREATE INDEX`
  comum. Índice não-único não é invariante: ele acelera a leitura e aceita a duplicata.

  ## Por que o teste ataca pelo `Ash.Seed`, e não pela ação

  Porque **não há caminho de ação** que crie a segunda grade: `PackageSchedule.:create` aceita
  só `[:dows, :horarios, :professional_id]`, e o `package_id` chega pelo `manage_relationship`
  da criação do pacote. A invariante, hoje, só pode ser quebrada por fora do Ash — `Ash.Seed`,
  script, `psql`, ou um caminho de escrita futuro que ainda não existe.

  É exatamente por isso que ela precisa morar **no banco**, e não numa validação: é a mesma
  razão do teto de `total` em `Api.Packages.PackageTest` ("o teto vale no banco também, não só
  na fronteira do Ash"). A `identity` acompanha para que o dia em que esse caminho existir o
  Ash devolva 422 em vez de estado ambíguo.
  """
  use Api.DataCase, async: false

  alias Api.Packages

  @segunda ~D[2026-07-20]

  defp pacote_com_grade do
    ctx = clinica(tipo: [nome: "Pilates #{unico()}"])

    {:ok, pkg} =
      Packages.create_package(
        %{
          nome: "Pilates 10",
          total: 10,
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
        scope: ctx.scope
      )

    {ctx, pkg}
  end

  describe "unicidade da grade" do
    # A camada que decide: o `INSERT` cru, sem Ash no caminho. É o mesmo desenho de
    # `PackageTest`, "o teto vale no banco também" — se a invariante só existisse no recurso,
    # `psql`, script e migration continuariam podendo criar a segunda grade.
    test "o banco recusa uma segunda grade para o mesmo pacote" do
      {ctx, pkg} = pacote_com_grade()

      assert_raise Postgrex.Error, ~r/package_schedules_one_schedule_per_package_index/, fn ->
        Api.Repo.query!(
          "INSERT INTO package_schedules (id, clinic_id, package_id, professional_id, dows, " <>
            "horarios, inserted_at, updated_at) VALUES ($1, $2, $3, $4, '{5}', " <>
            "'{\"5\": \"14:00\"}', now(), now())",
          [
            Ecto.UUID.dump!(Ash.UUID.generate()),
            Ecto.UUID.dump!(ctx.clinic.id),
            Ecto.UUID.dump!(pkg.id),
            Ecto.UUID.dump!(ctx.prof.id)
          ]
        )
      end
    end

    # A outra metade do P1-2: o `pre_check?` da identity. Sem ele, o `unique_violation` sob RLS
    # chega sem DETAIL e o Ash levanta `KeyError` — 500 em vez de 422 (a lição que
    # `WaitlistEntry` e `AppointmentType` já carregam no comentário).
    test "pelo Ash o erro é de validação com a mensagem da identity, não um 500" do
      {ctx, pkg} = pacote_com_grade()

      erro =
        assert_raise Ash.Error.Invalid, fn ->
          Ash.Seed.seed!(
            Api.Packages.PackageSchedule,
            %{
              package_id: pkg.id,
              professional_id: ctx.prof.id,
              dows: [5],
              horarios: %{"5" => "14:00"}
            },
            tenant: ctx.clinic.id
          )
        end

      assert Enum.any?(erro.errors, &(Map.get(&1, :message) =~ "já tem uma grade"))
    end

    # O par do teste acima: a constraint tem de barrar a DUPLICATA, não a grade de outro pacote.
    # Sem esta metade, um índice único errado (por exemplo sobre `clinic_id` sozinho) passaria no
    # teste de cima e quebraria a clínica inteira no segundo pacote.
    test "duas grades de pacotes diferentes na mesma clínica continuam valendo" do
      {ctx, _pkg} = pacote_com_grade()

      assert {:ok, outro} =
               Packages.create_package(
                 %{
                   nome: "Pilates 20",
                   total: 20,
                   falta_punitiva: true,
                   cor: "#0FB5A6",
                   data_inicio: @segunda,
                   patient_id: ctx.paciente.id,
                   appointment_type_id: ctx.tipo.id,
                   grade: %{
                     dows: [2],
                     horarios: %{"2" => "10:00"},
                     professional_id: ctx.prof.id
                   }
                 },
                 scope: ctx.scope
               )

      outro = Packages.get_package!(outro.id, scope: ctx.scope, load: [:schedule])
      assert outro.schedule.dows == [2]
    end

    # A grade continua editável pela porta normal — `adjust_grade` reescreve a linha existente,
    # e um índice único mal declarado (sem o recorte certo) transformaria o UPDATE em conflito.
    test "trocar a grade do pacote continua funcionando" do
      {ctx, pkg} = pacote_com_grade()

      assert {:ok, _} =
               Packages.adjust_grade(ctx.scope, pkg.id, %{
                 dows: [2, 4],
                 horarios: %{"2" => "07:00", "4" => "07:00"},
                 professional_id: ctx.prof.id
               })

      pkg = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:schedule])
      assert pkg.schedule.dows == [2, 4]
    end
  end
end
