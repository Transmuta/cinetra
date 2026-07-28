defmodule Api.Housekeeping.PruneAttachments do
  @moduledoc """
  Recolhe o lixo dos anexos (doc 51). Duas varreduras, com naturezas diferentes.

  ## 1. Uploads abandonados (`:pendente`)

  A linha do anexo nasce **antes** dos bytes, para que "objeto sem linha" seja impossível
  (`Api.Records.Attachment`). O preço dessa escolha é o inverso: quem fecha a aba no meio do
  upload deixa uma linha `:pendente` — e, às vezes, um objeto no bucket que ninguém confirmou.
  Esta poda limpa os dois, depois de
  #{Application.compile_env(:api, [__MODULE__, :reter_pendentes_horas], 24)} h.

  **Não** é um `DELETE` em lote como as outras podas do projeto, e não pode ser: cada linha tem
  bytes do outro lado, e SQL não fala com o R2. Varre linha a linha, apagando o objeto primeiro —
  a mesma ordem de `Api.Records.delete_attachment/2`, pelo mesmo motivo. O volume torna isso
  barato: um upload abandonado é evento raro.

  ## 2. A trilha de acesso NÃO é mais podada aqui

  Ela era: `attachment_events` tinha retenção própria de 730 dias — o dobro da trilha de
  agendamentos — com o argumento de que *"quem leu o laudo da paciente em 2027?"* tem prazo mais
  longo que *"quem remarcou a sessão de terça"*.

  Duas coisas mudaram no doc 63, e as duas foram decisão humana:

    * a trilha de acesso ao anexo passou a morar em `audit_events`, com o resto do sistema
      (D-Aud3) — a tabela própria não tinha rota nenhuma e ninguém conseguia lê-la;
    * a retenção passou a ser **uma só, de 90 dias** (D-Aud5), aplicada por
      `Api.Housekeeping.PruneTrail`.

  O argumento dos 730 dias continua de pé e está registrado para a revisão com o jurídico
  ([`Api.Audit`](../audit.ex)): 90 dias vale igual para "quem leu o laudo", que é o registro que
  uma auditoria externa costuma pedir de anos anteriores. A decisão foi tomada com isso dito.

  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Ash.Query
  require Logger

  alias Api.Housekeeping.Poda
  alias Api.Records.Attachment

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    pendentes = podar_pendentes(corte_pendentes(args))

    if pendentes > 0 do
      Logger.info("poda de anexos: #{pendentes} pendente(s)")
    end

    :ok
  end

  # Três fases, e a separação é o ponto: **o HTTP não pode rodar dentro da transação**.
  #
  # `Poda.por_clinica/1` abre uma transação por clínica (`Api.Repo.with_clinic/2` →
  # `Repo.transaction/1`) para escopar a GUC da RLS. A versão anterior chamava
  # `Api.Storage.delete/1` — request ao Cloudflare, `receive_timeout` de 15 s — de dentro dela,
  # uma vez por linha: uma clínica com 20 uploads abandonados segurava **uma conexão do pool por
  # até 5 minutos**, e o sintoma disso aparece como latência de API, não como problema do job
  # (`references/performance.md`: "transação longa segurando a GUC").
  #
  # Agora: (1) LÊ as chaves sob transação; (2) apaga os objetos FORA dela; (3) apaga as linhas.
  # A ordem objeto-antes-de-linha é a mesma de `Api.Records.delete_attachment/2`, pelo mesmo
  # motivo — se a fase 2 falhar, sobra linha `:pendente`, que a próxima rodada recolhe.
  defp podar_pendentes(corte) do
    Poda.clinicas()
    |> Enum.map(&podar_pendentes_da_clinica(&1, corte))
    |> Enum.sum()
  end

  defp podar_pendentes_da_clinica(clinic_id, corte) do
    # (1) só leitura, dentro da transação com a GUC. `authorize?: false` porque a poda não tem
    # ator — é manutenção do sistema; e sem a GUC a RLS devolveria zero linha sem dizer nada.
    {:ok, pendentes} =
      Api.Repo.with_clinic(clinic_id, fn ->
        Attachment
        |> Ash.Query.filter(status == :pendente and inserted_at < ^corte)
        |> Ash.read!(tenant: clinic_id, authorize?: false)
      end)

    # (2) fora de qualquer transação: a rede alheia não segura conexão do pool.
    apagaveis = Enum.filter(pendentes, &apagar_objeto/1)

    # (3) de volta à transação, só para o DELETE das linhas cujo objeto já foi.
    {:ok, apagadas} =
      Api.Repo.with_clinic(clinic_id, fn ->
        Enum.count(apagaveis, &apagar_linha(&1, clinic_id))
      end)

    apagadas
  end

  defp apagar_objeto(anexo) do
    case Api.Storage.delete(anexo.chave) do
      :ok ->
        true

      # O `chave` NÃO entra no log: carrega os ids de clínica e paciente (`05 §2.4`). Falhou,
      # fica para a próxima rodada — a linha continua `:pendente`.
      {:error, motivo} ->
        Logger.warning("poda de anexos: storage recusou #{anexo.id} (#{inspect(motivo)})")
        false
    end
  end

  defp apagar_linha(anexo, clinic_id) do
    # `return_notifications?: true` (e descartadas) porque este destroy roda dentro da transação
    # da fase 3: sem isto o Ash avisa, a cada linha, que as notificações não puderam ser
    # enviadas. Poda é manutenção — não há a quem notificar.
    Ash.destroy!(anexo, tenant: clinic_id, authorize?: false, return_notifications?: true)
    true
  rescue
    # Uma linha problemática não derruba a varredura das outras — nem a da próxima clínica.
    erro ->
      Logger.warning("poda de anexos: falhou em #{anexo.id} (#{Exception.message(erro)})")
      false
  end

  defp corte_pendentes(args) do
    horas =
      Map.get(args, "reter_pendentes_horas") ||
        Application.get_env(:api, __MODULE__, [])[:reter_pendentes_horas] || 24

    DateTime.add(DateTime.utc_now(), -horas * 3600, :second)
  end
end
