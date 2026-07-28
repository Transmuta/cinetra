defmodule Mix.Tasks.Cinetra.Whatsapp.TemplatesTest do
  @moduledoc """
  A task que submete os templates à Meta (doc 65 §3).

  O que se prova aqui é o que evita queimar dias de fila de aprovação: **o padrão é não enviar**,
  e enviar sem credencial ou com domínio de dev é recusado antes de chegar à rede. A montagem do
  payload é testada em `Api.Messaging.TemplatesTest`, onde ela mora.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Cinetra.Whatsapp.Templates, as: Task

  setup do
    anterior = Application.get_env(:api, Api.Messaging.Zernio, [])
    on_exit(fn -> Application.put_env(:api, Api.Messaging.Zernio, anterior) end)
    :ok
  end

  test "sem --enviar, só mostra o que iria — e mostra todos" do
    saida = capture_io(fn -> Task.run([]) end)

    for template <- Api.Messaging.Templates.conhecidos() do
      assert saida =~ template
    end

    # O corpo aprovado e o botão aparecem: é isto que alguém lê antes de decidir submeter.
    assert saida =~ "pt_BR"
    assert saida =~ "UTILITY"
    assert saida =~ "[botão]"
    assert saida =~ "/confirmar/{{1}}"
  end

  test "--enviar sem credencial não chega à rede" do
    Application.put_env(:api, Api.Messaging.Zernio, [])

    assert_raise Mix.Error, ~r/ZERNIO_API_KEY/, fn ->
      capture_io(fn -> Task.run(["--enviar"]) end)
    end
  end

  test "--enviar com WEB_APP_URL de dev é recusado" do
    # O domínio fica congelado no template aprovado. Submeter `http://localhost:5173` gastaria a
    # fila da Meta para aprovar um botão que ninguém consegue abrir.
    Application.put_env(:api, Api.Messaging.Zernio, api_key: "sk_x", account_id: "conta")
    anterior = Application.get_env(:api, :web_app_url)
    Application.put_env(:api, :web_app_url, "http://localhost:5173")

    # `delete_env` quando não havia valor, e não `put_env(nil)`: o default de `Api.web_app_url/0`
    # só vale para chave **ausente**, e deixá-la presente com `nil` faz o teste seguinte estourar
    # num `<>` com nil — foi o que aconteceu ao escrever este arquivo.
    on_exit(fn ->
      if anterior,
        do: Application.put_env(:api, :web_app_url, anterior),
        else: Application.delete_env(:api, :web_app_url)
    end)

    assert_raise Mix.Error, ~r/https/, fn ->
      capture_io(fn -> Task.run(["--enviar"]) end)
    end
  end
end
