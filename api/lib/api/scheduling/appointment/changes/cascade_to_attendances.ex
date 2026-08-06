defmodule Api.Scheduling.Appointment.Changes.CascadeToAttendances do
  @moduledoc """
  Propaga a transição do bloco para as `Attendance` dele (Entrega 4).

  O status de ciclo de vida é decidido no **bloco** (o grid "Mudar status" do drawer age sobre
  o agendamento, fiel ao `setStatus` do protótipo [`:1032`]), mas quem alimenta o agregado
  `Patient.faltas` é a **presença por participante** (`Attendance.status`), porque presença é
  por pessoa (D10/D11) — um bloco pode estar `:concluido` com um participante `:faltou`. Manter
  as duas coisas em sincronia é o que faz o contador de faltas do paciente se mexer, em vez de
  ficar preso no valor do seed (o bug que o protótipo tem: `p.faltas` mantido na mão, [`:1041`]).

  Roda como `after_action` dentro da transação da própria ação, e cada escrita passa pelo
  `SetTenantGuc` da ação de `Attendance` — a GUC cai no lugar sob RLS.

  ## Não deixa linha na trilha, e é decisão

  Quem decidiu foi o BLOCO: "Cancelou o agendamento" já conta o fato, e a linha do enriquecimento
  ainda mostra quem estava nele. As presenças aqui só refletem — e escreviam uma linha CADA,
  "Alterou a presença de Fulano: Prevista → Cancelada", no mesmo segundo. Numa turma de quatro
  eram cinco linhas para um clique. Daí o `audit_cascade` no contexto de cada escrita, que
  `Api.Audit.Capture` lê.

  O caminho inverso continua rendendo linha: quando é a PRESENÇA que decide (faltou, entrou, saiu),
  é ela que conta, e quem cala é o rollup do bloco (`Attendance.Changes.RollupBlockStatus`).

  Opções:

    * `status:` — o `AttendanceStatus` alvo (`:concluida` | `:faltou` | `:cancelada` | `:prevista`);
    * `reset_justificada?:` — quando `true`, zera `falta_justificada` junto (é o caso de reabrir);
    * `justify_from:` — nome do **argumento** booleano cujo valor vai para `falta_justificada`
      (o caso de justificar/desjustificar a falta, que não mexe no status).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn cs, appointment ->
      input = build_input(cs, opts)

      atualizadas =
        appointment
        |> Ash.load!([attendances: attendances_query()], authorize?: false, tenant: cs.tenant)
        |> Map.get(:attendances, [])
        |> Enum.map(fn attendance ->
          Ash.update!(attendance, input,
            action: :transition,
            authorize?: false,
            tenant: cs.tenant,
            actor: context.actor,
            context: %{audit_cascade: true}
          )
        end)

      # As presenças **já atualizadas** voltam penduradas no bloco (D-J). O `Ash.update!` devolve
      # cada uma; jogá-las fora obrigava `Api.Scheduling.transition_appointment/5` a reler tudo
      # numa transação nova, depois do commit — um round-trip inteiro para reconstruir o que
      # acabara de sair daqui. `Enum.map` no lugar de `Enum.each` é literalmente a diferença.
      {:ok, %{appointment | attendances: atualizadas}}
    end)
  end

  # `include_held` porque presença **segurada** por pausa de pacote (doc 43 §5c) continua sendo
  # presença do bloco — está escondida da leitura normal pela preparation global
  # `HideHeldAttendances`, não removida. Sem a porta, cancelar o bloco não a alcançava: ela ficava
  # `:prevista` pendurada num bloco `:cancelado`, e o `resume_package` também não a recuperava
  # (`held_targets/2` rejeita bloco cancelado). A sessão paga sumia do pacote (doc 96, B-1).
  #
  # É a mesma porta que a cascata irmã `RemoveParticipants` já abria — as duas precisam enxergar
  # o mesmo conjunto, e a assimetria entre elas era o bug.
  defp attendances_query do
    Ash.Query.set_context(Api.Scheduling.Attendance, %{include_held: true})
  end

  defp build_input(changeset, opts) do
    %{}
    |> maybe_put(:status, Keyword.get(opts, :status))
    |> maybe_reset(Keyword.get(opts, :reset_justificada?, false))
    |> maybe_justify(changeset, Keyword.get(opts, :justify_from))
  end

  defp maybe_put(input, _key, nil), do: input
  defp maybe_put(input, key, value), do: Map.put(input, key, value)

  # Reabrir desfaz o desfecho inteiro, não só o status: a justificativa e o **motivo** da falta
  # descrevem algo que deixou de ter acontecido. Deixar o motivo para trás era o que fazia uma
  # presença `:prevista` carregar "não avisou" — e o `reopen_attendance` (por participante) já
  # limpava os dois, então as duas portas discordavam sobre o mesmo desfecho.
  defp maybe_reset(input, true),
    do: input |> Map.put(:falta_justificada, false) |> Map.put(:motivo, nil)

  defp maybe_reset(input, _false), do: input

  defp maybe_justify(input, _changeset, nil), do: input

  defp maybe_justify(input, changeset, argument) do
    Map.put(input, :falta_justificada, !!Ash.Changeset.get_argument(changeset, argument))
  end
end
