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

  # Os status de **bloco aberto**: compromisso que ainda vai acontecer ou está acontecendo. Os
  # outros três já têm desfecho.
  #
  # Mora aqui, ao lado do enum que define os status — mesma disciplina de
  # `Api.Scheduling.Attendance.viva?/1`, e pelo mesmo motivo: a lista estava escrita à mão em
  # dois lugares (o guard do `:cancel` e a varredura dos lembretes da Onda 4), e lista de status
  # copiada é a que diverge no dia em que alguém acrescenta um status e atualiza só um dos lados.
  @abertos [:agendado, :confirmado, :em_atendimento]

  @doc """
  Os status de bloco aberto — o que ainda é compromisso.

      iex> Api.Scheduling.AppointmentStatus.abertos()
      [:agendado, :confirmado, :em_atendimento]
  """
  def abertos, do: @abertos

  @doc """
  O bloco ainda é um compromisso?

      iex> Api.Scheduling.AppointmentStatus.aberto?(:confirmado)
      true
      iex> Api.Scheduling.AppointmentStatus.aberto?(:cancelado)
      false
  """
  def aberto?(status) when is_atom(status), do: status in @abertos
end
