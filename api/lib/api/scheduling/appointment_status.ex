defmodule Api.Scheduling.AppointmentStatus do
  @moduledoc """
  Os seis status de um agendamento (`statusMeta` do protótipo,
  [`:810`](../../../interface/Movimento.dc.html#L810)):

    * `:agendado`       — recém-criado, ainda não confirmado pelo paciente;
    * `:confirmado`     — o paciente confirmou presença;
    * `:em_atendimento` — a sessão começou;
    * `:concluido`      — a sessão terminou e o paciente compareceu;
    * `:faltou`         — o paciente não compareceu (D4: justificativa é opcional);
    * `:cancelado`      — desmarcado; **não conflita** (predicado da constraint).

  Nesta fatia só `:agendado` nasce por ação da UI — as transições são a Entrega 4 (doc 25 §9).
  O enum já entra completo porque mudar valor de enum depois é migration, e porque o predicado
  da `appointments_no_overlap` referencia `'cancelado'` no banco desde a primeira migration.
  """
  use Ash.Type.Enum,
    values: [:agendado, :confirmado, :em_atendimento, :concluido, :faltou, :cancelado]
end
