defmodule Mix.Tasks.Cinetra.Whatsapp.Templates do
  @shortdoc "Submete os templates de WhatsApp à aprovação da Meta (uma vez por conta)"

  @moduledoc """
  Submete os templates HSM à Meta, pela API da Zernio (doc 65 §3).

  Roda **uma vez por conta**, e do outro lado há lead time de dias — é por isso que o doc 52 §9
  manda submeter durante a fase 1, não depois dela.

      mix cinetra.whatsapp.templates            # mostra o que seria enviado, não envia
      mix cinetra.whatsapp.templates --enviar   # envia de verdade

  O padrão é **não enviar**. Submissão à Meta não tem desfazer barato: um template reprovado por
  texto errado queima dias de fila, e um aprovado com o domínio errado no botão só se conserta
  criando `_v2` — o nome é a chave, e reescrever o corpo de um `_v1` já aprovado faz a mensagem
  sair com o texto antigo enquanto a timeline mostra o novo.

  ## O domínio do botão vem do ambiente, e o padrão é produção

  O botão de resposta é uma URL dinâmica (`https://cinetra.com.br/confirmar/{{1}}`) e o domínio
  fica **congelado no template aprovado**. Decidido em 2026-07-28: aprova-se só o de produção. O
  HML não manda WhatsApp — testa por e-mail e pelo sandbox da Zernio —, porque dois templates
  seriam duas filas de aprovação e o que se testaria no HML não seria o que roda em produção.

  Por isso a task recusa enviar com `WEB_APP_URL` apontando para `localhost`: seria queimar a
  fila para aprovar um botão que ninguém consegue abrir.

  ## O que ela NÃO faz

  Montar o payload. Isso é `Api.Messaging.Templates.hsm_payload/2`, que mora junto do texto
  aprovado e da ordem das posicionais — uma fonte só, e testável sem rodar a task. Aqui sobrou
  I/O e impressão.

  ## Por que é `Mix.Task` e não script em `priv/`

  Regra do projeto (`.claude/rules/migrations.md` §1): Elixir escrito à mão em `priv/` é ponto
  cego do formatter, do compilador e da cobertura — e ainda viaja para a imagem de produção.
  Tarefa operacional é `Mix.Task`, compilada e formatada como o resto.
  """
  use Mix.Task

  alias Api.Messaging.Templates
  alias Api.Messaging.Zernio

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    enviar? = "--enviar" in args
    base = Api.web_app_url()

    conferir(enviar?, base)

    Templates.conhecidos()
    |> Enum.sort()
    |> Enum.each(&processar(&1, base, enviar?))
  end

  defp conferir(false, _base), do: :ok

  defp conferir(true, base) do
    cond do
      not Zernio.configurado?() ->
        Mix.raise("faltam ZERNIO_API_KEY / ZERNIO_ACCOUNT_ID no ambiente")

      not String.starts_with?(base, "https://") ->
        Mix.raise("WEB_APP_URL precisa ser https público — o botão do template congela esta URL")

      true ->
        :ok
    end
  end

  defp processar(nome, base, enviar?) do
    {:ok, payload} = Templates.hsm_payload(nome, base)

    Mix.shell().info("\n=== #{nome} (#{payload.language}, #{payload.category}) ===")
    Mix.shell().info(Enum.map_join(payload.components, "\n", &descrever/1))

    if enviar?, do: submeter(nome, payload)
  end

  defp submeter(nome, payload) do
    case Zernio.criar_template(payload) do
      {:ok, _corpo} -> Mix.shell().info(">>> #{nome} submetido — a Meta responde em dias")
      {:error, motivo} -> Mix.shell().error(">>> #{nome} recusado: #{inspect(motivo)}")
    end
  end

  defp descrever(%{type: "BODY", text: texto}), do: texto
  defp descrever(%{type: "BUTTONS", buttons: [%{url: url} | _]}), do: "[botão] #{url}"
  defp descrever(componente), do: inspect(componente)
end
