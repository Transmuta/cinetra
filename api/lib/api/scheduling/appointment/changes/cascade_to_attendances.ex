defmodule Api.Scheduling.Appointment.Changes.CascadeToAttendances do
  @moduledoc """
  Propaga a transição do bloco para as `Attendance` dele (Entrega 4).

  O status de ciclo de vida é decidido no **bloco** (o grid "Mudar status" do drawer age sobre
  o agendamento, fiel ao `setStatus` do protótipo [`:1032`]), mas quem alimenta o agregado
  `Patient.faltas` é a **presença por participante** (`Attendance.status`), porque presença é
  por pessoa (D10/D11) — um bloco pode estar `:concluido` com um participante `:faltou`. Manter
  as duas coisas em sincronia é o que faz o contador de faltas do paciente se mexer, em vez de
  ficar preso no valor do seed (o bug que o protótipo tem: `p.faltas` mantido na mão, [`:1041`]).

  Roda como `after_action` dentro da transação da própria ação, então cada `Attendance` gera
  sua própria linha de trilha ("quem marcou faltou") e cada escrita passa pelo `SetTenantGuc`
  da ação de `Attendance` — a GUC cai no lugar sob RLS.

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
        |> Ash.load!([:attendances], authorize?: false, tenant: cs.tenant)
        |> Map.get(:attendances, [])
        |> Enum.map(fn attendance ->
          Ash.update!(attendance, input,
            action: :transition,
            authorize?: false,
            tenant: cs.tenant,
            actor: context.actor
          )
        end)

      # As presenças **já atualizadas** voltam penduradas no bloco (D-J). O `Ash.update!` devolve
      # cada uma; jogá-las fora obrigava `Api.Scheduling.transition_appointment/5` a reler tudo
      # numa transação nova, depois do commit — um round-trip inteiro para reconstruir o que
      # acabara de sair daqui. `Enum.map` no lugar de `Enum.each` é literalmente a diferença.
      {:ok, %{appointment | attendances: atualizadas}}
    end)
  end

  defp build_input(changeset, opts) do
    %{}
    |> maybe_put(:status, Keyword.get(opts, :status))
    |> maybe_reset(Keyword.get(opts, :reset_justificada?, false))
    |> maybe_justify(changeset, Keyword.get(opts, :justify_from))
  end

  defp maybe_put(input, _key, nil), do: input
  defp maybe_put(input, key, value), do: Map.put(input, key, value)

  defp maybe_reset(input, true), do: Map.put(input, :falta_justificada, false)
  defp maybe_reset(input, _false), do: input

  defp maybe_justify(input, _changeset, nil), do: input

  defp maybe_justify(input, changeset, argument) do
    Map.put(input, :falta_justificada, !!Ash.Changeset.get_argument(changeset, argument))
  end
end
