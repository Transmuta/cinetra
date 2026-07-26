defmodule Api.Scheduling.Appointment.Changes.SyncSessionStartsAt do
  @moduledoc """
  Propaga o `starts_at` do bloco para o `session_starts_at` das presenças dele (doc 43 §4).

  A coluna é denormalizada de propósito — é o que faz o histórico da ficha ordenar e paginar pelo
  índice, em vez de um aggregate não-correlacionado que varre a agenda da clínica no hash join. O
  preço da denormalização é exatamente esta cascata: **quem move o bloco move a presença**.

  ## Por que um `UPDATE` só, e não a ação da presença

  A irmã `CascadeToAttendances` chama a ação de cada presença, e deve mesmo: lá o que muda é
  **estado de domínio** (quem faltou, quem concluiu), a trilha precisa registrar e cada escrita é
  um fato. Aqui o que muda é uma **cópia** de um valor cujo original a trilha do bloco já registrou.
  Passar pela ação custaria, por remarcação: um `SELECT` das presenças, N `UPDATE`s e N linhas de
  `attendances_versions` — trilha que só diria "o espelho espelhou". É o mesmo tipo de custo que o
  bate-volta mediu no caminho quente da massa (doc 43 §5a), num lugar onde não compra nada.

  Roda dentro da transação da remarcação (`after_action`), com a GUC de tenant já setada pelo
  `SetTenantGuc` da ação — e ainda assim o `UPDATE` filtra por `clinic_id` explicitamente, defesa
  em profundidade no mesmo espírito do resto do domínio. O `IS DISTINCT FROM` é o que faz remarcar
  só o profissional (sem mexer no horário) não escrever nada.

  As presenças já carregadas no bloco são corrigidas **em memória**, para o retorno da ação não
  sair mentindo sobre o que está no banco.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn cs, appointment ->
      Api.Repo.query!(
        """
        UPDATE attendances
           SET session_starts_at = $1, updated_at = (now() AT TIME ZONE 'utc')
         WHERE appointment_id = $2 AND clinic_id = $3 AND session_starts_at IS DISTINCT FROM $1
        """,
        [
          DateTime.to_naive(appointment.starts_at),
          Ecto.UUID.dump!(appointment.id),
          Ecto.UUID.dump!(to_string(cs.tenant))
        ]
      )

      {:ok, espelha_em_memoria(appointment)}
    end)
  end

  defp espelha_em_memoria(%{attendances: attendances} = appointment) when is_list(attendances) do
    %{
      appointment
      | attendances: Enum.map(attendances, &%{&1 | session_starts_at: appointment.starts_at})
    }
  end

  defp espelha_em_memoria(appointment), do: appointment
end
