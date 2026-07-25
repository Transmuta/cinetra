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

  import Api.Tenancy, only: [in_clinic: 2]

  alias Api.Scheduling
  alias Api.Scheduling.LocalTime

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
      run(scope, alvos, &cancel_one(scope, &1))
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
         {:ok, alvos, tz} <- targets(scope, package_id, params) do
      run(scope, alvos, &adjust_one(scope, &1, plano, tz, package_id))
    end
  end

  # ---- alvos ----

  defp targets(scope, package_id, params) do
    with {:ok, escopo} <- escopo(params),
         :ok <- pacote_existe(scope, package_id) do
      %{today: today, timezone: tz} = Scheduling.clinic_now(scope)

      by_appointment =
        scope
        |> attendances(package_id)
        |> Enum.reject(&(&1.status == :cancelada))
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

  defp attendances(scope, package_id) do
    in_clinic(scope, fn ->
      Scheduling.list_attendances!(scope: scope, query: [filter: [package_id: package_id]])
    end)
  end

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
  def cancelar_sessao(%Api.Scope{} = scope, {_appt, _att} = alvo), do: cancel_one(scope, alvo)

  @doc """
  Os alvos (`[{appointment, attendance}]`) do escopo pedido — a resolução única de "as sessões
  futuras ainda não resolvidas deste pacote", compartilhada com o ciclo de vida.
  """
  def alvos(%Api.Scope{} = scope, package_id, params), do: targets(scope, package_id, params)

  defp cancel_one(scope, {appt, att}) do
    if sozinho?(appt, att) do
      write(fn ->
        Scheduling.cancel_appointment_slot(appt, %{}, opts(scope))
      end)
    else
      write(fn ->
        Scheduling.remove_appointment_participants(
          appt,
          %{patient_ids: [att.patient_id]},
          opts(scope)
        )
      end)
    end
  end

  defp adjust_one(scope, {appt, att}, plano, tz, package_id) do
    starts_at = novo_starts_at(appt, plano, tz)
    professional_id = plano.professional_id || appt.professional_id

    if sozinho?(appt, att) do
      write(fn ->
        Scheduling.reschedule_appointment_slot(
          appt,
          # `encaixe` só entra quando `forcar`: mandar `false` **reclassificaria** um bloco que já
          # era encaixe (o argumento nulo é que preserva — ver `SetEncaixeIfGiven`).
          remarcacao(starts_at, professional_id, plano.forcar),
          opts(scope)
        )
      end)
    else
      destaca_e_reinsere(scope, appt, att, starts_at, professional_id, plano, package_id)
    end
  end

  defp destaca_e_reinsere(scope, appt, att, starts_at, professional_id, plano, package_id) do
    with {:ok, saida} <-
           write(fn ->
             Scheduling.remove_appointment_participants(
               appt,
               %{patient_ids: [att.patient_id]},
               opts(scope)
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
               opts(scope)
             )
           end) do
      {:ok, saida ++ entrada}
    end
  end

  defp remarcacao(starts_at, professional_id, true),
    do: %{starts_at: starts_at, professional_id: professional_id, encaixe: true}

  defp remarcacao(starts_at, professional_id, _forcar),
    do: %{starts_at: starts_at, professional_id: professional_id}

  # O bloco é só desta presença? Então mexer no bloco é mexer na sessão dela — e nada mais.
  defp sozinho?(%{attendances: attendances}, att) when is_list(attendances) do
    attendances
    |> Enum.reject(&(&1.status == :cancelada))
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
  defp opts(scope), do: [scope: scope, return_notifications?: true]

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
           forcar: truthy?(get(params, :forcar))
         }}
    end
  end

  defp quando(params, flag, campo) do
    if truthy?(get(params, flag)), do: get(params, campo)
  end

  defp hhmm?(valor) when is_binary(valor),
    do: match?({:ok, _}, Time.from_iso8601(valor <> ":00"))

  defp hhmm?(_valor), do: false

  defp truthy?(valor), do: valor in [true, "true"]

  defp get(params, key),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key)))
end
