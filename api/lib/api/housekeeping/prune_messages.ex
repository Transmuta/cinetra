defmodule Api.Housekeeping.PruneMessages do
  @moduledoc """
  A poda de `messages` — **dois relógios sobre a mesma linha** (doc 101, M10 · `[D-11]`).

  ## Por que dois, e não um

  A linha de `messages` acumula dois papéis que têm prazos de validade diferentes, e tratá-los
  com um número só erra dos dois lados:

    * **a prova de que a clínica avisou** — `kind`, `canal`, `template`, `status`,
      `provider_message_id` e os carimbos (`enviado_em`, `entregue_em`, `falhou_em`). Foi por
      isso que este recurso dispensou o `AshPaperTrail`: **o registro é o histórico**. Apagá-lo
      cedo é destruir a resposta para *"ninguém me avisou"*, que é exatamente a pergunta que
      chega tarde;
    * **o dado pessoal do titular** — `vars` (o nome do paciente, a data e a hora da sessão dele)
      e `destino` (o e-mail ou telefone **congelado** no envio). Isso é dado parado, que a
      minimização da LGPD desaconselha manter para sempre, e que ninguém lê depois de a mensagem
      sair — a timeline do drawer é operacional, olhada em dias, não em anos.

  Daí a mecânica: a janela **curta** anonimiza (`UPDATE`, a linha fica), a janela **longa** apaga
  (`DELETE`). Uma mensagem anonimizada continua dizendo *"foi mandado um lembrete por WhatsApp em
  12/03, e o provider confirmou a entrega"* — que é a prova inteira, sem o número de telefone de
  ninguém.

  ## O número não está aqui, e isso é o desenho

  **Este job não roda sem política configurada.** Sem as duas chaves em config ele registra um
  aviso e devolve zero, sem tocar em linha nenhuma:

      config :api, Api.Housekeeping.PruneMessages,
        reter_pii_dias: 90,
        reter_dias: 1825

  E ele **não está no crontab** (`config/config.exs`), de propósito. O `[D-11]` decidiu, em
  2026-07-28, esperar: retenção é pergunta transversal e **jurídica** — quanto tempo se consegue
  provar que a clínica avisou, contra quanto tempo se pode guardar dado pessoal de um paciente —
  e decidir tabela a tabela é como se chega a quatro réguas que ninguém sabe justificar depois. O
  que faltava não era mecanismo; era o número.

  Então o mecanismo fica pronto, testado e **desarmado**: ligar é acrescentar as duas linhas de
  config e uma linha de cron, com o número vindo de quem pode decidi-lo. Um default embutido aqui
  faria o oposto — o dia em que alguém pusesse o cron, a régua de ninguém entraria em produção em
  silêncio, e é exatamente esse silêncio que o D-11 existe para evitar.

  ## Como respeita a RLS

  Por clínica, cada lote dentro de `Api.Repo.with_clinic/2` (`Api.Housekeeping.Poda`) — o job roda
  como `cinetra_app` no servidor real, e sem GUC o `UPDATE`/`DELETE` toca **zero linha em
  silêncio**. É a armadilha de sempre, e a razão de nem o `UPDATE` daqui escrever SQL próprio.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Logger

  alias Api.Housekeeping.Poda

  @tabela "messages"

  # O que sobra no lugar do dado pessoal. `destino` é `allow_nil? false`, então some para um
  # marcador em vez de `NULL` — e o marcador é legível de propósito: a timeline mostra "podado" e
  # não um vazio que se confunde com "não sabemos para onde foi".
  @destino_podado "[podado]"

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case politica(args) do
      {:ok, dias_pii, dias_linha} ->
        podar(dias_pii, dias_linha)

      :sem_politica ->
        Logger.warning(
          "PruneMessages: sem política de retenção configurada (reter_pii_dias/reter_dias) — " <>
            "nada foi podado. Ver `Api.Housekeeping.PruneMessages` e o D-11."
        )

        {:ok, %{anonimizadas: 0, apagadas: 0, pendente: :politica}}
    end
  end

  defp podar(dias_pii, dias_linha) do
    corte_pii = Poda.corte_em_dias(dias_pii)
    corte_linha = Poda.corte_em_dias(dias_linha)

    # O DELETE primeiro: anonimizar linha que vai ser apagada logo em seguida é trabalho jogado
    # fora, e em volume ele é o dobro de escrita no WAL.
    apagadas = Poda.por_clinica(&apagar(&1, corte_linha))
    anonimizadas = Poda.por_clinica(&anonimizar(&1, corte_pii))

    if apagadas > 0 or anonimizadas > 0 do
      Logger.info(
        "PruneMessages: #{anonimizadas} anonimizadas (corte #{NaiveDateTime.to_iso8601(corte_pii)}), " <>
          "#{apagadas} apagadas (corte #{NaiveDateTime.to_iso8601(corte_linha)})"
      )
    end

    {:ok, %{anonimizadas: anonimizadas, apagadas: apagadas}}
  end

  # `destino <> marcador` na condição é o que faz o laço terminar: sem ele, as mesmas linhas
  # voltariam a casar a cada volta e o lote nunca ficaria abaixo do teto.
  defp anonimizar(clinic_id, corte) do
    Poda.atualizar_em_lote(
      @tabela,
      "vars = '{}'::jsonb, destino = $3",
      "clinic_id = $1 AND inserted_at < $2 AND destino <> $3",
      [Ecto.UUID.dump!(clinic_id), corte, @destino_podado],
      clinic_id
    )
  end

  defp apagar(clinic_id, corte) do
    Poda.em_lote(
      @tabela,
      "clinic_id = $1 AND inserted_at < $2",
      [Ecto.UUID.dump!(clinic_id), corte],
      clinic_id
    )
  end

  @doc """
  As duas janelas configuradas, ou `:sem_politica`.

  `args` do job vence a config (é o que o teste usa, e o que serviria a uma poda pontual), mas
  **as duas chaves precisam estar presentes**: meia política é a mais perigosa das três
  possibilidades — anonimizar sem apagar deixa a tabela crescendo para sempre, e apagar sem
  anonimizar guarda dado pessoal até o último dia da janela longa.
  """
  @spec politica(map()) :: {:ok, non_neg_integer(), non_neg_integer()} | :sem_politica
  def politica(args \\ %{}) do
    config = Application.get_env(:api, __MODULE__, [])

    pii = dias(args, "reter_pii_dias", config[:reter_pii_dias])
    linha = dias(args, "reter_dias", config[:reter_dias])

    cond do
      is_nil(pii) or is_nil(linha) -> :sem_politica
      pii > linha -> :sem_politica
      true -> {:ok, pii, linha}
    end
  end

  defp dias(args, chave, configurado) do
    case Map.get(args, chave, configurado) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end
end
