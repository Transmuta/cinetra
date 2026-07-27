defmodule Api.Scheduling.CodedError do
  @moduledoc """
  Constrói os erros de agenda que carregam um **código estável** do contrato (doc 25 §5):
  `group_full`, `outside_business_hours`, `closed_by_exception`.

  ## Por que o código viaja em `vars`

  Uma validação de recurso não conhece HTTP e não deve conhecer. `vars` é o canal que o Ash já
  oferece para dado estruturado dentro de um erro, então é ali que o código anda; a fronteira o
  promove ao topo do 422. Sem isso, o único identificador do erro seria o **texto** da mensagem
  — e aí editar uma frase quebraria o cliente em silêncio.

  ## Por que existe como módulo

  A construção é contra-intuitiva o bastante para não caber em dois lugares: `add_error/2` com
  keyword list **aninha** o que recebe (`vars: [vars: [code: ...]]`), então a exception precisa
  ser montada à mão. Isso foi descoberto uma vez em `CheckAvailability`; centralizar impede que
  seja redescoberto na próxima validação com código.

  Erro **sem campo** (`InvalidChanges`) é o default dos códigos de agenda, e é deliberado: em
  "esse horário sobrepõe outro" ou "a turma está cheia" não há campo errado no formulário —
  pintar `starts_at` de vermelho mentiria (A10, `09:605`).
  """

  @doc "Erro sem campo, com código estável — o formato dos erros de agenda (A10)."
  def invalid_changes(message, code) when is_binary(message) and is_binary(code) do
    Ash.Error.Changes.InvalidChanges.exception(message: message, vars: [code: code])
  end

  @doc """
  O erro do **A3/D12**: a mudança quebraria agendamentos futuros.

  Carrega a análise inteira em `vars` (e não só o código) porque a tela precisa **listar** o que
  vai quebrar — é o único erro do projeto cujo conteúdo é uma lista, e é o que a fronteira
  promove para o `meta` do 409.
  """
  def future_conflicts(%{conflicts: conflicts, total: total}) do
    Ash.Error.Changes.InvalidChanges.exception(
      message: "Há #{total} agendamento(s) futuro(s) que ficariam fora do expediente.",
      vars: [code: "future_conflicts", conflicts: conflicts, total: total]
    )
  end

  @doc "Erro de campo, com código opcional — quando o formulário tem de fato onde pintar."
  def invalid_attribute(field, message, code \\ nil) when is_atom(field) and is_binary(message) do
    Ash.Error.Changes.InvalidAttribute.exception(
      field: field,
      message: message,
      vars: if(code, do: [code: code], else: [])
    )
  end
end
