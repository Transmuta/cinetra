defmodule Api.Notifications.SlotOpenedJob do
  @moduledoc """
  Tira o "quem cabe na vaga" do caminho síncrono do cancelamento (#52, P1 do doc 32).

  ## O que estava errado

  O `Api.Notifications.Fanout.slot_maybe_opened/2` roda `Api.Waitlist.who_fits/5`, que lê a fila
  inteira da clínica com seus `load`s e filtra em memória. Isso acontecia **dentro do notifier
  pós-commit** de todo cancelamento e de toda falta — 6 queries e uma transação medidas com a
  **fila vazia**, somadas à latência da resposta que o usuário está esperando. Quem cancela um
  horário paga o preço de uma pergunta sobre a fila que, na clínica sem fila, é sempre "ninguém".

  ## O desenho

  O notifier continua decidindo **se a vaga abriu** (só ele tem o changeset para comparar o
  status anterior); o que muda é que a resposta a "quem cabe" passa a ser trabalho de fundo. O
  job relê o bloco e refaz a pergunta — de propósito, e não carregando o resultado nos args:

    * entre o commit e o job cabem segundos, e nesses segundos alguém pode ter preenchido a vaga
      ou entrado na fila. Reler é o que mantém o aviso verdadeiro no momento em que ele chega;
    * `args` de Oban é JSON no banco — mandar `DateTime`/struct por ali é serialização frágil.

  Se o bloco sumiu, ou se quem causou o evento não é mais membro da clínica, o job não faz nada:
  a caixa é best-effort (o moduledoc do `Fanout` diz isso), e o pior caso de um aviso é não
  aparecer, nunca uma escrita errada.

  ## Por que fila própria

  `notifications` e não `housekeeping`: a poda diária varre clínica a clínica e pode ocupar os
  dois slots da fila por minutos. Um aviso de vaga livre atrás de um expurgo chegaria tarde
  demais para ter valor — a recepção já teria fechado o dia.
  """
  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    # O mesmo bloco abrindo a mesma vaga duas vezes em um minuto é um evento repetido, não dois
    # fatos: justificar uma falta logo após marcá-la passa duas vezes pelo rollup.
    # `keys:` recorta quais chaves do `args` entram na unicidade. Sem ele, `args` inteiro entrava
    # — inclusive `actor_id` —, e dois usuários tocando o MESMO bloco geravam dois jobs e duas
    # notificações "vaga livre" do mesmo fato, que é justamente o que este `unique` existe para
    # impedir (doc 96, P-7).
    unique: [period: 60, fields: [:worker, :args], keys: [:clinic_id, :appointment_id]]

  alias Api.Notifications.Fanout

  @doc """
  Enfileira a verificação para um bloco que acabou de abrir vaga.

  Best-effort como o resto do fan-out: se o insert falhar, o cancelamento **não** volta atrás.
  """
  def enqueue(%{id: appointment_id, clinic_id: clinic_id}, actor) do
    %{
      "clinic_id" => clinic_id,
      "appointment_id" => appointment_id,
      "actor_id" => actor_id(actor)
    }
    |> new(Api.Correlacao.opts())
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"clinic_id" => clinic_id, "appointment_id" => appointment_id} = args
      }) do
    with %{} = appointment <- carregar(clinic_id, appointment_id),
         %{} = actor <- ator(args["actor_id"]) do
      Fanout.slot_maybe_opened(appointment, actor)
    end

    :ok
  end

  defp carregar(clinic_id, appointment_id) do
    Api.Repo.with_clinic(clinic_id, fn ->
      Api.Scheduling.get_appointment(appointment_id,
        tenant: clinic_id,
        authorize?: false,
        not_found_error?: false
      )
    end)
    |> case do
      {:ok, {:ok, %{} = appointment}} -> appointment
      _ -> nil
    end
  end

  # O ator serve a duas coisas no `Fanout`: emprestar autoridade de membro ao `who_fits` e ser
  # suprimido da própria notificação. Sem ele identificável, não há fan-out a fazer.
  defp ator(nil), do: nil

  defp ator(actor_id) do
    Api.Accounts.get_user(actor_id, authorize?: false, not_found_error?: false)
    |> case do
      {:ok, %{} = user} -> user
      _ -> nil
    end
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_actor), do: nil
end
