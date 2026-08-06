defmodule Api.Packages.Targets do
  @moduledoc """
  Os pares `{appointment, attendance}` de um pacote — a resolução **única** de "quais sessões deste
  pacote", com o filtro de cada caso passado de fora.

  ## Por que existe

  Havia três cópias da mesma sequência, com predicados finais diferentes (doc 101, B5):

    * `Api.Packages.future_sessions/3` — as futuras não-resolvidas, para pausar e cancelar;
    * `Api.Packages.held_targets/2` — as seguradas, para a retomada;
    * `Api.Packages.Bulk.targets/3` — as futuras não-resolvidas, para a massa.

  As três precisam concordar sobre o que é "uma sessão deste pacote", e concordavam **por
  convenção**: cada uma repetia, à mão, o mesmo par de leituras e o mesmo `Map.fetch!` do índice.
  A família de bugs que isso já gerou está documentada — as órfãs do bate-volta de 2026-07-24
  (uma cópia esqueceu de abrir o `include_held` e o pacote se escondeu do que ele mesmo segurou)
  e o A3 do doc 101 (uma cópia lia com recorte A7 e o pacote se escondeu de si mesmo).

  Unificar só foi possível **depois** do A3: enquanto as duas leituras tinham regimes de
  autorização diferentes, juntá-las teria escondido o bug em vez de corrigi-lo.

  ## A sequência, e por que cada passo está aqui

  1. **As presenças do pacote, incluindo as seguradas** (`list_package_attendances/3`, que abre a
     porta `include_held`). É por elas que se começa, e não pelos blocos: o vínculo com o pacote
     mora na presença.
  2. **Só as vivas** (`Attendance.viva?/1`). Presença cancelada já não é sessão de ninguém, e
     mantê-la na varredura fazia o bloco dos colegas ser arrastado por um vínculo morto.
  3. **Os blocos correspondentes, incluindo os segurados** (`list_sessions_including_held/3`).
     Sem `include_held`, o `.appointment` de uma sessão segurada por uma pausa anterior volta
     `nil` e o chamador estoura.
  4. **O par**, porque quem decide o efeito é a presença: uma turma com colegas não pode ser
     cancelada inteira por causa de um pacote.
  5. **Ordenado por `starts_at`**. A massa já ordenava (o escopo `:a_partir_desta` depende disso);
     o ciclo de vida não, e passar a ordenar torna a ordem das escritas determinística nos dois —
     de graça, já que a lista está na memória.
  """

  alias Api.Scheduling
  alias Api.Scheduling.Attendance

  @typedoc "Um bloco da agenda e a presença que o liga a este pacote."
  @type par :: {Scheduling.Appointment.t(), Attendance.t()}

  @doc """
  Os pares do pacote que satisfazem `filtro`, ordenados por `starts_at`.

  `filtro` recebe o par `{appointment, attendance}` — e recebe o **par**, não só o bloco, porque
  `held_targets` precisa olhar o `pkg_hold` dos dois (segurar é por-bloco quando a sessão está
  sozinha nele e por-presença quando ela fundiu numa turma, doc 43 §5c).
  """
  @spec pares(Api.Scope.t(), Ecto.UUID.t(), (par() -> boolean())) :: [par()]
  def pares(%Api.Scope{} = scope, package_id, filtro) when is_function(filtro, 1) do
    por_bloco =
      scope
      |> Scheduling.list_package_attendances(package_id, load: [:appointment])
      |> Enum.filter(&Attendance.viva?/1)
      |> Map.new(&{&1.appointment_id, &1})

    scope.clinic_id
    |> Scheduling.list_sessions_including_held(Map.keys(por_bloco), load: [:attendances])
    |> Enum.map(&{&1, Map.fetch!(por_bloco, &1.id)})
    |> Enum.filter(filtro)
    |> Enum.sort_by(fn {appt, _att} -> appt.starts_at end, DateTime)
  end
end
