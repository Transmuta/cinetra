defmodule Api.Support.FailingMailer do
  @moduledoc """
  Adapter Swoosh que sempre falha na entrega.

  Existe porque o `Swoosh.Adapters.Test` **sempre devolve `{:ok, _}`**, e um mailer que nunca
  falha não consegue exercer o caminho em que a entrega falha — que é justamente onde o
  `Api.Accounts.AccessRevokedEmailJob` engolia o erro em silêncio (bate-volta da Onda 4).
  """
  @behaviour Swoosh.Adapter

  # Motivo default: uma falha de rede, sem texto de provider. Quem precisa exercer a **barreira
  # de PII** do doc 62 §7.3 passa um bounce realista via `with_failure/2` — bounce de e-mail
  # embute o destinatário, e é isso que não pode chegar ao log.
  @default {:network, :sem_relay}

  @impl true
  def deliver(_email, _config), do: {:error, motivo()}

  @impl true
  def deliver_many(_emails, _config), do: {:error, motivo()}

  @impl true
  def validate_config(_config), do: :ok

  defp motivo, do: Application.get_env(:api, __MODULE__, @default)

  @doc "Roda `fun` com este adapter no lugar do configurado, e restaura no fim."
  def with_failure(fun) when is_function(fun, 0), do: with_failure(@default, fun)

  @doc "Idem, com um motivo de falha específico (ex.: o texto cru de um bounce)."
  def with_failure(motivo, fun) when is_function(fun, 0) do
    original = Application.get_env(:api, Api.Mailer)
    Application.put_env(:api, Api.Mailer, adapter: __MODULE__)
    Application.put_env(:api, __MODULE__, motivo)

    try do
      fun.()
    after
      Application.put_env(:api, Api.Mailer, original)
      Application.delete_env(:api, __MODULE__)
    end
  end
end
