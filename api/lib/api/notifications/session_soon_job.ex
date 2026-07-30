defmodule Api.Notifications.SessionSoonJob do
  @moduledoc """
  "Sua próxima sessão começa às HH:MM" — o segundo lembrete do #51 (doc 31 §3d).

  ## Sobre a recomendação contrária que este job contraria

  O doc 31 §3d marcou este item como 🔴 **não-v1**: *"a tela do dia já mostra; valor marginal;
  ruído alto"*. O doc 35 o selecionou assim mesmo, e a decisão foi reafirmada em 2026-07-26. Fica
  registrado aqui porque quem ler depois merece saber que a objeção existe e foi vencida por
  escolha, não por esquecimento — e porque desligar é **uma linha**: tirar a entrada do crontab
  em `config/config.exs`.

  ## A janela, e por que não é "15 minutos" no texto

  O cron roda a cada 5 minutos e serve os blocos que começam na janela
  `[agora + #{Application.compile_env(:api, [__MODULE__, :antecedencia_min], 15)} min,
    agora + #{Application.compile_env(:api, [__MODULE__, :antecedencia_min], 15) + 5} min)`.

  Essa janela **ladrilha** a linha do tempo: sem buraco (todo bloco cai em exatamente uma
  rodada) e sem sobreposição (nenhum bloco cai em duas). É o que garante um aviso por sessão sem
  precisar de tabela de "já avisei".

  Um cron de minuto daria precisão maior e custaria 12× mais varreduras por clínica — o preço que
  o D-L (doc 30) cobrou do cron anterior. Como o texto do aviso diz a **hora exata** da sessão e
  não "em 15 minutos", a imprecisão da janela não chega ao usuário como informação errada.
  """
  # `max_attempts: 1`, e **sem** `unique` — as duas coisas pelo mesmo motivo: este job é um
  # **tique**, não uma tarefa a concluir.
  #
  #   * retentar é pior que falhar. A janela é derivada do relógio de **quando o job roda**, não
  #     de um argumento; uma retentativa 30 s depois cobre `[+15, +20)` a partir dali, que
  #     **sobrepõe** a janela da rodada seguinte — e o profissional recebe o mesmo lembrete duas
  #     vezes. Uma rodada perdida é só uma rodada perdida: o próximo tique segue em frente;
  #   * havia aqui um `unique: [period: 300]` num cron que roda a cada 300 s, ou seja, margem
  #     zero. A dedupe do Oban conta jobs `:completed`, então bastava a rodada seguinte chegar
  #     uma fração de segundo cedo para ser engolida como duplicata — o lembrete pararia de sair
  #     **em silêncio**. E ela não protegia de nada: quem garante uma inserção por intervalo já é
  #     o próprio cron.
  use Oban.Worker, queue: :notifications, max_attempts: 1

  alias Api.Notifications.Fanout
  alias Api.Notifications.Reminders

  # O passo do cron. A janela tem exatamente esta largura — é o que a faz ladrilhar.
  @passo_min 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    antecedencia = Map.get(args, "antecedencia_min", antecedencia_configurada())
    agora = agora(args)

    de = DateTime.add(agora, antecedencia * 60, :second)
    ate = DateTime.add(de, @passo_min * 60, :second)

    enviados =
      Enum.reduce(Api.Housekeeping.Poda.clinicas(), 0, fn clinic_id, total ->
        tz = Api.Scheduling.clinic_timezone(clinic_id)

        total +
          Reminders.por_dono_da_coluna(clinic_id, de, ate, fn user_id, blocos ->
            # Um aviso por bloco: numa turma o profissional tem UM bloco, e dois blocos
            # distintos na mesma janela são dois compromissos de verdade.
            Enum.each(blocos, &Fanout.session_soon(clinic_id, user_id, &1, tz))
            length(blocos)
          end)
      end)

    {:ok, %{enviados: enviados}}
  end

  @doc "Quantos minutos antes o aviso sai."
  def antecedencia_configurada,
    do: Application.get_env(:api, __MODULE__, [])[:antecedencia_min] || 15

  # `agora` injetável pelos args: o teste precisa fixar o instante para montar a janela, e é a
  # mesma disciplina de relógio do resto do projeto (ADR-009 — relógio é entrada, não ambiente).
  defp agora(%{"agora" => iso}) when is_binary(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  defp agora(_args), do: DateTime.utc_now()
end
