defmodule Api.Accounts.AccessRevokedEmailJob do
  @moduledoc """
  Avisa **por e-mail** quem foi removido de uma clínica (#50, doc 44 §3).

  ## Por que e-mail, e não a caixa do sino

  A caixa é por-tenant e só se lê com vínculo ativo. No instante em que o vínculo cai, aquela
  caixa fica inalcançável para quem saiu — escrever ali seria gravar uma linha que ninguém vai
  abrir. O e-mail é o único canal que atravessa a remoção, e é por isso que este é o **segundo**
  canal do projeto a existir (o doc 31 §5 manteve e-mail fora da v1 justamente para não virar spam
  por evento de agenda; mudança de acesso não é evento de agenda).

  A notificação in-app continua existindo, com outro destinatário: owner/admin, pelo
  `Api.Notifications.Fanout.member_removed/2`. Os dois lados da remoção ficam cobertos.

  ## Por que um job, e não o envio no request

  SMTP é I/O externo e lento; deixá-lo dentro da resposta do "remover membro" é a mesma dívida
  que o #52 acabou de tirar do cancelamento. Vai para a fila `notifications`, que já existe.

  ## Sem lógica de autor

  Diferente de todo o resto do fan-out, aqui **não** se suprime quem causou o evento. Aviso de
  mudança de acesso é registro de segurança: o valor dele é chegar sempre, inclusive (e
  principalmente) quando quem recebe não foi quem fez. Um admin que saiu por vontade própria
  receber a confirmação é ruído aceitável; o inverso não é.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  require Logger

  @doc "Enfileira o aviso. Best-effort: falhar aqui não desfaz a remoção."
  def enqueue(%{user_id: user_id, clinic_id: clinic_id}) do
    %{"user_id" => user_id, "clinic_id" => clinic_id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Duas saídas, e a diferença entre elas é o conserto do bate-volta:

    * **conta ou clínica sumiu** entre o commit e o job → `:ok`. Não é falha a repetir; tentar de
      novo daria o mesmo nada, três vezes;
    * **entrega falhou** → `{:error, motivo}`, para o Oban tentar de novo (`max_attempts: 3`) e,
      esgotadas as tentativas, deixar o job em `discarded` — visível.

  Antes as duas saíam como `:ok`. E o motivo de isso passar batido é traiçoeiro: `Api.Mailer.deliver/1`
  devolve `{:error, _}`, **não levanta** — então o `rescue` que existia aqui nunca via a falha, e
  a tentativa era marcada como concluída. Num aviso qualquer isso seria aceitável; neste não,
  porque ele é o único canal que alcança quem saiu (não há caixa in-app de segunda chance).
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "clinic_id" => clinic_id}}) do
    with %{} = user <- buscar(:user, user_id),
         %{} = clinic <- buscar(:clinic, clinic_id) do
      entregar(user, clinic)
    else
      _sumiu -> :ok
    end
  end

  defp entregar(user, clinic) do
    case Api.Accounts.Emails.send_access_revoked_email(user, clinic.nome) do
      {:ok, _} ->
        :ok

      {:error, motivo} ->
        Logger.error("AccessRevokedEmailJob: entrega falhou (#{inspect(motivo)})")
        {:error, motivo}
    end
  rescue
    # Adapter que levanta em vez de devolver tupla. Mesmo destino: é falha de entrega.
    error ->
      Logger.error("AccessRevokedEmailJob: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  defp buscar(:user, id) do
    case Api.Accounts.get_user(id, authorize?: false, not_found_error?: false) do
      {:ok, %{} = user} -> user
      _ -> nil
    end
  end

  defp buscar(:clinic, id) do
    case Api.Accounts.get_clinic(id, authorize?: false, not_found_error?: false) do
      {:ok, %{} = clinic} -> clinic
      _ -> nil
    end
  end
end
