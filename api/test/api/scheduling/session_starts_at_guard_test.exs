defmodule Api.Scheduling.SessionStartsAtGuardTest do
  @moduledoc """
  O guarda do **espelho** `Attendance.session_starts_at` (doc 43 §4).

  A coluna é uma cópia do `starts_at` do bloco, e denormalizar cobra manutenção: hoje só dois
  caminhos escrevem esse par — `ManageParticipants` (nasce com a presença) e `SyncSessionStartsAt`
  (a remarcação move as duas). O modo de falha de uma terceira porta é **silencioso**: o bloco anda,
  a presença guarda o instante velho, e o Histórico da ficha passa a ordenar e paginar pelo horário
  antigo — sem erro, sem log, só o dado errado na tela. O `allow_nil? false` pega o esquecimento na
  **criação**; não pega o esquecimento na **movimentação**.

  Este arquivo é o backstop dessa classe: qualquer ação de `Appointment` que aceite `starts_at`
  precisa carregar uma das duas changes. Uma ação nova sem ela falha aqui, na hora de escrevê-la —
  e não meses depois, na ficha de um paciente.
  """
  use Api.DataCase, async: false

  alias Api.Scheduling
  alias Api.Scheduling.Appointment
  alias Api.Scheduling.Appointment.Changes.ManageParticipants
  alias Api.Scheduling.Appointment.Changes.SyncSessionStartsAt

  @mantenedoras [ManageParticipants, SyncSessionStartsAt]

  @segunda ~D[2026-07-20]

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  describe "toda ação que mexe no horário do bloco mantém o espelho" do
    test "nenhuma ação aceita starts_at sem uma das changes que sincronizam a presença" do
      faltando =
        Appointment
        |> Ash.Resource.Info.actions()
        |> Enum.filter(&aceita_starts_at?/1)
        |> Enum.reject(&mantem_espelho?/1)
        |> Enum.map(& &1.name)

      assert faltando == [], """
      Estas ações de `Appointment` aceitam `starts_at` e não mantêm o espelho
      `Attendance.session_starts_at`: #{inspect(faltando)}.

      Some uma `change Api.Scheduling.Appointment.Changes.SyncSessionStartsAt` (ou, se a ação cria
      as presenças, `ManageParticipants` já resolve). Sem isso o Histórico da ficha ordena pelo
      horário velho, em silêncio — ver o moduledoc deste arquivo e o doc 43 §4.
      """
    end

    test "as duas mantenedoras ainda existem e estão penduradas em alguma ação" do
      # Renomear/remover uma delas sem substituir passaria batido no teste acima (a lista de
      # `faltando` ficaria vazia por vacuidade). Aqui se afirma o outro lado.
      penduradas =
        Appointment
        |> Ash.Resource.Info.actions()
        |> Enum.flat_map(&changes_de/1)
        |> MapSet.new()

      for mantenedora <- @mantenedoras do
        assert mantenedora in penduradas,
               "#{inspect(mantenedora)} não está em ação nenhuma de `Appointment`"
      end
    end
  end

  describe "o espelho acompanha de fato (não só na estrutura)" do
    test "remarcar o bloco move o session_starts_at de todas as presenças" do
      ctx = clinica()
      colega = paciente!(ctx, "Colega #{unico()}")
      turma = tipo!(ctx, nome: "Turma #{unico()}", icon: "Users", grupo: true, capacidade: 4)

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: turma.id,
            patient_ids: [ctx.paciente.id, colega.id]
          },
          scope: ctx.scope
        )

      assert Enum.all?(appt.attendances, &(&1.session_starts_at == at("08:00")))

      {:ok, movido} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
          starts_at: at("10:00")
        })

      # o retorno da ação não pode mentir…
      assert Enum.all?(movido.attendances, &(&1.session_starts_at == at("10:00")))

      # …e o banco também não.
      relidas =
        Scheduling.list_attendances!(
          scope: ctx.scope,
          query: [filter: [appointment_id: appt.id]]
        )

      assert length(relidas) == 2
      assert Enum.all?(relidas, &(&1.session_starts_at == at("10:00")))
    end

    test "remarcar SÓ o profissional não reescreve o espelho (nem gera escrita à toa)" do
      ctx = clinica()
      outro = profissional!(ctx, "Dr. Y")

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )

      antes = hd(appt.attendances).updated_at

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
          professional_id: outro.id
        })

      [presenca] =
        Scheduling.list_attendances!(
          scope: ctx.scope,
          query: [filter: [appointment_id: appt.id]]
        )

      assert presenca.session_starts_at == at("08:00")
      # o `IS DISTINCT FROM` do UPDATE é o que evita a escrita (e a linha de trilha) inútil
      assert presenca.updated_at == antes
    end
  end

  defp aceita_starts_at?(%{type: type} = action) when type in [:create, :update],
    do: :starts_at in (Map.get(action, :accept) || [])

  defp aceita_starts_at?(_action), do: false

  defp mantem_espelho?(action) do
    action |> changes_de() |> Enum.any?(&(&1 in @mantenedoras))
  end

  # O módulo de cada `change` da ação. As formas do DSL variam (`{Module, opts}`, struct de
  # validação embutida); só interessa quem tem módulo.
  defp changes_de(action) do
    action
    |> Map.get(:changes, [])
    |> Enum.map(fn
      %{change: {module, _opts}} -> module
      %{change: module} when is_atom(module) -> module
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end
end
