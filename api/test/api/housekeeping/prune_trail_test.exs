defmodule Api.Housekeeping.PruneTrailTest do
  @moduledoc """
  A poda da trilha (doc 43 §5f). A trilha é a tabela que mais cresce — medida em 15 MB contra
  5.256 kB da tabela base, com o único cron de poda removido em 2026-07-24 — e sem retenção ela
  cresce para sempre.

  O que se afirma aqui: a versão **velha** some, a **recente** fica, e a poda não atravessa
  clínica (a varredura é por tenant, sob a GUC).
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Housekeeping.PruneTrail
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp agenda(ctx, hhmm \\ "08:00") do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: dt,
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: ctx.scope
      )

    appt
  end

  # Envelhece as versões de um bloco na marra — a coluna é do próprio paper trail e não há ação
  # que a mova. É o equivalente a "esta trilha é de um ano atrás".
  defp envelhecer(appt_id, dias) do
    Api.Repo.query!(
      "UPDATE appointments_versions SET version_inserted_at = version_inserted_at - ($1 || ' days')::interval WHERE version_source_id = $2",
      [to_string(dias), Ecto.UUID.dump!(appt_id)]
    )
  end

  defp versoes(clinic_id, appt_id) do
    {:ok, %{rows: [[n]]}} =
      Api.Repo.query(
        "SELECT count(*) FROM appointments_versions WHERE clinic_id = $1 AND version_source_id = $2",
        [Ecto.UUID.dump!(clinic_id), Ecto.UUID.dump!(appt_id)]
      )

    n
  end

  describe "perform/1" do
    test "apaga a versão mais velha que a retenção e mantém a recente" do
      ctx = clinica()
      velho = agenda(ctx)
      novo = agenda(ctx, "09:00")

      assert versoes(ctx.clinic.id, velho.id) == 1
      envelhecer(velho.id, 400)

      assert {:ok, %{apagadas: apagadas}} = perform_job(PruneTrail, %{})
      assert apagadas >= 1

      assert versoes(ctx.clinic.id, velho.id) == 0
      assert versoes(ctx.clinic.id, novo.id) == 1
    end

    test "a retenção é parâmetro do job: 0 dia apaga tudo, o default não apaga nada recente" do
      ctx = clinica()
      appt = agenda(ctx)

      assert {:ok, %{apagadas: 0}} = perform_job(PruneTrail, %{})
      assert versoes(ctx.clinic.id, appt.id) == 1

      assert {:ok, %{apagadas: n}} = perform_job(PruneTrail, %{"reter_dias" => 0})
      assert n >= 1
      assert versoes(ctx.clinic.id, appt.id) == 0
    end

    test "poda a trilha de todas as clínicas, cada uma sob a própria GUC" do
      a = clinica()
      b = clinica()
      appt_a = agenda(a)
      appt_b = agenda(b)

      envelhecer(appt_a.id, 400)

      assert {:ok, _} = perform_job(PruneTrail, %{})

      assert versoes(a.clinic.id, appt_a.id) == 0
      assert versoes(b.clinic.id, appt_b.id) == 1

      envelhecer(appt_b.id, 400)
      assert {:ok, _} = perform_job(PruneTrail, %{})
      assert versoes(b.clinic.id, appt_b.id) == 0
    end
  end
end
