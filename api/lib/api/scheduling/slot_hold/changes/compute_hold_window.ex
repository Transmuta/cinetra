defmodule Api.Scheduling.SlotHold.Changes.ComputeHoldWindow do
  @moduledoc """
  Deriva `ends_at` e `expires_at` de uma reserva de vaga (doc 09 §6.2):

    * `ends_at = starts_at + duration_minutos` — a vaga tem a duração de varredura do motor
      (o argumento; default 50), não um tipo (o item de fila não carrega tipo — o tipo real é
      escolhido só na conversão);
    * `expires_at = agora + TTL` — o TTL de 10 min (D8). `agora` é o **relógio do escopo**
      (ADR-009), estável na requisição. É só o *valor* guardado; a **expiração efetiva** (a
      limpeza) compara com o relógio do **banco** (`PurgeExpired`), como manda o doc 09 §6.2.
  """
  use Ash.Resource.Change

  # 10 min (D8). O "5 min" dos docs 01/02/09 é resíduo do desenho anterior (12 Parte C).
  @ttl_seconds 600

  @impl true
  def change(changeset, _opts, _context) do
    starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)
    duration = Ash.Changeset.get_argument(changeset, :duration_minutos)
    # `now` vem do escopo (`changeset.context[:now]`, ADR-009), não do relógio de parede —
    # como `SessionStarted`. É só o *valor* de `expires_at`; a expiração efetiva compara com o
    # relógio do banco em `PurgeExpired`.
    now = changeset.context[:now] || DateTime.utc_now()

    changeset
    |> put_ends_at(starts_at, duration)
    |> Ash.Changeset.force_change_attribute(:expires_at, DateTime.add(now, @ttl_seconds, :second))
  end

  defp put_ends_at(changeset, %DateTime{} = starts_at, duration) when is_integer(duration) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :ends_at,
      DateTime.add(starts_at, duration * 60, :second)
    )
  end

  # `starts_at`/`duration` ausentes ou malformados: deixa como está — as validações de
  # `allow_nil? false` recusam com a mensagem certa, não este change calado.
  defp put_ends_at(changeset, _starts_at, _duration), do: changeset
end
