defmodule Api.Messaging.ReminderJob do
  @moduledoc """
  "Sua sessão é amanhã às HH:MM" — o lembrete por relógio (doc 52 §7).

  ## Nasceu calado; desde 2026-07-31 fala por padrão

  `Clinic.msg_lembrete_horas` nascia `nil` (desligado) porque a fatia tinha **outro** disparo
  automático — a confirmação na criação do agendamento —, e o cron podia esperar alguém escolher
  um número na tela sem que nenhum paciente ficasse sem comunicação.

  Removida a confirmação (doc 98), este job passou a ser o **único** contato automático com o
  paciente, e o padrão virou **2 h**. Clínica que não quer continua desligando na tela — `nil`
  segue significando desligado, e é pulada aqui.

  ## A janela ladrilha, e é isso que dispensa uma tabela de "já avisei"

  O cron roda a cada 15 min e serve as sessões que começam em `[agora + N, agora + N + 15min)`.
  Essa janela **ladrilha** a linha do tempo: sem buraco (toda sessão cai em exatamente uma
  rodada) e sem sobreposição (nenhuma cai em duas). É o mesmo desenho do
  `Api.Notifications.SessionSoonJob`, e pelo mesmo motivo — o alternativo seria uma coluna
  "lembrete_enviado_em" e a manutenção que vem com ela.

  A dedupe de verdade continua existindo como rede: o `Dispatch` grava uma `Message` por
  disparo, e uma segunda rodada geraria uma segunda linha visível na timeline. Se isso um dia
  acontecer, aparece na tela — não em silêncio.

  ## Sem retentativa, e isso é deliberado

  `max_attempts: 1`, como o `SessionSoonJob`: a janela deriva do relógio de **quando o job roda**,
  não de um argumento. Uma retentativa 30 s depois cobre `[+N, +N+15min)` a partir dali, que
  **sobrepõe** a janela da rodada seguinte — e o paciente recebe o mesmo lembrete duas vezes.
  Uma rodada perdida é só uma rodada perdida.

  ## Varredura por clínica, sob a GUC

  As tabelas têm RLS (ADR-018) e o job roda como `cinetra_app`. Um `SELECT` cross-tenant não
  volta vazio por acaso: volta vazio **sempre**, e passa no `mix test`, onde o sandbox conecta
  como superusuário. Mesmo cuidado do `Api.Notifications.Reminders`.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 1

  require Ash.Query
  require Logger

  alias Api.Messaging.Dispatch

  # A largura da janela é o passo do cron. É o que a faz ladrilhar — mexer em um sem o outro abre
  # buraco (sessão que ninguém lembra) ou sobreposição (lembrete em dobro).
  #
  # **15 min, e não mais 1 h** (2026-07-31, doc 98): a largura da janela é o ERRO da antecedência
  # configurada. Com 1 h, "2 horas antes" entregava entre 2h00 e 2h59 — meio prazo de folga num
  # aviso de duas horas. Com 24 h ninguém notava; foi o padrão de 2 h que tornou o erro visível.
  @passo_minutos 15

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    agora = agora(args)

    enviados =
      Enum.reduce(Api.Housekeeping.Poda.clinicas(), 0, fn clinic_id, total ->
        total + por_clinica(clinic_id, agora)
      end)

    if enviados > 0, do: Logger.info("lembretes de sessão enfileirados: #{enviados}")

    :ok
  end

  defp por_clinica(clinic_id, agora) do
    Api.Repo.with_clinic(clinic_id, fn ->
      clinic = Api.Accounts.get_clinic!(clinic_id, authorize?: false)

      case clinic.msg_lembrete_horas do
        nil -> 0
        horas -> lembrar(clinic, janela(agora, horas))
      end
    end)
    |> elem(1)
  rescue
    erro ->
      # Uma clínica com dado ruim não pode parar a varredura das outras — é o mesmo contrato
      # best-effort do resto dos lembretes.
      Logger.warning("lembrete falhou na clínica #{clinic_id}: #{Exception.message(erro)}")
      0
  end

  defp janela(agora, horas) do
    de = DateTime.add(agora, horas * 3600, :second)
    {de, DateTime.add(de, @passo_minutos * 60, :second)}
  end

  defp lembrar(clinic, {de, ate}) do
    clinic
    |> presencas_na_janela(de, ate)
    |> Enum.count(fn attendance ->
      match?({:ok, _}, Dispatch.dispatch(clinic, attendance, attendance.patient, :lembrete))
    end)
  end

  # Só presença `:prevista` — quem já concluiu, faltou ou saiu do bloco não precisa de lembrete.
  # `session_starts_at` mora na presença (não no bloco) desde a A2.
  #
  # Quem serve esta varredura é `attendances_clinic_session_starts_at_index`, criado na migration
  # `LembretePorJanelaDeTempo` — **e ele não existia quando este job foi escrito**. O bate-volta
  # mediu o que acontecia sem ele: 134,8 ms e 16.863 buffers para devolver 15 linhas, por clínica
  # e por hora. O `status` fica de fora do índice de propósito (ver o moduledoc da migration).
  defp presencas_na_janela(clinic, de, ate) do
    Api.Scheduling.Attendance
    |> Ash.Query.for_read(:read, %{}, tenant: clinic.id, authorize?: false)
    |> Ash.Query.filter(
      session_starts_at >= ^de and session_starts_at < ^ate and status == :prevista
    )
    |> Ash.Query.load([:patient])
    |> Ash.read!(authorize?: false)
  end

  # O relógio vem dos args quando o teste o injeta (D1) — senão é o de agora.
  defp agora(%{"agora" => iso}) when is_binary(iso) do
    {:ok, instante, _} = DateTime.from_iso8601(iso)
    instante
  end

  defp agora(_args), do: DateTime.utc_now()
end
