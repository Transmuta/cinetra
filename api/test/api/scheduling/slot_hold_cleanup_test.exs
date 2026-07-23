defmodule Api.Scheduling.SlotHold.CleanupWorkerTest do
  @moduledoc """
  O backstop de limpeza dos holds vencidos (doc 09 §6.2, passo 3). Exercita `purge_expired/0`
  direto — o cron é config, não lógica. A RLS não é exercida no sandbox (`postgres`, BYPASSRLS);
  a iteração por-clínica com GUC é verificada por `psql`/bate-volta.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling
  alias Api.Scheduling.SlotHold.CleanupWorker
  alias Api.Waitlist

  @segunda ~D[2026-07-20]

  defp email, do: "cln-#{System.unique_integer([:positive])}@example.com"

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  test "apaga os holds vencidos e preserva os vivos" do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)

    prof1 = Directory.create_professional!("Dra. A", %{}, tenant: clinic.id, actor: owner)
    prof2 = Directory.create_professional!("Dr. B", %{}, tenant: clinic.id, actor: owner)
    p = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)

    scope_vivo = Api.Scope.with_membership(owner, membership)
    {:ok, entry} = Waitlist.enqueue_entry(scope_vivo, %{patient_id: p.id})

    # Hold VENCIDO: relógio cravado no passado → expires_at no passado.
    scope_velho = Api.Scope.with_membership(owner, membership, now: ~U[2020-01-01 00:00:00Z])

    {:ok, vencido} =
      Waitlist.offer_slot(scope_velho, entry, %{professional_id: prof1.id, starts_at: at("09:00")})

    # Hold VIVO: relógio real → expires_at = agora + 10 min.
    {:ok, vivo} =
      Waitlist.offer_slot(scope_vivo, entry, %{professional_id: prof2.id, starts_at: at("11:00")})

    assert CleanupWorker.purge_expired() == 1

    ids = Scheduling.list_slot_holds!(scope: scope_vivo) |> Enum.map(& &1.id)
    refute vencido.id in ids
    assert vivo.id in ids
  end

  # D-L: o worker varre TODAS as clínicas, e o custo disso era uma transação por clínica —
  # paga todo minuto, houvesse hold ou não. O lote resolveu; estes dois testes travam as duas
  # metades (varre todas × numa transação só), porque uma sem a outra é regressão silenciosa.
  describe "varredura de várias clínicas (D-L)" do
    test "apaga o vencido de cada clínica, e num número FIXO de transações" do
      clinicas = for _ <- 1..3, do: clinica_com_hold_vencido()

      {removidas, transacoes} =
        com_contagem_de_transacoes(fn -> CleanupWorker.purge_expired() end)

      assert removidas == 3

      # Uma transação (o lote) — não uma por clínica. O sandbox do Ecto abre a sua própria por
      # fora, então o que se mede é a variação: com 3 clínicas o número não pode acompanhar 3.
      assert transacoes <= 2,
             "#{transacoes} transações para 3 clínicas: o custo voltou a ser por clínica?"

      for %{scope: scope} <- clinicas do
        assert Scheduling.list_slot_holds!(scope: scope) == []
      end
    end
  end

  # Uma clínica completa com um hold JÁ VENCIDO — o relógio cravado no passado é o que faz
  # `expires_at` nascer velho, sem esperar os 10 minutos reais.
  defp clinica_com_hold_vencido do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)
    prof = Directory.create_professional!("Dra. A", %{}, tenant: clinic.id, actor: owner)
    p = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)

    scope = Api.Scope.with_membership(owner, membership)
    {:ok, entry} = Waitlist.enqueue_entry(scope, %{patient_id: p.id})

    velho = Api.Scope.with_membership(owner, membership, now: ~U[2020-01-01 00:00:00Z])

    {:ok, _hold} =
      Waitlist.offer_slot(velho, entry, %{professional_id: prof.id, starts_at: at("09:00")})

    %{scope: scope}
  end

  # Conta os `BEGIN` que o trecho dispara. O `Api.QueryCounter` filtra por tabela e uma
  # transação não tem tabela — aqui o que se mede é o próprio statement.
  defp com_contagem_de_transacoes(fun) do
    parent = self()
    ref = make_ref()

    handler = fn _event, _measure, %{query: query}, _config ->
      if String.starts_with?(String.downcase(query), "begin"), do: send(parent, {ref, :begin})
    end

    :telemetry.attach({__MODULE__, ref}, [:api, :repo, :query], handler, nil)
    resultado = fun.()
    :telemetry.detach({__MODULE__, ref})

    {resultado, drenar(ref, 0)}
  end

  defp drenar(ref, acc) do
    receive do
      {^ref, :begin} -> drenar(ref, acc + 1)
    after
      50 -> acc
    end
  end
end
