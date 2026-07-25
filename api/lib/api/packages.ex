defmodule Api.Packages do
  @moduledoc """
  Domínio dos **pacotes** (doc 25, Fatia 3) — recursos por-tenant por atributo (`clinic_id`,
  ADR-017), no molde de `Api.Scheduling`/`Api.Waitlist`.

  Reúne o pacote (`Package`), sua grade (`PackageSchedule`) e o motor puro de série
  (`Api.Packages.Series`, sem recurso — só função).

  Como nos outros domínios por-tenant, os **wrappers deste módulo** centralizam o `in_clinic/2`
  (GUC de tenant para a RLS, ADR-018) na leitura; a escrita seta a GUC dentro da própria ação
  (`SetTenantGuc`).
  """
  use Ash.Domain, otp_app: :api

  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query

  resources do
    resource Api.Packages.Package do
      define :create_package, action: :create
      define :list_packages, action: :read
      define :get_package, action: :read, get_by: [:id]
      define :mark_package_paused, action: :mark_paused
      define :mark_package_active, action: :mark_active
      define :mark_package_cancelled, action: :mark_cancelled
    end

    resource Api.Packages.PackageSchedule do
      define :get_package_schedule, action: :read, get_by: [:id]
    end
  end

  @doc """
  A **prévia** da série de um pacote antes de criá-lo (o save-gate, doc 02 §1.5). Projeta e
  classifica cada ocorrência sem escrever. Delega a `Api.Packages.Preview` — ver lá o contrato.
  """
  defdelegate preview_series(scope, params), to: Api.Packages.Preview, as: :run

  @doc """
  Cria o pacote **e enfileira a materialização** da série (doc 04 §6). O ponto de entrada da
  criação: o controller chama isto, não `create_package` cru.

  Roda a prévia server-side (nunca confia no cliente) e **decide antes de escrever**:

    * ocorrência **fora do expediente** → `{:error, {:fora_expediente, previa}}`. É bloqueio
      absoluto (D14): encaixe não isenta, então nem `forcar` materializa esses — recusar de saída
      evita um pacote que jamais se agenda por inteiro.
    * conflito/turma cheia **sem `forcar`** → `{:error, {:precisa_confirmar, previa}}`. A tela
      reapresenta com o "agendar mesmo assim".
    * caso contrário → cria o pacote, enfileira `Api.Packages.Materializer` (que grava as sessões
      como `encaixe` quando `forcar`), e devolve `{:ok, package}`.

  A criação do pacote e o enfileiramento do job compartilham a transação da ação
  (`Oban.insert` dentro do `after_action`), então não há pacote sem job nem job sem pacote.
  """
  def create_series(%Api.Scope{} = scope, params, opts \\ []) do
    forcar = Keyword.get(opts, :forcar, false)

    with {:ok, previa} <- preview_series(scope, params),
         :ok <- gate(previa, forcar) do
      attrs = Map.merge(params, %{materialize?: true, forcar: forcar})
      create_package(attrs, scope: scope)
    end
  end

  defp gate(%{ocorrencias: ocorrencias} = previa, forcar) do
    cond do
      Enum.any?(ocorrencias, &(&1.issue == :fora_expediente)) ->
        {:error, {:fora_expediente, previa}}

      previa.bloqueios > 0 and not forcar ->
        {:error, {:precisa_confirmar, previa}}

      true ->
        :ok
    end
  end

  @doc """
  **Pausa** o pacote (RN-23): segura (`pkg_hold`) as sessões futuras ainda não resolvidas — elas
  somem da agenda (RN-05) — e marca o pacote como `:pausado`. As duas escritas na mesma transação
  (molde de `update_clinic_hours`): não fica pacote pausado com sessão solta, nem vice-versa.

  "Futura ainda não resolvida" = a sessão cujo dia (no fuso da clínica) é **hoje ou depois** e cujo
  status é `:agendado`/`:confirmado`. Passado, concluído, faltou e cancelado não se tocam.
  """
  def pause_package(%Api.Scope{} = scope, package_id) do
    # `authorize?: false`: quem autoriza é a ação do pacote (`mark_paused`); a escrita na sessão é
    # cascata interna, como `CascadeToAttendances`. `tenant` mantém a GUC.
    # `set_pkg_hold` segue como cascata interna (`authorize?: false`): não é ação de `@write_actions`
    # (não tem policy própria) e não carrega nada do corpo do request — não há o que escalar.
    lifecycle(scope, package_id, [:agendado, :confirmado], :mark_paused, fn {appt, _att} ->
      {:ok, _held, notes} =
        Api.Scheduling.set_appointment_pkg_hold(appt, %{pkg_hold: true},
          tenant: scope.clinic_id,
          authorize?: false,
          return_notifications?: true
        )

      notes
    end)
  end

  @doc """
  **Cancela** o pacote (RN-25): cancela as sessões futuras (inclusive as seguradas por uma pausa
  anterior) e marca o pacote como `:cancelado`. Sessões passadas/concluídas/faltadas ficam como
  registro.

  O alvo é a **presença**, não o bloco — a mesma regra da massa (`Api.Packages.Bulk`). Antes daqui
  cancelava-se o bloco, e numa turma isso levava junto a sessão dos colegas: o `pkgOf` do protótipo
  vivo pela porta do ciclo de vida, enquanto a massa já o havia corrigido.
  """
  def cancel_package(%Api.Scope{} = scope, package_id) do
    lifecycle(scope, package_id, [:agendado, :confirmado], :mark_cancelled, fn alvo ->
      {:ok, notes} = Api.Packages.Bulk.cancelar_sessao(scope, alvo)
      notes
    end)
  end

  @doc """
  **Retoma** o pacote pausado (RN-24 corrigida / GAP-06): reprojeta as sessões seguradas **para o
  futuro**, nunca para as datas originais (o bug do protótipo, que devolvia sessões no passado).

  A reprojeção é **cancelar as seguradas e re-materializar o mesmo número a partir de hoje**, pela
  grade. Escolha deliberada sobre "mover no lugar": a exclusion constraint **não** isenta
  `pkg_hold`, então uma sessão segurada ainda ocupa o slot — mover em lote geraria conflito
  transitório quando um destino coincide com a origem ainda-não-movida de outra. Cancelar primeiro
  libera todos os slots; as canceladas ficam como registro do que a pausa interrompeu. Como sessão
  segurada é `:prevista` (não consome), `usadas` não muda — o que já fora concluído/faltado no
  passado permanece contado.

  O **cancelamento** e a reativação são atômicos (transação); a **re-materialização** é enfileirada
  no `Api.Packages.Materializer` (com `from`/`count`), como na criação — assim as sessões novas
  emitem os eventos de tempo real normalmente (não presas numa transação). O job é idempotente.
  """
  def resume_package(%Api.Scope{} = scope, package_id) do
    clinic_id = scope.clinic_id
    %{today: today} = Api.Scheduling.clinic_now(scope)

    result =
      in_clinic(scope, fn ->
        Api.Repo.transaction(fn ->
          pkg = get_package!(package_id, scope: scope)
          held = held_sessions(scope, clinic_id, package_id)

          cancel_notes =
            Enum.flat_map(held, fn appt ->
              {:ok, _c, notes} =
                Api.Scheduling.cancel_appointment_slot(appt, %{},
                  tenant: clinic_id,
                  authorize?: false,
                  return_notifications?: true
                )

              notes
            end)

          enqueue_reproject(pkg, clinic_id, today, length(held))

          {:ok, ativo, mark_notes} =
            mark_package_active(pkg, scope: scope, return_notifications?: true)

          {ativo, cancel_notes ++ mark_notes}
        end)
      end)

    case result do
      {:ok, {pkg, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, pkg}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_reproject(_pkg, _clinic_id, _today, 0), do: :ok

  defp enqueue_reproject(pkg, clinic_id, today, n) do
    %{
      package_id: pkg.id,
      clinic_id: clinic_id,
      forcar: false,
      from: Date.to_iso8601(today),
      count: n
    }
    |> Api.Packages.Materializer.new()
    |> Oban.insert!()
  end

  # As sessões seguradas do pacote — via `list_held_sessions`, que abre a porta `include_held` do
  # `HideHeld` (a preparation global as esconderia de qualquer leitura normal).
  #
  # **Cancelada fica de fora**: uma segurada que já foi cancelada (pela massa, ou por um
  # `cancel_package` anterior) não tem o que reprojetar, e tentar cancelá-la de novo fazia o
  # `resume_package` estourar com "transição indisponível a partir de cancelado" — 500 no botão
  # Retomar que a ficha oferece (bate-volta da Onda 3).
  defp held_sessions(scope, clinic_id, package_id) do
    ids =
      list_attendances_for_package(scope, package_id)
      |> Enum.map(& &1.appointment_id)

    Api.Scheduling.list_held_sessions(clinic_id, ids)
    |> Enum.reject(&(&1.status == :cancelado))
  end

  # Roda `fun` sobre cada sessão futura não-resolvida do pacote e vira o status do pacote, **tudo
  # numa transação** com a GUC de tenant (`in_clinic`, molde de `update_clinic_hours`). As
  # notificações das escritas são coletadas e emitidas **fora** da transação: o Ash não as despacha
  # de dentro de uma transação que ele não abriu (senão avisa "missed notifications").
  defp lifecycle(scope, package_id, statuses, mark, fun) do
    result =
      in_clinic(scope, fn ->
        Api.Repo.transaction(fn ->
          notes =
            scope
            |> future_sessions(package_id, statuses)
            |> Enum.flat_map(fun)

          {:ok, pkg, pkg_notes} =
            get_package!(package_id, scope: scope)
            |> apply_mark(mark, scope)

          {pkg, notes ++ pkg_notes}
        end)
      end)

    case result do
      {:ok, {pkg, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, pkg}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_mark(pkg, :mark_paused, scope),
    do: mark_package_paused(pkg, scope: scope, return_notifications?: true)

  defp apply_mark(pkg, :mark_cancelled, scope),
    do: mark_package_cancelled(pkg, scope: scope, return_notifications?: true)

  # Os **pares** `{appointment, attendance}` das sessões do pacote cujo dia local é hoje-ou-depois e
  # cujo status está na lista — o par, e não só o bloco, porque quem decide o efeito é a presença
  # (uma turma com colegas não pode ser cancelada inteira por causa de um pacote).
  #
  # Lê os blocos **incluindo os segurados** (`include_held`) — senão o `.appointment` de uma sessão
  # segurada por uma pausa anterior volta `nil` (HideHeld) e o cancelar (RN-25) estoura, deixando as
  # seguradas órfãs (bate-volta 2026-07-24).
  #
  # Presença **cancelada** fica de fora: ela já não é sessão de ninguém, e mantê-la na varredura
  # fazia o bloco dos colegas ser arrastado por um vínculo morto (bate-volta da Onda 3).
  defp future_sessions(scope, package_id, statuses) do
    %{today: today, timezone: tz} = Api.Scheduling.clinic_now(scope)

    por_bloco =
      list_attendances_for_package(scope, package_id)
      |> Enum.reject(&(&1.status == :cancelada))
      |> Map.new(&{&1.appointment_id, &1})

    Api.Scheduling.list_sessions_including_held(scope.clinic_id, Map.keys(por_bloco),
      load: [:attendances]
    )
    |> Enum.filter(fn appt ->
      appt.status in statuses and
        not Date.before?(Api.Scheduling.LocalTime.to_local_date(appt.starts_at, tz), today)
    end)
    |> Enum.map(&{&1, Map.fetch!(por_bloco, &1.id)})
  end

  defp list_attendances_for_package(scope, package_id) do
    Api.Scheduling.list_attendances!(
      scope: scope,
      query: [filter: [package_id: package_id]],
      load: [:appointment]
    )
  end

  @doc """
  Ajuste em massa das sessões do pacote (doc 41 etapa 3). Delega a `Api.Packages.Bulk` — ver lá a
  semântica por presença.
  """
  defdelegate bulk_adjust(scope, package_id, params), to: Api.Packages.Bulk, as: :adjust

  @doc """
  Cancelamento em massa das sessões do pacote (doc 41 etapa 3). Delega a `Api.Packages.Bulk`.
  """
  defdelegate bulk_cancel(scope, package_id, params), to: Api.Packages.Bulk, as: :cancel

  @doc """
  O `package_id` é um pacote **deste** paciente nesta clínica? (doc 41 etapa 2, contrato
  09 §3.1.1 ponto 2.)

  Pergunta de validação, não de exibição: `authorize?: false` de propósito — o recorte da A7
  esconderia do papel `profissional` o pacote de um paciente que não é dele, e a resposta viraria
  "não é do paciente" quando é. Quem decide se aquele ator pode escrever ali é a policy da ação.

  Abre a própria transação com a GUC (`with_clinic`), como `Api.Records.patients_outside_clinic/2`:
  sem ela a leitura volta vazia sob RLS no servidor real — e **passa** no `mix test`, onde o
  sandbox conecta como `postgres` (BYPASSRLS).
  """
  def package_of_patient?(package_id, patient_id, clinic_id)
      when is_binary(package_id) and is_binary(patient_id) and is_binary(clinic_id) do
    {:ok, found} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_packages!(
          tenant: clinic_id,
          authorize?: false,
          query: [filter: [id: package_id, patient_id: patient_id]]
        )
      end)

    found != []
  end

  def package_of_patient?(_package_id, _patient_id, _clinic_id), do: false

  @doc """
  Os pacotes de um paciente na clínica ativa, com os derivados carregados. Wrapper de leitura sob
  RLS (ADR-018) — o controller chama isto, não a code interface crua.
  """
  def list_patient_packages(%Api.Scope{} = scope, patient_id, opts \\ []) do
    in_clinic(scope, fn ->
      list_packages!(
        scope: scope,
        query: [filter: [patient_id: patient_id], sort: [inserted_at: :desc]],
        load: Keyword.get(opts, :load, [:usadas, :restantes, :acabando, :schedule])
      )
    end)
  end

  @doc """
  Lê um pacote com os derivados **sob RLS** (`in_clinic`). O controller chama isto para reapresentar
  o pacote depois de criar/transicionar: o `get_package!` cru rodaria fora da GUC de tenant e a RLS
  (ADR-018) o barraria com `""::uuid` no servidor real — invisível ao `mix test`, que roda como
  superusuário (a mesma armadilha de `list_patient_packages` e das escritas com `SetTenantGuc`).
  """
  def get_patient_package!(%Api.Scope{} = scope, id, opts \\ []) do
    in_clinic(scope, fn ->
      get_package!(id,
        scope: scope,
        load: Keyword.get(opts, :load, [:usadas, :restantes, :acabando, :schedule])
      )
    end)
  end
end
