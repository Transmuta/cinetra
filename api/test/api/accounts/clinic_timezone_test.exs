defmodule Api.Accounts.ClinicTimezoneTest do
  @moduledoc """
  O cache do fuso da clínica (D-K, doc 30 §4).

  O fuso é lido em todo caminho quente da agenda — cada escrita passa pelo notifier, cada
  janela lida passa pela fronteira — e a clínica é um PK-hit por vez. Cachear é fácil; o que
  este arquivo protege é a **invalidação**, porque cache que não invalida transforma "mudei o
  fuso da clínica" num bug que só some com restart.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Accounts.ClinicTimezone

  defp email, do: "tz-#{System.unique_integer([:positive])}@example.com"

  defp fixture do
    addr = email()
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: user)

    %{user: user, clinic: clinic}
  end

  test "devolve o fuso da clínica" do
    %{clinic: clinic} = fixture()
    assert ClinicTimezone.fetch(clinic.id) == "America/Sao_Paulo"
  end

  test "o segundo acesso não vai ao banco" do
    %{clinic: clinic} = fixture()
    ClinicTimezone.fetch(clinic.id)

    {tz, queries} = Api.QueryCounter.count(fn -> ClinicTimezone.fetch(clinic.id) end, "clinics")

    assert tz == "America/Sao_Paulo"
    assert queries == 0
  end

  test "mudar o fuso invalida o cache" do
    %{user: user, clinic: clinic} = fixture()
    assert ClinicTimezone.fetch(clinic.id) == "America/Sao_Paulo"

    {:ok, _} =
      Accounts.update_clinic_settings(clinic, %{timezone: "America/Manaus"}, actor: user)

    assert ClinicTimezone.fetch(clinic.id) == "America/Manaus"
  end

  test "invalidação chega pelo PubSub (é o que vale entre nós)" do
    %{clinic: clinic} = fixture()
    ClinicTimezone.fetch(clinic.id)

    # O que um OUTRO nó faria: só a mensagem, sem passar pela ação local.
    Phoenix.PubSub.broadcast(Api.PubSub, "clinic_timezone", {:invalidate, clinic.id})

    # A mensagem é assíncrona; o `call` serializa contra o processo que a trata.
    ClinicTimezone.sync()

    {_tz, queries} = Api.QueryCounter.count(fn -> ClinicTimezone.fetch(clinic.id) end, "clinics")
    assert queries == 1
  end

  test "clínica inexistente não envenena o cache" do
    inexistente = Ash.UUID.generate()

    assert_raise Ash.Error.Invalid, fn -> ClinicTimezone.fetch(inexistente) end
    assert_raise Ash.Error.Invalid, fn -> ClinicTimezone.fetch(inexistente) end
  end
end
