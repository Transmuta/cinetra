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
  lista as clínicas (tabela global) e apaga por clínica com a GUC setada — ficando dentro do
  modelo de RLS. O `now()` é o relógio do **banco** (housekeeping, não ADR-009), como a purga da
  `offer`.

  ## D-L: o que foi feito, e o que foi recusado

  O achado era "O(clínicas) **transações** por minuto, independente de carga". O caminho que o
  doc 30 sugeria — *statement único com conexão privilegiada* — foi **recusado**: um `DELETE`
  global só existe para quem bypassa RLS, e abrir no app um pool (ou uma função `SECURITY
  DEFINER`) que enxerga todas as clínicas troca um custo desprezível por um furo permanente no
  isolamento de tenant. O ADR-018 existe justamente para não ter esse caminho.

  O que sobra, e foi feito:

    * **uma transação por lote**, não por clínica. A GUC é `set_config(..., is_local: true)`, que
      vale até o fim da transação e pode ser **re-setada** dentro dela — então N clínicas cabem
      numa transação só, com N `DELETE`s. O lote é limitado (`@lote`) porque o inverso também é
      verdade: uma transação única para milhares de clínicas seguraria locks e snapshot por
      tempo demais;
    * **só os ids** — `list_clinics!` trazia a linha inteira de cada clínica por minuto para usar
      um campo;
    * **cron de 5 em 5 minutos**, não de 1 em 1 (`config/config.exs`). Este worker é backstop
      puro: a corrida é resolvida pela exclusion constraint, e o hold que atrapalharia já é
      apagado pela própria `offer` antes de inserir. Rodar 5× menos não muda garantia nenhuma —
      muda só quanto tempo uma linha morta fica numa tabela quase vazia.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Ash.Query

  # Clínicas por transação. Alto o bastante para o custo por-transação sumir, baixo o bastante
  # para a transação não virar um lock longo quando a base crescer.
  @lote 200

  @impl Oban.Worker
  def perform(_job) do
    purge_expired()
    :ok
  end

  @doc "Apaga os holds vencidos de todas as clínicas. Devolve quantas linhas foram removidas."
  def purge_expired do
    clinic_ids()
    |> Enum.chunk_every(@lote)
    |> Enum.reduce(0, fn lote, total -> total + purge_lote(lote) end)
  end

  defp purge_lote(clinic_ids) do
    {:ok, removidas} =
      Api.Repo.transaction(fn ->
        Enum.reduce(clinic_ids, 0, fn clinic_id, acc ->
          # A MESMA função que o resto do sistema usa para setar o tenant — o nome da GUC não se
          # repete aqui. Re-setar dentro da transação é legítimo: `set_config(..., true)` vale
          # até o commit e o último valor é o que as policies enxergam no `DELETE` seguinte.
          :ok = Api.Repo.set_clinic_guc(to_string(clinic_id))

          %{num_rows: rows} = Api.Repo.query!("DELETE FROM slot_holds WHERE expires_at <= now()")
          acc + rows
        end)
      end)

    removidas
  end

  defp clinic_ids do
    Api.Accounts.Clinic
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end
end
