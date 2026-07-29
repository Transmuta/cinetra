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
      define :mark_package_completed, action: :mark_completed
      define :set_package_total, action: :set_total
    end

    resource Api.Packages.PackageSchedule do
      define :get_package_schedule, action: :read, get_by: [:id]
      define :list_package_schedules, action: :read
      define :update_package_schedule, action: :update
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

    # Antes do `Preview`, e não depois: com um `professional_id` que não é desta clínica o preview
    # estourava `MatchError` em `availability_by_date/5` (`{:error, :professional_not_found}` sem
    # cláusula), o que virava **500** no controller em vez de uma recusa de fronteira.
    with :ok <- checar_profissional(scope, profissional_da_grade(params)),
         {:ok, previa} <- preview_series(scope, params),
         :ok <- gate(previa, forcar) do
      attrs = Map.merge(params, %{materialize?: true, forcar: forcar})
      create_package(attrs, scope: scope)
    end
  end

  # A grade chega do controller (`series_params`) com chaves de átomo; ausência é `nil`, e aí
  # `checar_profissional/2` deixa passar — quem recusa grade sem profissional é o próprio recurso
  # (`PackageSchedule.professional_id` é `allow_nil? false`).
  defp profissional_da_grade(%{grade: %{professional_id: id}}), do: id
  defp profissional_da_grade(_params), do: nil

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
    lifecycle(scope, package_id, [:agendado, :confirmado], :mark_paused, &segura(scope, &1))
  end

  # Segurar segue a regra por-presença de todo o resto do pacote (doc 43 §5c): **sozinho no bloco**,
  # segura o bloco (é a sessão dele); **acompanhado**, segura só a presença — pausar o pacote da
  # Maria não pode fazer o Pilates das terças sumir da agenda do João e da Ana, que foi o que o
  # bate-volta mediu (`bloco_visivel_depois: 0` com `participantes_do_bloco: 2`).
  defp segura(scope, {appt, att}) do
    if Api.Packages.Bulk.sozinho?(appt, att) do
      {:ok, _held, notes} =
        Api.Scheduling.set_appointment_pkg_hold(appt, %{pkg_hold: true},
          tenant: scope.clinic_id,
          authorize?: false,
          return_notifications?: true
        )

      notes
    else
      {:ok, _held, notes} =
        Api.Scheduling.set_attendance_pkg_hold(att, %{pkg_hold: true},
          tenant: scope.clinic_id,
          authorize?: false,
          return_notifications?: true
        )

      notes
    end
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
          held = held_targets(scope, package_id)

          # Cancelar pela MESMA decisão por-presença da massa: numa turma compartilhada, a sessão
          # que volta para a fila de reprojeção é a **dele** — o colega fica. Antes daqui a
          # retomada cancelava o bloco, o que arrastaria a turma junto (a irmã do achado de
          # `cancel_package`, doc 43 §5c).
          cancel_notes =
            Enum.flat_map(held, fn alvo ->
              {:ok, notes} = Api.Packages.Bulk.cancelar_sessao(scope, alvo)
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
    |> Api.Packages.Materializer.new(Api.Correlacao.opts())
    |> Oban.insert!()
  end

  # Os pares `{appointment, attendance}` **segurados** do pacote — o bloco segurado (sessão de um
  # só) ou a presença segurada (turma compartilhada, doc 43 §5c). Abre a porta `include_held` das
  # duas preparations, senão o pacote se esconde do que ele mesmo segurou.
  #
  # **Cancelada fica de fora**: uma segurada que já foi cancelada (pela massa, ou por um
  # `cancel_package` anterior) não tem o que reprojetar, e tentar cancelá-la de novo fazia o
  # `resume_package` estourar com "transição indisponível a partir de cancelado" — 500 no botão
  # Retomar que a ficha oferece (bate-volta da Onda 3).
  defp held_targets(scope, package_id) do
    por_bloco =
      list_attendances_for_package(scope, package_id)
      |> Enum.filter(&Api.Scheduling.Attendance.viva?/1)
      |> Map.new(&{&1.appointment_id, &1})

    Api.Scheduling.list_sessions_including_held(scope.clinic_id, Map.keys(por_bloco),
      load: [:attendances]
    )
    |> Enum.reject(&(&1.status == :cancelado))
    |> Enum.map(&{&1, Map.fetch!(por_bloco, &1.id)})
    |> Enum.filter(fn {appt, att} -> appt.pkg_hold or att.pkg_hold end)
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
      |> Enum.filter(&Api.Scheduling.Attendance.viva?/1)
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

  defp list_attendances_for_package(scope, package_id),
    do: Api.Scheduling.list_package_attendances(scope, package_id, load: [:appointment])

  @doc """
  **Arquiva** o pacote: marca `:concluido` e o tira da vista da ficha (o histórico da seção).

  É o **único** caminho até `:concluido` (D1, doc 69 §10). Nada fecha o pacote sozinho: `restantes`
  chegar a zero muda o que a tela mostra, não o estado. A decisão de que a série acabou é de quem
  atende — um pacote de 10 pode terminar com 9 concluídas e 1 devolvida por acordo, e um pacote com
  0 restantes pode ganhar sessão pelo `+`.

  Deliberadamente **sem gatilho automático**: escrever no pacote de dentro da transição de presença
  (que roda em rollup/lote, Onda 3) reabriria a corrida A-6 do doc 42.

  Recusa em dois casos:

    * `{:error, :status_invalido}` — pacote `:cancelado` (terminal) ou já `:concluido`;
    * `{:error, :sessoes_futuras}` — ainda há sessão de hoje em diante `:agendado`/`:confirmado`,
      **inclusive segurada** por uma pausa. Arquivar aqui deixaria sessão viva na agenda de um
      pacote fechado; o caminho é cancelar (ou concluir) o que sobrou antes.
  """
  def archive_package(%Api.Scope{} = scope, package_id) do
    {pkg, futuras} =
      in_clinic(scope, fn ->
        pkg = get_package!(package_id, scope: scope)
        {pkg, future_sessions(scope, package_id, [:agendado, :confirmado])}
      end)

    cond do
      pkg.status in [:cancelado, :concluido] ->
        {:error, :status_invalido}

      futuras != [] ->
        {:error, :sessoes_futuras}

      true ->
        # A escrita fica **fora** do `in_clinic`: a ação seta a própria GUC (`SetTenantGuc`), e
        # assim o Ash despacha as notificações na transação dele — sem o "missed notifications"
        # que aparece ao escrever dentro de uma transação que ele não abriu (ver `lifecycle/5`).
        mark_package_completed(pkg, scope: scope)
    end
  end

  @doc """
  **Soma uma sessão** ao pacote (ADR-011 / contrato 09:444). O `total` sobe 1 e a sessão nova é
  materializada na **próxima data da grade depois da última** já existente.

  É metade do troco do ADR-011 (que tirou a renovação em favor do total editável): sem isto, um
  pacote que acabou só podia ser "estendido" criando um segundo pacote, com contador zerado.

  Por **D4**: `:concluido` volta a `:ativo` (a série voltou a andar); `:cancelado` recusa com
  `{:error, :status_invalido}` — cancelar avisou o paciente e liberou a agenda, e desfazer isso por
  um `+` seria surpresa. O teto do recurso (120) recusa pelo próprio changeset.

  A materialização é **assíncrona** (o mesmo job da criação, com `from`/`count`), então a sessão
  aparece na agenda logo depois — a tela recarrega a ficha.
  """
  def add_session(%Api.Scope{} = scope, package_id) do
    pkg = in_clinic(scope, fn -> get_package!(package_id, scope: scope) end)

    if pkg.status == :cancelado do
      {:error, :status_invalido}
    else
      with {:ok, maior} <- set_package_total(pkg, %{total: pkg.total + 1}, scope: scope) do
        enqueue_from(maior, scope, proxima_ancora(scope, package_id), 1)
        {:ok, maior}
      end
    end
  end

  @doc """
  **Tira uma sessão** do pacote (ADR-011 / contrato 09:445): cancela a **última sessão futura ainda
  não consumida** e baixa o `total` em 1.

  Por **D3**, "futura" é literal: só alcança sessão cuja data (no fuso da clínica) é hoje ou depois.
  Uma sessão da semana passada que ninguém resolveu continua `:agendado`, mas é **passado** — apagá-la
  reescreveria histórico. Quando não há nenhuma futura, devolve `{:error, :sem_sessao_futura}` em vez
  de cancelar a de trás.

  Também não desce abaixo do que já foi consumido (`usadas`): o total é o que foi vendido, e o
  consumido já aconteceu.
  """
  def remove_session(%Api.Scope{} = scope, package_id) do
    pkg =
      in_clinic(scope, fn -> get_package!(package_id, scope: scope, load: [:usadas]) end)

    # `alvos/3` é a MESMA resolução de "futuras ainda não resolvidas" da massa e do ciclo de vida
    # (por presença, fuso da clínica) — a regra do recorte existe uma vez só.
    case Api.Packages.Bulk.alvos(scope, package_id, %{escopo: :todas}) do
      {:ok, [], _tz} ->
        {:error, :sem_sessao_futura}

      {:ok, alvos, _tz} ->
        if pkg.total - 1 < pkg.usadas do
          {:error, :abaixo_do_consumido}
        else
          {_appt, _att} = ultimo = Enum.max_by(alvos, fn {appt, _att} -> appt.starts_at end)
          {:ok, _notes} = Api.Packages.Bulk.cancelar_sessao(scope, ultimo)
          set_package_total(pkg, %{total: pkg.total - 1}, scope: scope)
        end

      erro ->
        erro
    end
  end

  @doc """
  **Ajusta a grade** do pacote (contrato 09:441 / `pkgSaveGrade` do protótipo): grava a grade nova
  (dias, horários, profissional) e **remarca as sessões futuras** para ela.

  A remarcação é a mesma forma da retomada (GAP-06): cancelar as futuras não resolvidas e
  re-materializar a mesma quantidade a partir de hoje, pela grade nova. Cancelar primeiro libera os
  slots — mover em lote geraria conflito transitório quando um destino coincide com a origem
  ainda-não-movida de outra (a exclusion constraint não perdoa).

  O que já aconteceu **não** se toca: `usadas` não muda, e sessão passada/concluída/faltada fica
  como registro.

  Recusa com `{:error, :status_invalido}` fora de `:ativo` — num pacote **pausado** as sessões estão
  seguradas e a retomada já reprojeta tudo; ajustar por baixo produziria duas reprojeções brigando.
  """
  def adjust_grade(%Api.Scope{} = scope, package_id, %{} = grade) do
    %{today: today} = Api.Scheduling.clinic_now(scope)

    {pkg, futuras} =
      in_clinic(scope, fn ->
        pkg = get_package!(package_id, scope: scope, load: [:schedule])
        {pkg, future_sessions(scope, package_id, [:agendado, :confirmado])}
      end)

    cond do
      pkg.status != :ativo ->
        {:error, :status_invalido}

      is_nil(pkg.schedule) ->
        {:error, :sem_grade}

      true ->
        # A ordem aqui é a correção de um defeito medido, não estilo: `checar_profissional/2` vem
        # **antes** da escrita da grade e do cancelamento das futuras. Invertido — que era o
        # código anterior — a recusa chegava tarde: as futuras já estavam canceladas e a
        # re-materialização morria em silêncio no job, deixando o pacote vendido com N sessões e
        # zero na agenda. Ver `Api.Packages.LifecycleTest`, "recusa profissional …".
        with {:ok, atrs} <- grade_params(grade),
             :ok <- checar_profissional(scope, profissional_efetivo(atrs, pkg.schedule)),
             {:ok, _grade} <- update_package_schedule(pkg.schedule, atrs, scope: scope) do
          Enum.each(futuras, fn alvo ->
            {:ok, _notes} = Api.Packages.Bulk.cancelar_sessao(scope, alvo)
          end)

          enqueue_from(pkg, scope, today, length(futuras))
          {:ok, get_patient_package!(scope, package_id)}
        end
    end
  end

  # A grade que chega da fronteira precisa ter dia e horário; o `Series` recusaria depois, mas aí o
  # estrago (sessões canceladas) já estaria feito.
  defp grade_params(%{dows: dows, horarios: horarios} = grade)
       when is_list(dows) and is_map(horarios) do
    cond do
      dows == [] ->
        {:error, :grade_vazia}

      Enum.any?(dows, &(!is_integer(&1) or &1 < 0 or &1 > 6)) ->
        {:error, :dia_invalido}

      Enum.any?(dows, &(!Map.has_key?(horarios, to_string(&1)))) ->
        {:error, :horario_faltando}

      true ->
        {:ok,
         %{dows: dows, horarios: horarios}
         |> then(fn atrs ->
           case Map.get(grade, :professional_id) do
             nil -> atrs
             id -> Map.put(atrs, :professional_id, id)
           end
         end)}
    end
  end

  defp grade_params(_), do: {:error, :grade_invalida}

  # O profissional que a grade vai USAR: o do corpo quando veio, senão o que já estava lá. É o
  # efetivo que importa — sem `professional_id` no corpo a grade mantém o antigo, e o antigo pode
  # ter sido arquivado desde a última vez.
  defp profissional_efetivo(atrs, schedule),
    do: atrs[:professional_id] || schedule.professional_id

  # O profissional da grade precisa existir **nesta clínica** e estar ativo.
  #
  # É a mesma pergunta que `ReferencesActive` faz ao criar o bloco, feita mais cedo e num lugar
  # onde a resposta ainda pode evitar estrago. Duas razões para não bastar a validação de lá:
  #
  #   * `adjust_grade` cancela as futuras **antes** de materializar as novas — a recusa que vem do
  #     job chega depois do dano, e ainda por cima em silêncio (`Materializer.create_sessions`
  #     descarta o erro do `Enum.each`);
  #   * `Api.Directory.professional_inactive?/2` é uma pergunta NEGATIVA: ela responde `false` para
  #     um id que não existe nesta clínica, então uma referência de outro tenant passa por ela como
  #     se estivesse tudo bem. Aqui a pergunta é positiva — "existe e está ativo?" —, que é a que
  #     fecha o caso cross-tenant (a FK é global, ADR-017).
  defp checar_profissional(_scope, nil), do: :ok

  defp checar_profissional(%Api.Scope{} = scope, professional_id)
       when is_binary(professional_id) do
    in_clinic(scope, fn ->
      case Api.Directory.get_professional(professional_id,
             tenant: scope.clinic_id,
             authorize?: false,
             not_found_error?: false
           ) do
        {:ok, %Api.Directory.Professional{ativo: true}} -> :ok
        {:ok, %Api.Directory.Professional{}} -> {:error, :profissional_inativo}
        _ -> {:error, :profissional_invalido}
      end
    end)
  end

  defp checar_profissional(_scope, _outro), do: {:error, :profissional_invalido}

  # A âncora do `+1`: o dia seguinte à última sessão do pacote (a grade decide a data de fato). Sem
  # sessão nenhuma, hoje — o job projeta a primeira ocorrência daí para a frente.
  defp proxima_ancora(scope, package_id) do
    %{today: today, timezone: tz} = Api.Scheduling.clinic_now(scope)

    Api.Scheduling.list_package_attendances(scope, package_id)
    |> Enum.map(& &1.session_starts_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        today

      instantes ->
        instantes
        |> Enum.max(DateTime)
        |> Api.Scheduling.LocalTime.to_local_date(tz)
        |> Date.add(1)
    end
  end

  defp enqueue_from(_pkg, _scope, _from, 0), do: :ok

  defp enqueue_from(pkg, scope, %Date{} = from, count) do
    %{
      package_id: pkg.id,
      clinic_id: scope.clinic_id,
      forcar: false,
      from: Date.to_iso8601(from),
      count: count
    }
    |> Api.Packages.Materializer.new(Api.Correlacao.opts())
    |> Oban.insert!()

    :ok
  end

  @doc """
  As **sessões do pacote** com o estado de cada uma — a trilha da ficha (`pkgSessions` do protótipo,
  [`:386`](../../../interface/Movimento.dc.html#L386)).

  Lê por **presença** (é ela que carrega o vínculo com o pacote e o desfecho de cada participante),
  incluindo as **seguradas** por uma pausa — que a leitura normal esconde (RN-05) e que, escondidas,
  fariam a trilha de um pacote pausado parecer vazia.

  O estado de cada sessão:

    * `:concluida` / `:falta` — desfecho registrado;
    * `:segurada` — o pacote está pausado e ela saiu da agenda;
    * `:proxima` — a primeira ainda por acontecer, de hoje em diante;
    * `:agendada` — as demais previstas.

  **Cancelada fica de fora.** A trilha é a série, não o cemitério dela: o `−1`, a massa e a
  reprojeção da retomada cancelam sessões, e mantê-las faria o cartão desenhar oito bolinhas num
  pacote de seis — o desenho discordando do contador ao lado. Mesmo filtro do protótipo
  ([`:387`](../../../interface/Movimento.dc.html#L387)).
  """
  def list_sessions(%Api.Scope{} = scope, package_id) do
    pkg = in_clinic(scope, fn -> get_package!(package_id, scope: scope) end)

    scope
    |> Api.Scheduling.list_package_attendances(package_id)
    |> trilha(scope.now, pkg.status == :pausado)
  end

  @doc """
  As trilhas de **vários** pacotes numa leitura só — o que o cartão da ficha desenha (as bolinhas)
  para cada pacote do paciente.

  Uma query para todos, e não `list_sessions/2` num laço: a ficha mostra os pacotes atuais **e** o
  histórico, e uma leitura por pacote transformaria a abertura da ficha num N+1 que cresce com o
  tempo de casa do paciente.
  """
  def sessions_by_package(%Api.Scope{} = scope, packages) when is_list(packages) do
    package_ids = Enum.map(packages, & &1.id)
    pausados = MapSet.new(packages, &{&1.id, &1.status == :pausado})
    pausado? = fn id -> MapSet.member?(pausados, {id, true}) end

    if package_ids == [] do
      %{}
    else
      query =
        Api.Scheduling.Attendance
        |> Ash.Query.set_context(%{include_held: true})
        |> Ash.Query.filter(package_id in ^package_ids)

      in_clinic(scope, fn ->
        Api.Scheduling.list_attendances!(scope: scope, query: query)
      end)
      |> Enum.group_by(& &1.package_id)
      |> Map.new(fn {package_id, attendances} ->
        {package_id, trilha(attendances, scope.now, pausado?.(package_id))}
      end)
    end
  end

  # A trilha de um conjunto de presenças: descarta as canceladas, ordena, acha a próxima e
  # classifica cada uma.
  #
  # `pausado?` vem do PACOTE, e não dá para deduzi-lo da presença: numa sessão individual quem
  # recebe o `pkg_hold` é o **bloco** (é a sessão dele), e a presença fica intacta — a trilha de um
  # pacote pausado se apresentava como "Próxima/Agendada" enquanto as sessões não estavam na agenda
  # de ninguém. Na turma o hold é da presença, e o `att.pkg_hold` abaixo dá conta.
  defp trilha(attendances, agora, pausado?) do
    sessoes =
      attendances
      |> Enum.reject(&(is_nil(&1.session_starts_at) or &1.status == :cancelada))
      |> Enum.sort_by(& &1.session_starts_at, DateTime)

    proxima =
      if pausado? do
        nil
      else
        Enum.find(sessoes, fn att ->
          att.status == :prevista and not att.pkg_hold and
            not DateTime.before?(att.session_starts_at, agora)
        end)
      end

    Enum.map(sessoes, fn att ->
      %{
        attendance_id: att.id,
        appointment_id: att.appointment_id,
        starts_at: att.session_starts_at,
        estado: estado_da_sessao(att, proxima, pausado?)
      }
    end)
  end

  defp estado_da_sessao(%{status: :concluida}, _proxima, _pausado?), do: :concluida
  defp estado_da_sessao(%{status: :faltou}, _proxima, _pausado?), do: :falta
  defp estado_da_sessao(%{pkg_hold: true}, _proxima, _pausado?), do: :segurada
  defp estado_da_sessao(_att, _proxima, true), do: :segurada
  defp estado_da_sessao(%{id: id}, %{id: id}, _pausado?), do: :proxima
  defp estado_da_sessao(_att, _proxima, _pausado?), do: :agendada

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
