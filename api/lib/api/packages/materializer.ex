defmodule Api.Packages.Materializer do
  @moduledoc """
  Materializa a série de um pacote — o job Oban que cria os N agendamentos reais a partir da grade
  (doc 04 §6, RN-18). Enfileirado por `Api.Packages.create_series/2` na **criação** do pacote, para
  não travar o request: uma série de 40 sessões não pode segurar a resposta HTTP.

  ## O que faz por ocorrência

  Reprojeta a série (mesmo `Api.Packages.Series` da prévia — o calendário pode ter mudado entre a
  prévia e o job) e, para cada ocorrência **não-feriado**, cria a sessão via
  `Api.Scheduling.schedule_appointment/2` (que já funde em turma existente quando é o caso, A-D4) e
  carimba o `package_id` na presença do paciente — o vínculo que o contador `usadas` conta (D11).

  Feriado **não vira sessão**: é marcador de calendário; a série já se estendeu para entregar as N
  úteis (RN-19).

  ## `encaixe` e o que o job NÃO pode forçar

  `forcar` (o "agendar mesmo assim" da tela) vira `encaixe: true` — que fura a exclusion constraint
  (conflito) e o teto de turma (cheia). **Não fura o expediente**: `CheckAvailability` é bloqueio
  absoluto (D14), encaixe não isenta. Por isso `create_series/2` **recusa** de saída uma grade com
  ocorrência fora do expediente — o job nunca recebe uma; se uma surgir por corrida (mudaram o
  expediente entre a criação e o job), a sessão falha e o job registra, sem materializar meia série
  em silêncio.

  ## Idempotência

  Oban re-executa em falha. Antes de materializar, o job lê as presenças já carimbadas com este
  `package_id` e **pula** as ocorrências cujo horário já existe. Uma re-execução após sucesso é
  no-op; após falha parcial, completa o que faltou.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  import Api.Tenancy, only: [in_clinic: 2]

  require Logger

  alias Api.Scheduling.LocalTime

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"package_id" => package_id, "clinic_id" => clinic_id} = args

    # O job **engole o motivo de propósito**, e isso não é o mesmo silêncio de antes: a recusa já
    # foi registrada por `create_sessions/3`, com data e razão. O que ele não faz é falhar.
    #
    # Falhar poria a fila em retry eterno num caso que é NORMAL — a criação de uma série de 40
    # sessões pode legitimamente esbarrar num slot ocupado, e é para isso que existe o
    # `forcar`/encaixe. Quem precisa da resposta na hora não usa o job: usa `materializar/3`
    # direto, que devolve o motivo (ver `Api.Packages.add_session/2`).
    case materializar(package_id, clinic_id, args) do
      {:ok, _criadas} -> :ok
      {:error, _motivo} -> :ok
    end
  end

  @doc """
  Materializa **agora**, no processo de quem chamou, e devolve o que aconteceu.

  É o mesmo caminho que o `perform/1` roda — a diferença é só quem trata o resultado. Existe
  porque há duas situações com necessidades opostas:

    * **criar a série inteira** (40 sessões) não pode segurar a requisição HTTP, e uma sessão
      recusada por conflito ali é caso normal → job, resultado engolido, recusa no log;
    * **somar UMA sessão** (`+1`) precisa da resposta na hora, porque o `total` do pacote só pode
      subir se a sessão de fato nasceu. Enfileirar ali era o que produzia pacote vendido com N+1
      e com N na agenda, sem ninguém saber.

  `args` usa chaves de string por ser o mesmo mapa que o Oban carrega: `from` (ISO), `count` e
  `forcar` são opcionais e caem no default do pacote quando ausentes.

  Devolve `{:ok, quantas_nasceram}` ou `{:error, motivo}` — o motivo é o erro do Ash da primeira
  sessão recusada, então o controller o serializa com a mesma máquina de sempre.
  """
  @spec materializar(binary(), binary(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def materializar(package_id, clinic_id, args \\ %{}) do
    forcar = Map.get(args, "forcar", false)

    # As leituras rodam sob a GUC de tenant (`in_clinic`): sem ela a RLS (ADR-018) lê o
    # `movimento.clinic_id` vazio e estoura `""::uuid` no job — o mesmo furo que o `mix test`
    # (superusuário) não vê. O plano (quais instantes criar) sai daqui já resolvido.
    plan =
      in_clinic(clinic_id, fn ->
        pkg =
          Api.Packages.get_package!(package_id,
            tenant: clinic_id,
            authorize?: false,
            load: [:schedule]
          )

        build_plan(pkg, clinic_id, anchor(args, pkg), count(args, pkg))
      end)

    # As escritas ficam **fora** do `in_clinic`: cada sessão seta a própria GUC (`SetTenantGuc`).
    # Envolver a escrita na transação de leitura quebraria o caminho de erro (ver `Api.Tenancy`).
    create_sessions(plan, clinic_id, forcar)
  end

  # Criação: âncora = `data_inicio`, total = `pkg.total`. Retomada (GAP-06): a retomada passa
  # `from` (hoje) e `count` (quantas seguradas foram canceladas) para reprojetar só o que falta.
  defp anchor(%{"from" => iso}, _pkg) when is_binary(iso), do: Date.from_iso8601!(iso)
  defp anchor(_args, pkg), do: pkg.data_inicio

  defp count(%{"count" => n}, _pkg) when is_integer(n), do: n
  defp count(_args, pkg), do: pkg.total

  # Resolve, sob a GUC, TUDO que precisa de leitura: tipo, feriados, série projetada e os horários
  # já materializados. Devolve só os instantes a criar — as escritas acontecem fora daqui.

  # Pacote CANCELADO não materializa (bate-volta 2026-07-24, provado ao vivo): se o usuário cancela
  # um pacote recém-criado ANTES de o job async rodar, o job criava as sessões mesmo assim — órfãs
  # `:agendado` ocupando a agenda de um pacote `:cancelado`. O job lê o status atual do pacote; se
  # já foi cancelado, pula. (Retomada roda com o pacote `:ativo`, então não é afetada.)
  defp build_plan(%{status: :cancelado} = pkg, _clinic_id, _anchor, _count), do: {:skip, pkg.id}

  defp build_plan(%{schedule: nil} = pkg, _clinic_id, _anchor, _count), do: {:no_grade, pkg.id}

  defp build_plan(pkg, clinic_id, anchor, total) do
    %{timezone: tz} = Api.Scheduling.load_clinic(clinic_id)

    tipo =
      Api.Directory.get_appointment_type!(pkg.appointment_type_id,
        tenant: clinic_id,
        authorize?: false
      )

    feriados = Api.Scheduling.clinic_holidays(clinic_id)
    grade = %{dows: pkg.schedule.dows, horarios: pkg.schedule.horarios}

    with {:ok, ocorrencias} <- Api.Packages.Series.project(anchor, grade, total, feriados) do
      ja_feitas = materialized_starts(pkg.id, clinic_id)

      starts =
        ocorrencias
        |> Enum.reject(& &1.feriado?)
        |> Enum.map(fn occ ->
          {:ok, starts_at} = LocalTime.to_utc(occ.data, occ.hhmm, tz)
          starts_at
        end)
        |> Enum.reject(&MapSet.member?(ja_feitas, DateTime.to_iso8601(&1)))

      {:ok, pkg, tipo, starts}
    end
  end

  defp create_sessions({:skip, pkg_id}, _clinic_id, _forcar) do
    # Pacote cancelado antes do job — nada a materializar (ver `build_plan`). Zero criadas, e não
    # é erro: o job nunca vai ter o que fazer, então não há o que re-tentar.
    Logger.info("Pacote #{pkg_id} cancelado antes da materialização; job ignorado")
    {:ok, 0}
  end

  defp create_sessions({:no_grade, pkg_id}, _clinic_id, _forcar) do
    # Sem grade não há o que materializar — não deveria acontecer (a grade nasce com o pacote).
    Logger.error("Pacote #{pkg_id} sem grade na materialização; nada a fazer")
    {:error, :sem_grade}
  end

  defp create_sessions({:error, _reason} = erro, _clinic_id, _forcar), do: erro

  defp create_sessions({:ok, pkg, tipo, starts}, clinic_id, forcar) do
    # Aqui havia um `Enum.each` que **descartava** o `{:error, _}` de `create_and_stamp/5` e
    # devolvia `:ok`: o Oban registrava sucesso, nenhuma linha era escrita e nada em lugar nenhum
    # dizia que a sessão não nasceu. Foi o que tornou invisível o defeito do `adjust_grade` medido
    # no bate-volta (doc 77) — as futuras eram canceladas, a re-materialização não acontecia, e o
    # pacote ficava com zero sessão sem um único sinal.
    #
    # Agora o resultado SOBE. Quem decide o que fazer com ele é o chamador, porque a resposta certa
    # depende de quem chamou: o job engole (retry eterno seria pior), o `+1` recusa e devolve o
    # motivo. O motivo que sobe é o da PRIMEIRA sessão recusada — é a que explica o resto.
    {criadas, falhas} =
      Enum.reduce(starts, {0, []}, fn starts_at, {criadas, falhas} ->
        case Api.Packages.Sessions.create_and_stamp(pkg, tipo, starts_at, clinic_id, forcar) do
          {:ok, _appt} ->
            {criadas + 1, falhas}

          {:error, motivo} ->
            Logger.error(
              "Materialização: sessão de #{DateTime.to_iso8601(starts_at)} do pacote #{pkg.id} " <>
                "não foi criada — #{inspect(motivo)}"
            )

            {criadas, [motivo | falhas]}
        end
      end)

    case Enum.reverse(falhas) do
      [] ->
        {:ok, criadas}

      [primeiro | _] ->
        Logger.error(
          "Materialização do pacote #{pkg.id}: #{length(falhas)} de #{length(starts)} " <>
            "sessões não nasceram"
        )

        {:error, primeiro}
    end
  end

  # As presenças **ativas** carimbadas com este pacote → horários (ISO) já materializados. Ignora
  # canceladas: na retomada (GAP-06) as seguradas foram canceladas e não devem bloquear a
  # reprojeção de uma data que por acaso coincida com a original de uma delas.
  defp materialized_starts(package_id, clinic_id) do
    Api.Scheduling.list_attendances!(
      tenant: clinic_id,
      authorize?: false,
      query: [filter: [package_id: package_id]],
      load: [:appointment]
    )
    |> Enum.map(& &1.appointment)
    # `nil`: a sessão está segurada (pkg_hold) e o load global a esconde — não conta como
    # materializada ativa. Cancelada: idem (a retomada não deve tropeçar na data da que cancelou).
    |> Enum.reject(&(is_nil(&1) or &1.status == :cancelado))
    |> MapSet.new(&DateTime.to_iso8601(&1.starts_at))
  end
end
