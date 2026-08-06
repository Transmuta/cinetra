defmodule Api.Scheduling.PatientSessionsTest do
  @moduledoc """
  `Api.Scheduling.list_patient_sessions/3` — as duas listas da ficha (doc 56) e, aqui, a aritmética
  do `more?` quando alguma linha lida **não sobrevive** ao filtro em Elixir.

  O achado M3 (doc 101): a leitura pede `limit + 1` ao banco para responder "tem mais" sem um
  `COUNT`, mas rejeitava depois as presenças cujo `.appointment` volta `nil` — e só ENTÃO comparava
  `length(lista) > limit`. Com a lista já reduzida, a comparação passa a ser sobre outra coisa: uma
  única linha rejeitada derruba o `more?` para `false` com mais linhas esperando no banco, e o "ver
  histórico completo" para de paginar.

  Presença com `.appointment` nulo não é caso de borda: é o pacote **pausado**. Pausar segura o
  bloco quando a sessão está sozinha nele (doc 43 §5c), e `HideHeld` esconde bloco segurado de toda
  leitura — a presença passa pelo filtro dela, o bloco não.

  Este teste ataca a lista `upcoming` porque sessão segurada é sempre futura (pausar só alcança de
  hoje em diante). A aritmética é a mesma função (`read_patient_sessions/5`) nas duas listas.
  """
  use Api.DataCase, async: false

  alias Api.Scheduling

  # O relógio da ficha fica aqui; as sessões nascem depois dele.
  @hoje ~D[2026-07-13]

  defp at(data, hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(data, hhmm, "America/Sao_Paulo")
    dt
  end

  defp setup_clinic, do: clinica(now: at(@hoje, "08:00"))

  defp sessao(ctx, data, hhmm) do
    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: at(data, hhmm),
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id]
        },
        scope: ctx.scope
      )

    appt
  end

  # Segura o BLOCO, que é o que `Api.Packages.segura/1` faz quando a sessão está sozinha nele. A
  # presença continua visível; o bloco some da leitura por causa do `HideHeld`.
  defp segurar(ctx, appt) do
    {:ok, _} =
      Scheduling.set_appointment_pkg_hold(appt, %{pkg_hold: true},
        tenant: ctx.clinic.id,
        authorize?: false
      )

    :ok
  end

  describe "more? com linha rejeitada depois da leitura (M3)" do
    test "sessão segurada não pode derrubar o aviso de que há mais" do
      ctx = setup_clinic()

      # duas seguradas ANTES das demais: elas entram nas `limit + 1` linhas lidas e saem no filtro
      seguradas = [
        sessao(ctx, ~D[2026-07-16], "08:00"),
        sessao(ctx, ~D[2026-07-17], "08:00")
      ]

      Enum.each(seguradas, &segurar(ctx, &1))

      # seis visíveis — bem mais que o teto de 5 das próximas
      for {data, hhmm} <- [
            {~D[2026-07-20], "08:00"},
            {~D[2026-07-21], "08:00"},
            {~D[2026-07-22], "08:00"},
            {~D[2026-07-23], "08:00"},
            {~D[2026-07-24], "08:00"},
            {~D[2026-07-27], "08:00"}
          ] do
        sessao(ctx, data, hhmm)
      end

      %{upcoming: upcoming, upcoming_more?: mais?} =
        Scheduling.list_patient_sessions(ctx.scope, ctx.paciente.id)

      assert mais?,
             "o cartão disse que acabou com 6 sessões visíveis no banco e #{length(upcoming)} " <>
               "na tela — o `more?` foi calculado sobre a lista já filtrada"
    end

    test "sem linha rejeitada, o more? continua respondendo o de sempre" do
      ctx = setup_clinic()

      for {data, hhmm} <- [
            {~D[2026-07-20], "08:00"},
            {~D[2026-07-21], "08:00"},
            {~D[2026-07-22], "08:00"}
          ] do
        sessao(ctx, data, hhmm)
      end

      %{upcoming: upcoming, upcoming_more?: mais?} =
        Scheduling.list_patient_sessions(ctx.scope, ctx.paciente.id)

      assert length(upcoming) == 3
      refute mais?
    end
  end
end
