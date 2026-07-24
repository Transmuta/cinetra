defmodule ApiWeb.WaitlistJSON do
  @moduledoc """
  A serialização da fila de espera (doc 25, Entrega 5). Reaproveita `ApiWeb.AgendaJSON` para o
  paciente e o profissional — a mesma forma nas duas telas, e uma fonte só (como a Entrega 3 fez
  para o bloco).

  `clinic_id` fica de fora (é o tenant, convenção do projeto). `dias_na_fila` é derivado de
  `inserted_at` no **relógio do escopo** (ADR-009), calculado aqui, não no banco.
  """

  alias Api.Scheduling.LocalTime

  @doc "Um item da fila. `today` é a data local de hoje (ADR-009); `tz`, o fuso da clínica."
  def entry(entry, today, tz) do
    %{
      id: entry.id,
      prio: entry.prio,
      janela: entry.janela,
      obs: entry.obs,
      professional_ids: entry.professional_ids,
      dias_na_fila: Date.diff(today, LocalTime.to_local_date(entry.inserted_at, tz)),
      rules: Enum.map(entry.rules, &rule/1),
      patient: patient(entry.patient),
      inserted_at: DateTime.to_iso8601(entry.inserted_at)
    }
  end

  @doc "Uma regra de disponibilidade (o índice é implícito pela ordem, casa com `slot.rule_index`)."
  def rule(rule) do
    %{
      id: rule.id,
      tipo: rule.tipo,
      dows: rule.dows,
      data: rule.data && Date.to_iso8601(rule.data),
      periodos: rule.periodos
    }
  end

  @doc "Uma vaga do motor (`find_slots`). `start` é minuto local; o cliente formata para HH:MM."
  def slot(slot) do
    %{
      date: Date.to_iso8601(slot.date),
      start: slot.start,
      dur: slot.dur,
      professional_id: slot.professional_id,
      dow: slot.dow,
      rule_index: slot.rule_index,
      freed: slot.freed
    }
  end

  def professional(prof), do: ApiWeb.AgendaJSON.professional(prof)

  def patient(nil), do: nil
  def patient(paciente), do: ApiWeb.AgendaJSON.patient(paciente)
end
