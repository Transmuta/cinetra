defmodule Api.MailerConfigTest do
  @moduledoc """
  A escolha do adapter de e-mail em `runtime.exs`, provada pela configuração REAL.

  O contrato está escrito no próprio arquivo: *"sem `RESEND_API_KEY` o sistema segue no adapter
  `Local`"* — a caixa em memória de `/dev/mailbox`, que é como se vê o magic link em dev sem
  entregar e-mail a ninguém.

  Aqui se prova que ele vale também para a variável **presente e vazia**, que é o estado normal de
  dev: o `docker-compose.yml` define `RESEND_API_KEY: ${RESEND_API_KEY:-}`, ou seja, a env SEMPRE
  existe no container — vazia quando não há valor no `.env`.
  """

  use ExUnit.Case, async: false

  setup do
    original = System.get_env("RESEND_API_KEY")

    on_exit(fn ->
      if original,
        do: System.put_env("RESEND_API_KEY", original),
        else: System.delete_env("RESEND_API_KEY")
    end)

    :ok
  end

  defp mailer(env), do: Config.Reader.read!("config/runtime.exs", env: env)[:api][Api.Mailer]

  test "variável VAZIA não escolhe o Resend — a caixa de dev continua funcionando" do
    # O bug medido: `if api_key = System.get_env("RESEND_API_KEY")` casa com `""`, porque em Elixir
    # só `nil` e `false` são falsos. O adapter do Resend era escolhido com chave vazia e o envio
    # estourava em `Swoosh.Adapter.raise_on_missing_config/2` — magic link quebrado em todo dev
    # subido pelo compose, com `/dev/mailbox` vazio e nenhuma pista apontando para a causa.
    System.put_env("RESEND_API_KEY", "")

    refute mailer(:dev)[:adapter] == Swoosh.Adapters.Resend
  end

  test "variável AUSENTE não escolhe o Resend" do
    System.delete_env("RESEND_API_KEY")

    refute mailer(:dev)[:adapter] == Swoosh.Adapters.Resend
  end

  test "com chave de verdade, o Resend é escolhido" do
    # O outro sentido do contrato: consertar o caso vazio não pode desligar o e-mail de produção.
    #
    # Lido em `:dev` e não em `:prod` porque a escolha do adapter não olha o ambiente (só exclui
    # `:test`), e `runtime.exs` em `:prod` levanta por falta de `SECRET_KEY_BASE` — o teste
    # morreria por um motivo que não tem nada a ver com e-mail.
    System.put_env("RESEND_API_KEY", "re_chave_de_teste")

    config = mailer(:dev)
    assert config[:adapter] == Swoosh.Adapters.Resend
    assert config[:api_key] == "re_chave_de_teste"
  end
end
