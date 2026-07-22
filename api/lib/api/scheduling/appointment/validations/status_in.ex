defmodule Api.Scheduling.Appointment.Validations.StatusIn do
  @moduledoc """
  Recusa uma transição de ciclo de vida quando o status ATUAL do bloco não está no conjunto de
  origens permitidas (F4 do QA, doc 34). O protótipo/UI só mostra o botão válido por status, mas
  o veredito é do servidor (doc 25 §3): sem este guard, uma chamada direta à API (ou uma UI velha,
  ou uma corrida) fazia `concluído → cancelado`, `reabrir` de um já-agendado ou `justificar` uma
  falta que nunca houve — cada uma virava 200 + uma entrada FANTASMA na trilha de auditoria.

  Uma regra, um módulo (DRY): cada ação passa `from:` com as origens que aceita — ex.:
  `validate {StatusIn, from: [:agendado, :confirmado, :em_atendimento]}`.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if is_list(opts[:from]) and opts[:from] != [],
      do: {:ok, opts},
      else: {:error, "from deve ser uma lista não-vazia de status"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    if changeset.data.status in opts[:from],
      do: :ok,
      else:
        {:error,
         field: :status,
         message: "transição indisponível a partir de \"#{changeset.data.status}\""}
  end
end
