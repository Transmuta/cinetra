defmodule Api.Notifications.DailyDigestJob do
  @moduledoc """
  "Você tem N atendimentos amanhã" — o resumo diário do #51 (doc 31 §3d).

  ## Por que de hora em hora, e não uma vez por dia

  A hora do resumo é **local da clínica** (#{Application.compile_env(:api, [__MODULE__, :hora], 19)}h
  por padrão), e cada clínica tem o seu fuso (ADR-009). Um cron único em UTC serviria a hora certa
  para uma clínica e a errada para as demais. Então o job acorda a cada hora e só trabalha nas
  clínicas cujo relógio marca a hora configurada — a varredura é barata (uma leitura de fuso
  cacheada por clínica) e a agenda só é lida de quem vai receber.

  Mudar a hora é uma linha de config:

      config :api, Api.Notifications.DailyDigestJob, hora: 19

  Args: `%{"forcar" => true}` ignora o relógio (execução manual e teste); `%{"hora" => n}`
  substitui a configurada.

  ## O que conta

  Só bloco **vivo** (`agendado`/`confirmado`/`em_atendimento`) do dia seguinte, no fuso da
  clínica. Cancelado não é compromisso, e lembrar dele seria pior que não lembrar.
  """
  # `max_attempts: 1` pelo mesmo motivo do `SessionSoonJob`: uma retentativa reenviaria o resumo
  # a quem já recebeu antes de a rodada falhar no meio. Resumo duplicado é pior que resumo
  # ausente — e a rodada da hora seguinte não repete o dia, então nada se acumula.
  use Oban.Worker, queue: :notifications, max_attempts: 1

  alias Api.Notifications.Fanout
  alias Api.Notifications.Reminders

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    hora = Map.get(args, "hora", hora_configurada())
    forcar? = Map.get(args, "forcar", false) == true

    enviados =
      Reminders.em_cada_clinica_as(hora, [forcar?: forcar?], fn clinic_id, tz ->
        amanha = tz |> hoje_local() |> Date.add(1)

        de = Reminders.inicio_do_dia(amanha, tz)
        ate = Reminders.inicio_do_dia(Date.add(amanha, 1), tz)

        Reminders.por_dono_da_coluna(clinic_id, de, ate, fn user_id, blocos ->
          Fanout.daily_digest(clinic_id, user_id, amanha, length(blocos))
          1
        end)
      end)

    {:ok, %{enviados: enviados}}
  end

  @doc "A hora local em que o resumo sai. Config, porque é escolha de produto."
  def hora_configurada, do: Application.get_env(:api, __MODULE__, [])[:hora] || 19

  defp hoje_local(tz), do: DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date()
end
