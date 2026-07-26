defmodule Api.Notifications.RemindersTest do
  @moduledoc """
  Os lembretes por relógio (#51, doc 31 §3d): o resumo diário e o "sessão começando".

  As duas afirmações que importam aqui não são sobre o texto, e sim sobre **quando** e **para
  quem**:

    * a hora é local da clínica (ADR-009) — um cron em UTC serviria a hora errada;
    * o destinatário é o dono da coluna, e clínica sem vínculo profissional↔usuário não gera
      nada;
    * a janela do "sessão começando" **ladrilha** o tempo: um bloco cai em exatamente uma
      rodada, o que é o que substitui uma tabela de "já avisei".
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Accounts
  alias Api.Notifications
  alias Api.Notifications.DailyDigestJob
  alias Api.Notifications.SessionSoonJob
  alias Api.Scheduling

  defp email, do: "rem-#{System.unique_integer([:positive])}@example.com"

  # O profissional do fixture com um USUÁRIO vinculado — sem isso não há a quem avisar.
  defp dono_da_coluna(ctx) do
    user = Accounts.register_user!("Dono coluna", email(), authorize?: false)

    {:ok, m} =
      Accounts.invite_member(
        %{
          papel: :profissional,
          user_id: user.id,
          clinic_id: ctx.clinic.id,
          professional_id: ctx.prof.id
        },
        authorize?: false
      )

    {:ok, _} = Accounts.accept_invite(m, authorize?: false)
    user
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp kinds(user, clinic),
    do: Notifications.list_inbox(scope_for(user, clinic)).results |> Enum.map(& &1.kind)

  defp agenda(ctx, %DateTime{} = quando) do
    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: quando,
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: scope_for(ctx.owner, ctx.clinic)
      )

    appt
  end

  # A próxima segunda no fuso da clínica — dia de expediente no seed (seg–sex 08–12 / 13–18).
  defp proxima_segunda do
    hoje = Date.utc_today()
    Date.add(hoje, rem(8 - Date.day_of_week(hoje), 7) + 7)
  end

  describe "resumo diário (#51)" do
    test "conta os blocos de amanhã e avisa o dono da coluna" do
      ctx = clinica()
      prof_user = dono_da_coluna(ctx)

      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      amanha = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date() |> Date.add(1)

      {:ok, as_nove} = Scheduling.LocalTime.to_utc(amanha, "09:00", tz)
      {:ok, as_dez} = Scheduling.LocalTime.to_utc(amanha, "10:00", tz)

      agenda(ctx, as_nove)
      agenda(ctx, as_dez)

      assert {:ok, %{enviados: 1}} = perform_job(DailyDigestJob, %{"forcar" => true})

      assert :daily_digest in kinds(prof_user, ctx.clinic)

      assert [%{body: body}] =
               Notifications.list_inbox(scope_for(prof_user, ctx.clinic)).results
               |> Enum.filter(&(&1.kind == :daily_digest))

      assert body =~ "2 atendimentos"
    end

    test "dia vazio não gera resumo" do
      ctx = clinica()
      prof_user = dono_da_coluna(ctx)

      assert {:ok, %{enviados: 0}} = perform_job(DailyDigestJob, %{"forcar" => true})
      refute :daily_digest in kinds(prof_user, ctx.clinic)
    end

    # A hora é a LOCAL da clínica. Sem o recorte por fuso, o cron horário mandaria 24 resumos.
    test "fora da hora local configurada, não faz nada" do
      ctx = clinica()
      prof_user = dono_da_coluna(ctx)

      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      amanha = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date() |> Date.add(1)
      {:ok, as_nove} = Scheduling.LocalTime.to_utc(amanha, "09:00", tz)
      agenda(ctx, as_nove)

      hora_agora = Api.Notifications.Reminders.hora_local(tz)
      outra_hora = rem(hora_agora + 5, 24)

      assert {:ok, %{enviados: 0}} = perform_job(DailyDigestJob, %{"hora" => outra_hora})
      refute :daily_digest in kinds(prof_user, ctx.clinic)

      assert {:ok, %{enviados: 1}} = perform_job(DailyDigestJob, %{"hora" => hora_agora})
      assert :daily_digest in kinds(prof_user, ctx.clinic)
    end

    test "profissional sem usuário vinculado não gera nada" do
      ctx = clinica()

      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      amanha = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date() |> Date.add(1)
      {:ok, as_nove} = Scheduling.LocalTime.to_utc(amanha, "09:00", tz)
      agenda(ctx, as_nove)

      assert {:ok, %{enviados: 0}} = perform_job(DailyDigestJob, %{"forcar" => true})
    end

    # Bate-volta da Onda 4, e é a MESMA classe do CR-7 da Onda 3 (doc 43): o fan-out lia o caro
    # antes do barato. Aqui doeria mais, porque não é por clique — é por rodada de cron, em
    # **toda** clínica, para sempre. Medido no dev: 21 de 23 clínicas não têm profissional
    # vinculado a usuário (o caso comum da clínica pequena), e as 21 tinham a agenda lida assim
    # mesmo.
    test "clínica sem ninguém a quem avisar não chega a ler a agenda" do
      ctx = clinica()

      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      amanha = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date() |> Date.add(1)
      {:ok, as_nove} = Scheduling.LocalTime.to_utc(amanha, "09:00", tz)
      agenda(ctx, as_nove)

      {_, queries} =
        Api.QueryCounter.count(
          fn -> perform_job(DailyDigestJob, %{"forcar" => true}) end,
          "appointments"
        )

      assert queries == 0
    end
  end

  # Bate-volta da Onda 4. Estes dois testes guardam a **semântica de tique** dos crons de
  # lembrete: cada rodada serve uma janela de tempo própria e irrepetível.
  describe "os crons de lembrete são tiques, não tarefas" do
    # Havia `unique: [period: 300]` num cron que roda a cada 300s — margem zero. Sondado: a
    # dedupe do Oban conta jobs `:completed`, então bastava a rodada seguinte chegar uma fração
    # de segundo cedo para ela ser engolida como duplicata, **em silêncio**.
    test "duas rodadas seguidas não se dedupam" do
      {:ok, primeira} = SessionSoonJob.new(%{}) |> Oban.insert()
      {:ok, segunda} = SessionSoonJob.new(%{}) |> Oban.insert()

      refute segunda.conflict?, "a rodada seguinte do cron foi descartada como duplicata"
      refute primeira.id == segunda.id
    end

    # Retentativa num job de janela é pior que a falha: a janela é recalculada com o relógio da
    # RETENTATIVA, então ela cobre um intervalo diferente e sobreposto ao da próxima rodada — e o
    # profissional recebe o mesmo lembrete duas vezes. Uma rodada perdida é só uma rodada perdida.
    test "uma rodada que falha não é retentada" do
      assert SessionSoonJob.__opts__()[:max_attempts] == 1
      assert DailyDigestJob.__opts__()[:max_attempts] == 1
    end
  end

  describe "sessão começando (#51)" do
    test "avisa o bloco que cai na janela e diz a hora exata" do
      ctx = clinica()
      prof_user = dono_da_coluna(ctx)

      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      {:ok, as_nove} = Scheduling.LocalTime.to_utc(proxima_segunda(), "09:00", tz)
      agenda(ctx, as_nove)

      # 15 min antes das 09:00 → a janela [+15, +20) contém o bloco.
      agora = DateTime.add(as_nove, -15 * 60, :second)

      assert {:ok, %{enviados: 1}} =
               perform_job(SessionSoonJob, %{"agora" => DateTime.to_iso8601(agora)})

      assert [%{body: body}] =
               Notifications.list_inbox(scope_for(prof_user, ctx.clinic)).results
               |> Enum.filter(&(&1.kind == :session_soon))

      assert body =~ "09:00"
    end

    # O ponto do ladrilho: a rodada anterior e a seguinte não podem pegar o mesmo bloco, senão o
    # profissional recebe o mesmo aviso duas vezes — e não há tabela de "já avisei" para salvar.
    test "a janela ladrilha: a rodada vizinha não repete o mesmo bloco" do
      ctx = clinica()
      prof_user = dono_da_coluna(ctx)

      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      {:ok, as_nove} = Scheduling.LocalTime.to_utc(proxima_segunda(), "09:00", tz)
      agenda(ctx, as_nove)

      base = DateTime.add(as_nove, -15 * 60, :second)

      for passo <- [-5, 0, 5] do
        perform_job(SessionSoonJob, %{
          "agora" => base |> DateTime.add(passo * 60, :second) |> DateTime.to_iso8601()
        })
      end

      avisos =
        Notifications.list_inbox(scope_for(prof_user, ctx.clinic)).results
        |> Enum.count(&(&1.kind == :session_soon))

      assert avisos == 1
    end

    test "bloco cancelado não vira lembrete" do
      ctx = clinica()
      prof_user = dono_da_coluna(ctx)

      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      {:ok, as_nove} = Scheduling.LocalTime.to_utc(proxima_segunda(), "09:00", tz)
      appt = agenda(ctx, as_nove)

      {:ok, _} =
        Scheduling.transition_appointment(scope_for(ctx.owner, ctx.clinic), appt.id, :cancel)

      agora = DateTime.add(as_nove, -15 * 60, :second)

      assert {:ok, %{enviados: 0}} =
               perform_job(SessionSoonJob, %{"agora" => DateTime.to_iso8601(agora)})

      refute :session_soon in kinds(prof_user, ctx.clinic)
    end
  end
end
