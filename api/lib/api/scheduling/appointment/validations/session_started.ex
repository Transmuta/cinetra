defmodule Api.Scheduling.Appointment.Validations.SessionStarted do
  @moduledoc """
  Recusa concluir/faltar antes de a sessão começar (Entrega 4).

  No protótipo os botões "Concluir" e "Faltou" ficam desabilitados até a sessão começar, com o
  title *"Disponível após o horário da sessão"* ([`:1841`]). A UI antecipa por ergonomia; o
  veredito é do servidor (doc 25 §3), então a regra também mora aqui.

  A fronteira é **"já começou"** (`starts_at <= agora`), a de RN-58 — deliberadamente diferente
  de "precisa de ação" (`ends_at <= agora`): concluir/faltar libera quando a sessão *começou*,
  não quando *terminou*. `agora` vem do escopo (`context[:now]`, ADR-009), nunca de
  `DateTime.utc_now/0` — é o que torna a regra determinística e testável sem depender do relógio
  de parede. **Cancelar e reabrir não passam por aqui**: cancelar um futuro é legítimo, e
  reabrir desfaz um clique errado a qualquer momento.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    now = changeset.context[:now] || DateTime.utc_now()

    case changeset.data.starts_at do
      %DateTime{} = starts_at ->
        if DateTime.compare(starts_at, now) != :gt,
          do: :ok,
          else: {:error, field: :status, message: "Disponível após o horário da sessão"}

      _ ->
        :ok
    end
  end
end
