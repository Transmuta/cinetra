defmodule Api.Scheduling.ParticipantPackageTest do
  @moduledoc """
  O vínculo **participante↔pacote** entrando junto com a presença (Frente 6/A2 etapa 2, doc 41;
  contrato [`09 §3.1.1` ponto 2]).

  Até aqui o `package_id` era carimbado **depois** (`Api.Packages.Sessions.stamp/3`: relê o bloco
  e chama `set_package`), o que deixa uma janela em que a presença existe sem pacote — e o dono do
  pacote nunca era validado, porque quem carimbava era código interno. Agora o `package_id` viaja
  na entrada de `:schedule`/`:add_participant`, na mesma escrita, e o servidor recusa (422) pacote
  que não seja do próprio paciente.
  """
  use Api.DataCase, async: false

  alias Api.Directory
  alias Api.Packages
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp setup_clinic,
    do: clinica(tipo: [nome: "Turma #{unico()}", icon: "Users", grupo: true, capacidade: 4])

  defp novo_paciente(ctx), do: paciente!(ctx, "Paciente #{unico()}")

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

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp agendar(ctx, attrs),
    do:
      Scheduling.schedule_appointment(
        Map.merge(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id
          },
          attrs
        ),
        scope: ctx.scope
      )

  defp presencas(ctx, appt_id) do
    Scheduling.list_attendances!(
      scope: ctx.scope,
      query: [filter: [appointment_id: appt_id]]
    )
  end

  defp presenca_de(ctx, appt_id, patient_id),
    do: Enum.find(presencas(ctx, appt_id), &(&1.patient_id == patient_id))

  describe "package_id na entrada" do
    test "criar o bloco já nasce com a presença carimbada" do
      ctx = setup_clinic()
      paciente = novo_paciente(ctx)
      pkg = pacote(ctx, paciente)

      assert {:ok, appt} = agendar(ctx, %{patient_ids: [paciente.id], package_id: pkg.id})

      assert presenca_de(ctx, appt.id, paciente.id).package_id == pkg.id
    end

    test "fundir numa turma existente carimba só a presença que entrou" do
      ctx = setup_clinic()
      p1 = novo_paciente(ctx)
      p2 = novo_paciente(ctx)
      pkg2 = pacote(ctx, p2)

      # p1 entra sem pacote (encaixe avulso/particular)
      {:ok, appt} = agendar(ctx, %{patient_ids: [p1.id]})
      # p2 entra pelo pacote — o caminho da materialização que cai numa turma existente
      assert {:ok, turma} = agendar(ctx, %{patient_ids: [p2.id], package_id: pkg2.id})
      assert turma.id == appt.id

      assert presenca_de(ctx, appt.id, p2.id).package_id == pkg2.id
      assert presenca_de(ctx, appt.id, p1.id).package_id == nil
    end

    test "sem package_id a presença nasce avulsa" do
      ctx = setup_clinic()
      paciente = novo_paciente(ctx)

      assert {:ok, appt} = agendar(ctx, %{patient_ids: [paciente.id]})
      assert presenca_de(ctx, appt.id, paciente.id).package_id == nil
    end
  end

  describe "o pacote tem de ser do próprio paciente (422)" do
    test "pacote de outro paciente é recusado e ninguém entra na turma" do
      ctx = setup_clinic()
      p1 = novo_paciente(ctx)
      p2 = novo_paciente(ctx)
      pkg1 = pacote(ctx, p1)

      assert {:error, %Ash.Error.Invalid{} = erro} =
               agendar(ctx, %{patient_ids: [p2.id], package_id: pkg1.id})

      assert erro_de_campo?(erro, :package_id)
      assert Scheduling.find_appointments!(scope: ctx.scope) == []
    end

    test "pacote inexistente é recusado" do
      ctx = setup_clinic()
      paciente = novo_paciente(ctx)

      assert {:error, %Ash.Error.Invalid{} = erro} =
               agendar(ctx, %{patient_ids: [paciente.id], package_id: Ash.UUID.generate()})

      assert erro_de_campo?(erro, :package_id)
    end

    test "pacote de outra clínica é recusado (não confirma sequer que existe)" do
      ctx = setup_clinic()
      outra = setup_clinic()
      paciente = novo_paciente(ctx)
      pkg_alheio = pacote(outra, novo_paciente(outra))

      assert {:error, %Ash.Error.Invalid{} = erro} =
               agendar(ctx, %{patient_ids: [paciente.id], package_id: pkg_alheio.id})

      assert erro_de_campo?(erro, :package_id)
    end

    test "pacote com mais de um participante é recusado (D11: pacote é por participante)" do
      ctx = setup_clinic()
      p1 = novo_paciente(ctx)
      p2 = novo_paciente(ctx)
      pkg1 = pacote(ctx, p1)

      assert {:error, %Ash.Error.Invalid{} = erro} =
               agendar(ctx, %{patient_ids: [p1.id, p2.id], package_id: pkg1.id})

      assert erro_de_campo?(erro, :package_id)
    end

    test "fundir numa turma com pacote alheio não altera a presença de quem já estava" do
      ctx = setup_clinic()
      p1 = novo_paciente(ctx)
      p2 = novo_paciente(ctx)
      pkg1 = pacote(ctx, p1)

      {:ok, appt} = agendar(ctx, %{patient_ids: [p1.id], package_id: pkg1.id})

      assert {:error, %Ash.Error.Invalid{}} =
               agendar(ctx, %{patient_ids: [p2.id], package_id: pkg1.id})

      assert presencas(ctx, appt.id) |> length() == 1
      assert presenca_de(ctx, appt.id, p1.id).package_id == pkg1.id
    end
  end

  describe "a materialização usa o mesmo caminho" do
    test "a série carimba o pacote sem passar por set_package" do
      ctx = setup_clinic()
      paciente = novo_paciente(ctx)
      pkg = ctx |> pacote(paciente) |> then(&Packages.get_patient_package!(ctx.scope, &1.id))

      tipo =
        Directory.get_appointment_type!(ctx.tipo.id, tenant: ctx.clinic.id, authorize?: false)

      assert {:ok, appt} =
               Packages.Sessions.create_and_stamp(pkg, tipo, at("08:00"), ctx.clinic.id, false)

      assert presenca_de(ctx, appt.id, paciente.id).package_id == pkg.id
    end
  end

  defp erro_de_campo?(%Ash.Error.Invalid{errors: errors}, campo),
    do: Enum.any?(errors, &(Map.get(&1, :field) == campo))
end
