defmodule Api.Scheduling.AppointmentStatusTest do
  @moduledoc """
  Os status de agendamento e o recorte "bloco aberto".

  O `doctest` é o motivo principal deste arquivo existir: `abertos/0` e `aberto?/1` nasceram no
  bate-volta da Onda 4 com exemplo na docstring, e exemplo que não roda é documentação que
  apodrece em silêncio (achado da rodada 5, doc 45 §4).
  """
  use ExUnit.Case, async: true

  alias Api.Scheduling.AppointmentStatus

  doctest Api.Scheduling.AppointmentStatus

  test "todo status aberto é um valor do enum" do
    # Um átomo com typo em `@abertos` não quebraria nada na compilação: viraria um filtro que
    # nunca casa, e o lembrete simplesmente pararia de sair para aquele status.
    assert AppointmentStatus.abertos() -- AppointmentStatus.values() == []
  end

  test "os status com desfecho não são abertos" do
    for status <- [:concluido, :faltou, :cancelado] do
      refute AppointmentStatus.aberto?(status)
    end
  end
end
