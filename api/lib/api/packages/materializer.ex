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
    # Pacote cancelado antes do job — nada a materializar (ver `build_plan`). Encerra em `:ok`
    # para o Oban não re-tentar um job que nunca vai ter o que fazer.
    Logger.info("Pacote #{pkg_id} cancelado antes da materialização; job ignorado")
    :ok
  end

  defp create_sessions({:no_grade, pkg_id}, _clinic_id, _forcar) do
    # Sem grade não há o que materializar — não deveria acontecer (a grade nasce com o pacote), mas
    # falhar aqui só geraria retry infinito. Registra e encerra.
    Logger.error("Pacote #{pkg_id} sem grade na materialização; nada a fazer")
    :ok
  end

  defp create_sessions({:error, _reason} = erro, _clinic_id, _forcar), do: erro

  defp create_sessions({:ok, pkg, tipo, starts}, clinic_id, forcar) do
    Enum.each(starts, fn starts_at ->
      Api.Packages.Sessions.create_and_stamp(pkg, tipo, starts_at, clinic_id, forcar)
    end)

    :ok
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
