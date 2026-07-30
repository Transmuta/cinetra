defmodule Api.Packages.Bulk do
  @moduledoc """
  Ajuste e cancelamento **em massa** de um pacote (doc 41 etapa 3; contrato
  [`09 §3.1.1` ponto 3] e §3.4): `applyMassaPacote`/`cancelarMassaPacote` do protótipo, com a
  correção que o contrato cobrou.

  ## O alvo é a PRESENÇA, não o bloco

  No protótipo a massa operava sobre o `appointment`. Numa clínica de Pilates isso significa que
  cancelar o pacote da Maria cancela a turma inteira — a sessão do João e da Ana junto. Aqui o
  escopo resolve para o conjunto de `Attendance` com aquele `package_id`, e o efeito por presença
  depende de quem mais está no bloco:

    * **sozinho no bloco** (o caso individual, e a turma que só tem o dono do pacote) — o bloco é a
      sessão dele: cancelar cancela o bloco; ajustar **remarca o bloco no lugar**, preservando id,
      trilha e o que o cliente tem em tela;
    * **acompanhado** — mexe-se só na presença: cancelar a **remove** do bloco (os colegas ficam);
      ajustar a **destaca** do bloco antigo e a **reinsere** no destino, fundindo numa turma que já
      exista lá ou criando bloco novo. É o `join`/`push` da materialização, agora por presença.

  ## O recorte de tempo é o mesmo de pausar/cancelar o pacote

  Só sessões **futuras e ainda não resolvidas** (`:agendado`/`:confirmado`, dia local hoje ou
  depois). Passado, concluído, faltado e cancelado são registro — massa não reescreve histórico.
  As **seguradas** por uma pausa entram (o `include_held` de `list_sessions_including_held/2`):
  são sessões do pacote que ainda vão acontecer, e deixá-las de fora repetiria o bug das órfãs
  (bate-volta 2026-07-24).

  ## Tudo ou nada

  As escritas correm numa transação só: um conflito no destino da terceira sessão desfaz as duas
  primeiras. Massa aplicada pela metade é pior que massa recusada — ninguém sabe onde parou, e o
  desfazer é manual, sessão por sessão.

  Quem aborta, na prática, é o **próprio Ash**: a ação que falha chama `Repo.rollback(changeset)`
  na transação que ele não abriu (é o efeito que o moduledoc de `Api.Tenancy` avisa), então o
  `rollback/1` explícito do `run/3` é só a rede para uma falha que volte sem abortar. O que importa
  é o que sai daqui: `{:error, %Ash.Error.Invalid{}}`, normalizado a partir do changeset cru — sem
  isso a fronteira devolveria **400** para o que é um 422 de conflito.
  """

  import Api.Params, only: [get: 2, truthy?: 2]
  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query
  require Logger

  alias Api.Scheduling
  alias Api.Scheduling.Attendance
  alias Api.Scheduling.LocalTime
  alias Api.Scheduling.Warm

  @escopos ~w(esta proximas todas)a
  @vivas [:agendado, :confirmado]

  @doc """
  Cancela o escopo de sessões do pacote. `params`: `%{escopo: :esta | :proximas | :todas,
  appointment_id: id}` — `appointment_id` é a sessão de referência, obrigatória em `:esta` e
  `:proximas`.

  Devolve `{:ok, %{afetadas: n}}` · `{:error, :not_found}` (referência que não é do pacote) ·
  `{:error, motivo}` de escrita.
  """
  def cancel(%Api.Scope{} = scope, package_id, params) do
    with {:ok, alvos, _tz} <- targets(scope, package_id, params) do
      case run(scope, alvos, &cancel_one(scope, &1, nil)) do
        {:ok, %{afetadas: afetadas} = resultado} ->
          avisa(scope, package_id, alvos, nil, :pacote_cancelado, afetadas)
          {:ok, resultado}

        erro ->
          erro
      end
    end
  end

  @doc """
  Muda profissional e/ou horário do escopo. Além do escopo, `params` carrega os campos do
  `applyMassaPacote`: `aplicar_profissional`/`professional_id` e `aplicar_horario`/`hhmm` (hora
  local da clínica; a **data** de cada sessão não muda), mais `forcar` — o "agendar mesmo assim"
  da criação, que vira `encaixe` na reinserção.

  `{:error, :nada_a_aplicar}` quando nenhum dos dois foi pedido: sem isso a massa varreria a série
  inteira para reescrever cada sessão com os próprios valores.
  """
  def adjust(%Api.Scope{} = scope, package_id, params) do
    with {:ok, plano} <- plan(params),
         {:ok, escopo} <- escopo(params),
         {:ok, todos, tz} <- targets(scope, package_id, params) do
      # Sessão **segurada** por uma pausa fica de fora do ajuste (doc 43 §5c): não há horário a
      # remarcar no que está parado, e a retomada reprojeta tudo a partir de hoje de qualquer
      # forma. Diferente do cancelar, que precisa alcançá-las (senão ficam órfãs, RN-25).
      alvos = Enum.reject(todos, &segurado?/1)
      warm = warm(scope, alvos, plano, tz, package_id)

      case run(scope, alvos, &adjust_one(scope, &1, plano, tz, package_id, warm)) do
        {:ok, %{afetadas: afetadas} = resultado} ->
          sincroniza_grade(scope, package_id, escopo, plano, afetadas)
          avisa(scope, package_id, alvos, plano, :pacote_remarcado, afetadas)
          {:ok, resultado}

        erro ->
          erro
      end
    end
  end

  # D2 (doc 69 §10): escopo `todas` é "mudei o pacote inteiro" — a **grade** acompanha. Escopos
  # `esta`/`proximas` são remarcação pontual e não mexem nela.
  #
  # Sem isto a grade guardada envelhecia calada, e é ela que o `Materializer` lê para reprojetar:
  # pausar+retomar depois de uma massa devolvia as sessões no horário/profissional velhos (achado
  # §6.2 do doc 69). O mesmo vale para qualquer materialização futura (`+1`, ajuste de grade).
  #
  # Roda **depois do commit** da massa, como o `avisa/6`: falhar aqui não pode desfazer sessões que
  # já se moveram. Uma falha vira log — a inconsistência é o estado anterior a este conserto, não
  # um regresso.
  defp sincroniza_grade(_scope, _package_id, _escopo, _plano, 0), do: :ok
  defp sincroniza_grade(_scope, _package_id, escopo, _plano, _n) when escopo != :todas, do: :ok

  defp sincroniza_grade(scope, package_id, :todas, plano, _afetadas) do
    # Lê a **grade** direto, não o pacote com `load: [:schedule]`: o teto de queries da massa
    # (`bulk_queries_test`) prova que o invariante do pacote é lido no máximo 2× por massa, e
    # reler `packages` aqui furava justamente essa asserção — a que importa, porque é a que pega
    # leitura por sessão.
    grade =
      in_clinic(scope, fn ->
        Api.Packages.list_package_schedules!(
          scope: scope,
          query: [filter: [package_id: package_id], limit: 1]
        )
      end)
      |> List.first()

    with %{} = grade <- grade,
         attrs when attrs != %{} <- atributos_da_grade(grade, plano) do
      # A escrita fica fora do `in_clinic`: a ação seta a própria GUC (`SetTenantGuc`).
      case Api.Packages.update_package_schedule(grade, attrs, scope: scope) do
        {:ok, _} ->
          :ok

        {:error, erro} ->
          Logger.error("Grade do pacote #{package_id} não acompanhou a massa: #{inspect(erro)}")
          :ok
      end
    else
      _ -> :ok
    end
  end

  # O `hhmm` da massa vale para **todos** os dias da grade: a massa aplica um horário só a todas as
  # sessões do escopo, então guardar horário diferente por dia deixaria a grade descrevendo algo que
  # a série já não é.
  defp atributos_da_grade(grade, plano) do
    %{}
    |> then(fn attrs ->
      if plano.professional_id,
        do: Map.put(attrs, :professional_id, plano.professional_id),
        else: attrs
    end)
    |> then(fn attrs ->
      if plano.hhmm,
        do: Map.put(attrs, :horarios, Map.new(grade.dows, &{to_string(&1), plano.hhmm})),
        else: attrs
    end)
  end

  # UMA notificação de caixa por massa, em vez de uma por sessão (doc 43 §5b). As por-sessão são
  # suprimidas na origem pela marca `bulk_pacote` no contexto (ver `opts/2` e
  # `Api.Notifications.Notifier`); esta as substitui, com o número que o usuário quer ler.
  #
  # Roda **depois** do commit da massa, como todo fan-out (doc 31): notificação de escrita que a
  # transação ainda pode desfazer é notificação errada.
  defp avisa(_scope, _package_id, _alvos, _plano, _kind, 0), do: :ok

  defp avisa(scope, package_id, alvos, plano, kind, afetadas) do
    # O nome do pacote é lido **uma vez** e serve aos dois avisos. Antes eram duas leituras da
    # mesma linha, uma por aviso — o tipo de custo que só aparece quando alguém conta as queries.
    nome = nome_do_pacote(scope, package_id)

    avisa_a_caixa(scope, nome, alvos, plano, kind, afetadas)
    avisa_o_paciente(scope, package_id, nome, alvos, kind, afetadas)
  end

  # A caixa do **profissional** dono da coluna. Vale para as duas massas: até o bate-volta da fase
  # 2 (doc 66 §5) só o ajuste avisava, e cancelar um pacote de 40 sessões esvaziava a agenda de
  # alguém sem pôr uma linha na caixa dele.
  #
  # `plano` é nulo no cancelamento — não há profissional de destino a acrescentar, porque
  # cancelar não move ninguém de coluna.
  defp avisa_a_caixa(scope, nome, alvos, plano, kind, afetadas) do
    colunas =
      alvos
      |> Enum.map(fn {appt, _att} -> appt.professional_id end)
      |> then(&if(plano && plano.professional_id, do: [plano.professional_id | &1], else: &1))

    fanout(kind).(scope.clinic_id, colunas, nome, afetadas, scope.user)
  end

  defp fanout(:pacote_remarcado), do: &Api.Notifications.Fanout.package_bulk_adjusted/5
  defp fanout(:pacote_cancelado), do: &Api.Notifications.Fanout.package_bulk_canceled/5

  # UMA mensagem ao paciente por massa, pelo mesmo motivo que a caixa recebe uma só (doc 43 §5b) —
  # e aqui o motivo é mais duro: são 40 mensagens de WhatsApp **pagas**, para o mesmo telefone, em
  # segundos. É assim que se perde um número por bloqueio (§9.1.1).
  #
  # As por-sessão já estão suprimidas na origem pela marca `bulk_pacote` (`Api.Messaging.Notifier`);
  # esta as substitui.
  #
  # **Um pacote é de um paciente só** (RN da Fatia 5), então "uma por massa" e "uma por paciente"
  # são a mesma coisa aqui.
  #
  # Tudo dentro de **um** `in_clinic`: cada um custa BEGIN + `set_config` + COMMIT, e a primeira
  # versão abria quatro (âncora, clínica, pacote, escrita) para fazer o trabalho de um. O teto de
  # queries da massa (`Api.Packages.BulkQueriesTest`) pegou.
  #
  # Roda **depois** do commit da massa: mensagem enviada não volta, e a transação ainda podia
  # desfazer tudo.
  defp avisa_o_paciente(scope, package_id, nome, alvos, kind, afetadas) do
    in_clinic(scope, fn ->
      with %{} = attendance <- ancora(scope, package_id, alvos),
           %{} = clinic <- Api.Accounts.get_clinic!(scope.clinic_id, authorize?: false) do
        Api.Messaging.Dispatch.dispatch(clinic, attendance, attendance.patient, kind,
          disparado_por_id: scope.user && scope.user.id,
          vars_extras: %{"quantas" => Api.Texto.sessoes(afetadas), "pacote" => nome}
        )
      end
    end)

    :ok
  rescue
    erro ->
      # Best-effort, como todo o resto da comunicação: a massa já foi aplicada e não pode cair
      # porque a mensagem não saiu.
      Logger.warning("aviso de massa (#{kind}) falhou: #{Exception.message(erro)}")
      :ok
  end

  # Onde a mensagem da massa se ancora — e é aqui que mora a sutileza que custou um bug.
  #
  # `Message` exige uma presença (doc 52 §3) e a FK é `ON DELETE CASCADE`. Só que a massa **mexe
  # nas presenças**, e de dois jeitos diferentes:
  #
  #   * ajustar uma sessão de turma **destaca e reinsere** — a presença antiga é destruída e nasce
  #     outra, com id novo. Ancorar no id que veio de `targets/3` antes da massa dá "record not
  #     found" (foi exatamente o que aconteceu na primeira versão);
  #   * cancelar uma sessão de turma **remove** a presença; a de sessão individual sobrevive (é o
  #     bloco que fica `:cancelado`).
  #
  # Duas queries, na ordem que acerta na primeira no caso comum:
  #
  #   1. as presenças **desta massa** que sobreviveram (individual, ajustado ou cancelado);
  #   2. qualquer presença do pacote (o caso do destaca-e-reinsere, que trocou os ids).
  #
  # A ordem é por `session_starts_at`, que a própria presença carrega (doc 43 §4) — ordenar pelo
  # bloco exigiria um join para escolher onde pendurar uma mensagem.
  #
  # Quando **nada** sobrevive — pacote inteiro de turma, cancelado — não há onde ancorar e a
  # mensagem não sai. Registrado no doc 65 §8 como limitação conhecida, com a saída (tornar a
  # âncora opcional) e o motivo de ela não ter sido tomada agora.
  defp ancora(scope, package_id, alvos) do
    ids = Enum.map(alvos, fn {_appt, att} -> att.id end)

    primeira_presenca(scope, Ash.Query.filter(Attendance, id in ^ids)) ||
      primeira_presenca(scope, Ash.Query.filter(Attendance, package_id == ^package_id))
  end

  defp primeira_presenca(scope, query) do
    query
    |> Ash.Query.set_tenant(scope.clinic_id)
    |> Ash.Query.sort(session_starts_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:patient)
    |> Ash.read_one!(authorize?: false)
  end

  defp nome_do_pacote(scope, package_id) do
    case in_clinic(scope, fn ->
           Api.Packages.get_package(package_id, scope: scope, not_found_error?: false)
         end) do
      {:ok, %{nome: nome}} -> nome
      _ -> "pacote"
    end
  end

  # O invariante do lote — clínica e expediente dos profissionais envolvidos na janela de datas que
  # a massa toca — lido **uma vez**, não uma vez por sessão (doc 43 §5a). Ver `Api.Scheduling.Warm`
  # para o que entra e por que é seguro. As datas não mudam num ajuste (só a hora), então a janela é
  # exatamente a das sessões alvo.
  defp warm(scope, alvos, plano, tz, package_id) do
    datas =
      Enum.map(alvos, fn {appt, _att} -> LocalTime.to_local_date(appt.starts_at, tz) end)

    profissionais =
      alvos
      |> Enum.map(fn {appt, _att} -> appt.professional_id end)
      |> then(&if(plano.professional_id, do: [plano.professional_id | &1], else: &1))

    Warm.build(
      scope.clinic_id,
      [
        profissionais: profissionais,
        de: Enum.min(datas, Date),
        ate: Enum.max(datas, Date)
      ] ++ catalogo(alvos, package_id)
    )
  end

  # Tipo, paciente e dono do pacote só interessam ao caminho da TURMA (`destaca_e_reinsere`, que
  # cria bloco e por isso valida entrada). Numa massa em que toda sessão é individual, a remarcação
  # não lê nenhum dos três — aquecê-los seria pagar leitura para economizar zero.
  defp catalogo(alvos, package_id) do
    if Enum.any?(alvos, fn {appt, att} -> not sozinho?(appt, att) end) do
      [
        tipos: Enum.map(alvos, fn {appt, _att} -> appt.appointment_type_id end),
        pacientes: Enum.map(alvos, fn {_appt, att} -> att.patient_id end),
        pacotes: Map.new(alvos, fn {_appt, att} -> {package_id, att.patient_id} end)
      ]
    else
      []
    end
  end

  defp segurado?({appt, att}), do: appt.pkg_hold or att.pkg_hold

  # ---- alvos ----

  defp targets(scope, package_id, params) do
    with {:ok, escopo} <- escopo(params),
         :ok <- pacote_existe(scope, package_id) do
      %{today: today, timezone: tz} = Scheduling.clinic_now(scope)

      by_appointment =
        scope
        |> attendances(package_id)
        |> Enum.filter(&Attendance.viva?/1)
        |> Map.new(&{&1.appointment_id, &1})

      sessoes =
        scope.clinic_id
        |> Scheduling.list_sessions_including_held(Map.keys(by_appointment), load: [:attendances])
        |> Enum.filter(&futura_nao_resolvida?(&1, today, tz))
        |> Enum.sort_by(& &1.starts_at, DateTime)

      with {:ok, escolhidas} <- apply_escopo(sessoes, escopo, get(params, :appointment_id)) do
        {:ok, Enum.map(escolhidas, &{&1, Map.fetch!(by_appointment, &1.id)}), tz}
      end
    end
  end

  # Pacote inexistente (ou de outra clínica) é **404**, não "ok, 0 afetadas": sem esta checagem a
  # massa sobre um id errado respondia sucesso silencioso. `uuid?/1` antes do read porque id
  # malformado faz o Ash estourar em vez de devolver `nil` — o mesmo 500 que a tela de auditoria
  # pegou (doc 32).
  defp pacote_existe(scope, package_id) do
    with true <- uuid?(package_id),
         {:ok, %{}} <-
           in_clinic(scope, fn ->
             Api.Packages.get_package(package_id, scope: scope, not_found_error?: false)
           end) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  defp attendances(scope, package_id),
    do: Scheduling.list_package_attendances(scope, package_id)

  defp futura_nao_resolvida?(appt, today, tz) do
    appt.status in @vivas and
      not Date.before?(LocalTime.to_local_date(appt.starts_at, tz), today)
  end

  defp apply_escopo(sessoes, :todas, _ref), do: {:ok, sessoes}

  defp apply_escopo(sessoes, escopo, ref_id) do
    case Enum.find(sessoes, &(&1.id == ref_id)) do
      nil ->
        {:error, :not_found}

      ref when escopo == :esta ->
        {:ok, [ref]}

      ref ->
        {:ok, Enum.filter(sessoes, &(DateTime.compare(&1.starts_at, ref.starts_at) != :lt))}
    end
  end

  defp escopo(params) do
    case get(params, :escopo) do
      nil -> {:ok, :todas}
      valor when valor in @escopos -> {:ok, valor}
      valor when is_binary(valor) -> escopo_from_string(valor)
      _ -> {:error, :escopo_invalido}
    end
  end

  defp escopo_from_string(valor) do
    case Enum.find(@escopos, &(Atom.to_string(&1) == valor)) do
      nil -> {:error, :escopo_invalido}
      escopo -> {:ok, escopo}
    end
  end

  # ---- execução ----

  # Uma transação para toda a massa, com a GUC de tenant setada no início (as escritas setam a
  # própria via `SetTenantGuc`, mas as leituras de dentro das ações dependem desta). As
  # notificações são coletadas e emitidas **fora**: o Ash não as despacha de dentro de uma
  # transação que ele não abriu.
  defp run(_scope, [], _fun), do: {:ok, %{afetadas: 0}}

  defp run(scope, alvos, fun) do
    resultado =
      Api.Repo.transaction(fn ->
        Api.Repo.set_clinic_guc(scope.clinic_id)

        Enum.reduce(alvos, [], fn alvo, notes ->
          case fun.(alvo) do
            {:ok, novas} -> notes ++ novas
            {:error, motivo} -> Api.Repo.rollback(motivo)
          end
        end)
      end)

    case resultado do
      {:ok, notes} ->
        Ash.Notifier.notify(notes)
        {:ok, %{afetadas: length(alvos)}}

      # Medido: quando a escrita interna falha (conflito de horário na exclusion constraint), quem
      # aborta é o **próprio Ash**, chamando `Repo.rollback(changeset)` na transação que ele não
      # abriu — o `rollback/1` acima nem chega a rodar, e o valor que sai daqui é um `Ash.Changeset`
      # cru. Sem esta normalização a fronteira cai no catch-all do `error_response/2` e devolve
      # **400** para o que é um 422 de conflito.
      {:error, %Ash.Changeset{} = changeset} ->
        {:error, Ash.Error.to_error_class(changeset)}

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  @doc """
  Cancela **uma** sessão do pacote pela regra por-presença — pública porque o ciclo de vida do
  pacote (`cancel_package`) usa exatamente a mesma decisão.

  Era o furo que o bate-volta mediu: `cancel_package` cancelava o **bloco**, e numa turma isso
  levava junto a sessão dos colegas (o `pkgOf` do protótipo, vivo pela porta do lado enquanto a
  massa já o havia corrigido). Duas regras opostas para "as sessões deste pacote", no mesmo
  domínio — agora é uma.
  """
  def cancelar_sessao(%Api.Scope{} = scope, {_appt, _att} = alvo),
    do: cancel_one(scope, alvo, nil)

  @doc """
  Os alvos (`[{appointment, attendance}]`) do escopo pedido — a resolução única de "as sessões
  futuras ainda não resolvidas deste pacote", compartilhada com o ciclo de vida.
  """
  def alvos(%Api.Scope{} = scope, package_id, params), do: targets(scope, package_id, params)

  defp cancel_one(scope, {appt, att}, warm) do
    if sozinho?(appt, att) do
      write(fn ->
        Scheduling.cancel_appointment_slot(appt, %{}, opts(scope, warm))
      end)
    else
      write(fn ->
        Scheduling.remove_appointment_participants(
          appt,
          %{patient_ids: [att.patient_id]},
          opts(scope, warm)
        )
      end)
    end
  end

  defp adjust_one(scope, {appt, att}, plano, tz, package_id, warm) do
    starts_at = novo_starts_at(appt, plano, tz)
    professional_id = plano.professional_id || appt.professional_id

    if sozinho?(appt, att) do
      write(fn ->
        Scheduling.reschedule_appointment_slot(
          appt,
          # `encaixe` só entra quando `forcar`: mandar `false` **reclassificaria** um bloco que já
          # era encaixe (o argumento nulo é que preserva — ver `SetEncaixeIfGiven`).
          remarcacao(starts_at, professional_id, plano.forcar),
          opts(scope, warm)
        )
      end)
    else
      destaca_e_reinsere(scope, appt, att, starts_at, professional_id, plano, package_id, warm)
    end
  end

  defp destaca_e_reinsere(scope, appt, att, starts_at, professional_id, plano, package_id, warm) do
    with {:ok, saida} <-
           write(fn ->
             Scheduling.remove_appointment_participants(
               appt,
               %{patient_ids: [att.patient_id]},
               opts(scope, warm)
             )
           end),
         {:ok, entrada} <-
           write(fn ->
             Scheduling.schedule_appointment(
               %{
                 starts_at: starts_at,
                 professional_id: professional_id,
                 appointment_type_id: appt.appointment_type_id,
                 patient_ids: [att.patient_id],
                 package_id: package_id,
                 # A sessão de origem pode ter duração fora do padrão do tipo e ser um encaixe —
                 # o bloco novo herda as duas. Sem isto, uma sessão de 80 min virava 50 em
                 # silêncio (o default do tipo) e o encaixe caía, medido no bate-volta da Onda 3.
                 duration_minutos: DateTime.diff(appt.ends_at, appt.starts_at, :minute),
                 encaixe: plano.forcar or appt.encaixe
               },
               opts(scope, warm)
             )
           end) do
      {:ok, saida ++ entrada}
    end
  end

  defp remarcacao(starts_at, professional_id, true),
    do: %{starts_at: starts_at, professional_id: professional_id, encaixe: true}

  defp remarcacao(starts_at, professional_id, _forcar),
    do: %{starts_at: starts_at, professional_id: professional_id}

  @doc """
  O bloco é só desta presença? Então mexer no bloco é mexer na sessão dela — e nada mais.

  Pública porque é a **decisão** que a massa e o ciclo de vida do pacote compartilham: cancelar
  (`cancel_package`), segurar (`pause_package`, doc 43 §5c) e ajustar respondem todos a esta mesma
  pergunta, e responder diferente em cada lugar é exatamente o bug do `pkgOf` do protótipo.
  """
  def sozinho?(%{attendances: attendances}, att) when is_list(attendances) do
    attendances
    |> Enum.filter(&Attendance.viva?/1)
    |> Enum.all?(&(&1.id == att.id))
  end

  defp novo_starts_at(appt, %{hhmm: nil}, _tz), do: appt.starts_at

  defp novo_starts_at(appt, %{hhmm: hhmm}, tz) do
    data = LocalTime.to_local_date(appt.starts_at, tz)
    {:ok, starts_at} = LocalTime.to_utc(data, hhmm, tz)
    starts_at
  end

  # As escritas passam pelo **autorizador**, com o actor do escopo — e não como cascata interna.
  #
  # Era `authorize?: false`, com o argumento de que "quem autoriza é a leitura do pacote que trouxe
  # o alvo". O bate-volta mediu o furo: `professional_id` e `forcar` vêm do CORPO do request e
  # chegavam intactos a `reschedule`/`schedule`, que nunca viam o ator. Um papel `profissional`
  # empurrava a própria sessão para a coluna de um colega (A7) e ligava `encaixe` (A9, que isenta a
  # exclusion constraint) — as duas coisas que o `Ash.can?` nega no caminho normal.
  #
  # A regra continua morando na policy: em vez de copiá-la aqui, a massa deixa de ser porta lateral.
  # `warm` (quando há) viaja no CONTEXTO da ação: é o invariante do lote já lido, e quem o consome
  # é `CheckAvailability`. Ver `Api.Scheduling.Warm`.
  # `bulk_pacote` marca as escritas como parte de um LOTE: o notifier da caixa as ignora, porque a
  # massa emite uma notificação agregada no fim (doc 43 §5b). O tempo real não é afetado — é outro
  # notifier, e a agenda aberta precisa de cada bloco.
  defp opts(scope, warm) do
    [scope: scope, return_notifications?: true, context: %{bulk_pacote: true}]
    |> Warm.opts(warm)
  end

  # Normaliza o retorno das escritas para `{:ok, notificações}` — o que o `run/3` acumula.
  defp write(fun) do
    case fun.() do
      {:ok, _record, notifications} -> {:ok, notifications}
      {:ok, _record} -> {:ok, []}
      {:error, motivo} -> {:error, motivo}
    end
  end

  # ---- plano do ajuste ----

  defp plan(params) do
    professional_id = quando(params, :aplicar_profissional, :professional_id)
    hhmm = quando(params, :aplicar_horario, :hhmm)

    cond do
      is_nil(professional_id) and is_nil(hhmm) ->
        {:error, :nada_a_aplicar}

      not is_nil(hhmm) and not hhmm?(hhmm) ->
        {:error, :horario_invalido}

      true ->
        {:ok,
         %{
           professional_id: professional_id,
           hhmm: hhmm,
           forcar: truthy?(params, :forcar)
         }}
    end
  end

  defp quando(params, flag, campo) do
    if truthy?(params, flag), do: get(params, campo)
  end

  defp hhmm?(valor) when is_binary(valor),
    do: match?({:ok, _}, Time.from_iso8601(valor <> ":00"))

  defp hhmm?(_valor), do: false
end
