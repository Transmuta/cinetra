defmodule Api.Scheduling.Appointment.Changes.StampExcludedAt do
  @moduledoc """
  Carimba `excluded_at` com o instante da exclusão (soft-delete, doc 40). Lê o relógio injetado
  (`changeset.context[:now]`, vindo de `Api.Scope`) em vez de chamar o relógio de parede direto —
  a mesma disciplina de `Api.Scheduling.Appointment.Validations.SessionStarted`, que mantém o
  ciclo de vida determinístico e testável sem depender da hora real. Sem `:now` no contexto
  (seed, chamada interna), cai no `DateTime.utc_now/0`.

  Módulo próprio (não fn anônima) pela convenção do projeto (ash.md — "Custom Modules vs.
  Anonymous Functions").
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    now = changeset.context[:now] || DateTime.utc_now()
    Ash.Changeset.change_attribute(changeset, :excluded_at, now)
  end
end
