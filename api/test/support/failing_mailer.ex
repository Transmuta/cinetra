defmodule Api.Support.FailingMailer do
  @moduledoc """
  Adapter Swoosh que sempre falha na entrega.

  Existe porque o `Swoosh.Adapters.Test` **sempre devolve `{:ok, _}`**, e um mailer que nunca
  falha não consegue exercer o caminho em que a entrega falha — que é justamente onde o
  `Api.Accounts.AccessRevokedEmailJob` engolia o erro em silêncio (bate-volta da Onda 4).
  """
  @behaviour Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, {:network, :sem_relay}}

  @impl true
  def deliver_many(_emails, _config), do: {:error, {:network, :sem_relay}}

  @impl true
  def validate_config(_config), do: :ok

  @doc "Roda `fun` com este adapter no lugar do configurado, e restaura no fim."
  def with_failure(fun) when is_function(fun, 0) do
    original = Application.get_env(:api, Api.Mailer)
    Application.put_env(:api, Api.Mailer, adapter: __MODULE__)

    try do
      fun.()
    after
      Application.put_env(:api, Api.Mailer, original)
    end
  end
end
