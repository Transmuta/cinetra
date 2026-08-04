defmodule Api.Accounts.WelcomeEmailJob do
  @moduledoc """
  As boas-vindas de quem acabou de criar uma clínica (`Api.Accounts.Clinic.onboard`).

  ## Por que ele escapa da régua do doc 31 §5

  A régua é dura de propósito — "e-mail por evento de agenda vira spam em uma semana" — e este
  não é evento de agenda: é **um por clínica, na vida**, no instante em que a pessoa mais precisa
  saber o que fazer a seguir. O terceiro e-mail de conta do projeto, e o `Api.Accounts.Emails`
  descreve o critério que os três compartilham.

  ## Por que um job, e não o envio no request

  O mesmo motivo do `Api.Accounts.AccessRevokedEmailJob`: entrega de e-mail é I/O externo e lento,
  e ela não pode nem atrasar nem derrubar a criação da clínica. Aqui isso pesa mais que lá — o
  `onboard` é a **primeira** coisa que a pessoa faz no produto, e um erro nele custa o cadastro
  inteiro. Vai para a fila `notifications`, que já existe.

  ## As duas saídas, como no irmão

    * **clínica ou conta sumiu** entre o commit e o job → `:ok`. Não há o que repetir;
    * **entrega falhou** → `{:error, motivo}`, para o Oban tentar de novo e, esgotadas as
      tentativas, deixar o job `discarded` — visível.

  A diferença de gravidade em relação ao aviso de acesso removido: lá o e-mail é o **único** canal
  que alcança quem saiu; aqui a pessoa está logada e o produto está aberto na frente dela. Perder
  este e-mail custa orientação, não acesso — mas ele continua indo para `discarded` em vez de
  sumir como `:ok`, porque "o onboarding não manda mais e-mail" é o tipo de falha que só se
  descobre pela fila.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  require Logger

  @doc "Enfileira as boas-vindas. Best-effort: falhar aqui não desfaz a criação da clínica."
  def enqueue(%{user_id: user_id, clinic_id: clinic_id}) do
    %{"user_id" => user_id, "clinic_id" => clinic_id}
    |> new(Api.Correlacao.opts())
    |> Oban.insert()
  end

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
    case Api.Accounts.Emails.send_welcome_email(user, clinic.nome) do
      {:ok, _} ->
        :ok

      {:error, motivo} ->
        Logger.error("WelcomeEmailJob: entrega falhou (#{inspect(motivo)})")
        {:error, motivo}
    end
  rescue
    # Adapter que levanta em vez de devolver tupla. Mesmo destino: é falha de entrega.
    error ->
      Logger.error("WelcomeEmailJob: #{Exception.message(error)}")
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
