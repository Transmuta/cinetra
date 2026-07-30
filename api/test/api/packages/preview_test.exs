defmodule Api.Packages.PreviewTest do
  @moduledoc """
  A **prévia síncrona** da série (Fatia 3, o save-gate do `occIssue` do protótipo,
  [`:703`](../../../../interface/Movimento.dc.html#L703)): projeta a série e classifica cada
  ocorrência — fora do expediente, conflito, turma cheia, ou ok — **sem escrever nada**. É o que
  a tela mostra antes de confirmar (com ou sem "encaixe").

  Dois níveis: `classify/4` é puro e tem teste de mutação; `run/2` integra os carregadores reais
  (expediente das 4 camadas, feriados, agendamentos existentes) contra uma clínica de verdade.
  """
  use Api.DataCase, async: false

  alias Api.Packages.Preview
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp setup_clinic, do: clinica(tipo: [nome: "Pilates #{unico()}"])

  defp params(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        total: 4,
        data_inicio: @segunda,
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

  defp at(date, hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(date, hhmm, "America/Sao_Paulo")
    dt
  end

  # --- classify/4 puro ---

  describe "classify/4 (puro)" do
    @tipo_ind %{id: "t-ind", grupo: false, capacidade: nil}
    @tipo_grp %{id: "t-grp", grupo: true, capacidade: 3}

    defp occ(h_ini, h_fim, feriado? \\ false) do
      %{starts_at: at(@segunda, h_ini), ends_at: at(@segunda, h_fim), feriado?: feriado?}
    end

    test "feriado é informativo, não bloqueia" do
      assert Preview.classify(occ("08:00", "08:50", true), true, [], @tipo_ind) == :feriado
    end

    test "fora do expediente bloqueia" do
      assert Preview.classify(occ("08:00", "08:50"), false, [], @tipo_ind) == :fora_expediente
    end

    test "slot livre no expediente é ok" do
      assert Preview.classify(occ("08:00", "08:50"), true, [], @tipo_ind) == :ok
    end

    test "individual sobre bloco existente é conflito" do
      existente = %{
        starts_at: at(@segunda, "08:00"),
        ends_at: at(@segunda, "08:50"),
        status: :agendado,
        appointment_type_id: "outro",
        participantes: 1
      }

      assert Preview.classify(occ("08:30", "09:20"), true, [existente], @tipo_ind) == :conflito
    end

    test "cancelado não conflita (RN-13)" do
      cancelado = %{
        starts_at: at(@segunda, "08:00"),
        ends_at: at(@segunda, "08:50"),
        status: :cancelado,
        appointment_type_id: "outro",
        participantes: 1
      }

      assert Preview.classify(occ("08:00", "08:50"), true, [cancelado], @tipo_ind) == :ok
    end

    test "turma coincidente com vaga é join (não bloqueia)" do
      turma = %{
        starts_at: at(@segunda, "08:00"),
        ends_at: at(@segunda, "08:50"),
        status: :agendado,
        appointment_type_id: "t-grp",
        participantes: 2
      }

      assert Preview.classify(occ("08:00", "08:50"), true, [turma], @tipo_grp) == :join
    end

    test "turma coincidente cheia é :cheia" do
      turma = %{
        starts_at: at(@segunda, "08:00"),
        ends_at: at(@segunda, "08:50"),
        status: :agendado,
        appointment_type_id: "t-grp",
        participantes: 3
      }

      assert Preview.classify(occ("08:00", "08:50"), true, [turma], @tipo_grp) == :cheia
    end

    test "turma que sobrepõe mas NÃO coincide (horário diferente) é conflito" do
      turma = %{
        starts_at: at(@segunda, "08:30"),
        ends_at: at(@segunda, "09:20"),
        status: :agendado,
        appointment_type_id: "t-grp",
        participantes: 1
      }

      assert Preview.classify(occ("08:00", "08:50"), true, [turma], @tipo_grp) == :conflito
    end
  end

  # --- run/2 integração ---

  describe "run/2 (integração)" do
    test "série limpa: 4 ocorrências, todas ok, pode salvar" do
      ctx = setup_clinic()
      assert {:ok, resultado} = Preview.run(ctx.scope, params(ctx))

      assert length(resultado.ocorrencias) == 4
      assert Enum.all?(resultado.ocorrencias, &(&1.issue == :ok))
      assert resultado.bloqueios == 0
      assert resultado.pode_salvar? == true
    end

    test "feriado (exceção :fechado da clínica) pula, estende e não bloqueia" do
      ctx = setup_clinic()
      # 2026-07-22 é a segunda ocorrência (quarta). Fecha a clínica nesse dia.
      {:ok, _} =
        Scheduling.create_clinic_exception(ctx.scope, %{
          data: ~D[2026-07-22],
          nome: "Feriado",
          tipo: :fechado
        })

      assert {:ok, resultado} = Preview.run(ctx.scope, params(ctx))

      # 4 úteis + 1 feriado = 5 ocorrências
      assert length(resultado.ocorrencias) == 5
      feriado = Enum.find(resultado.ocorrencias, & &1.feriado?)
      assert feriado.data == ~D[2026-07-22]
      assert feriado.issue == :feriado
      # feriado não conta como bloqueio
      assert resultado.pode_salvar? == true
    end

    test "conflito com agendamento existente é sinalizado e bloqueia" do
      ctx = setup_clinic()
      # ocupa a primeira ocorrência (seg 08:00) com um bloco do mesmo profissional
      Ash.Seed.seed!(
        Api.Scheduling.Appointment,
        %{
          starts_at: at(@segunda, "08:00"),
          ends_at: at(@segunda, "08:50"),
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          status: :agendado,
          encaixe: false,
          version: 1,
          pkg_hold: false
        },
        tenant: ctx.clinic.id
      )

      assert {:ok, resultado} = Preview.run(ctx.scope, params(ctx))

      primeira = hd(resultado.ocorrencias)
      assert primeira.data == @segunda
      assert primeira.issue == :conflito
      assert resultado.bloqueios == 1
      assert resultado.pode_salvar? == false
    end

    test "grade fora do expediente (domingo) bloqueia todas" do
      ctx = setup_clinic()
      # dow 0 = domingo; a clínica abre seg–sáb
      p =
        params(ctx, %{
          grade: %{dows: [0], horarios: %{"0" => "10:00"}, professional_id: ctx.prof.id},
          total: 2
        })

      assert {:ok, resultado} = Preview.run(ctx.scope, p)
      assert Enum.all?(resultado.ocorrencias, &(&1.issue == :fora_expediente))
      assert resultado.pode_salvar? == false
    end

    test "grade inválida devolve o erro do motor, sem escrever" do
      ctx = setup_clinic()
      p = params(ctx, %{grade: %{dows: [], horarios: %{}, professional_id: ctx.prof.id}})
      assert {:error, :dows_vazio} = Preview.run(ctx.scope, p)
    end
  end
end
