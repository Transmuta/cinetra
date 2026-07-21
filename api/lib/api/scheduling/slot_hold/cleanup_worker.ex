defmodule Api.Scheduling.SlotHold.CleanupWorker do
  @moduledoc """
  Backstop de limpeza dos `SlotHold` vencidos (doc 09 §6.2, passo 3) — um cron de 1 min que apaga
  os holds cuja `expires_at` já passou. **Só higiene**: a garantia contra a corrida é da exclusion
  constraint + do `DELETE` in-transaction da própria `SlotHold.offer` (que apaga os vencidos do
  profissional antes de inserir). Este worker cobre apenas os holds de profissionais que **ninguém
  tentou reservar** de novo — a correção nunca depende dele.

  ## Por que itera as clínicas

  `slot_holds` está sob RLS (ADR-018) e o Oban roda **sem tenant** (o servidor conecta como
  `movimento_app`, NOBYPASSRLS). Um `DELETE` global sem a GUC veria 0 linhas
  (`current_setting('movimento.clinic_id', true)` é NULL → nenhuma linha casa). Então o worker
  lista as clínicas (tabela global) e apaga por clínica dentro de `Api.Repo.with_clinic/2`, que
  seta a GUC — ficando dentro do modelo de RLS. O `now()` é o relógio do **banco** (housekeeping,
  não ADR-009), como a purga da `offer`.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    purge_expired()
    :ok
  end

  @doc "Apaga os holds vencidos de todas as clínicas. Devolve quantas linhas foram removidas."
  def purge_expired do
    Api.Accounts.list_clinics!(authorize?: false)
    |> Enum.reduce(0, fn clinic, total ->
      {:ok, %{num_rows: rows}} =
        Api.Repo.with_clinic(clinic.id, fn ->
          Api.Repo.query!("DELETE FROM slot_holds WHERE expires_at <= now()")
        end)

      total + rows
    end)
  end
end
