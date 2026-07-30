defmodule Api.DeployEnvTest do
  @moduledoc """
  As envs de comunicação (doc 52 / doc 65) chegam ao container da API no compose de produção.

  ## O bug que este teste existe para não deixar voltar

  O `compose.dokploy.yml` roteia `/webhooks` para a API desde o começo — está escrito no cabeçalho
  dele — mas o bloco `environment:` do serviço `api` nunca recebeu nenhuma env de comunicação.
  Efeito no dia em que o stack subir, e é duplo:

    * sem `RESEND_API_KEY` o mailer cai no adapter `Local` (`runtime.exs`, e é o contrato provado
      em `Api.MailerConfigTest`) — **nenhum e-mail sai**, inclusive o magic link, ou seja ninguém
      entra no sistema;
    * sem `RESEND_WEBHOOK_SECRET` o webhook é fail-closed e responde **401 em todo evento**
      (`ApiWeb.ResendWebhookController`). O Resend reentrega por horas e a timeline de comunicação
      congela em `:enviado` para sempre.

  Nenhum dos dois levanta erro em lugar nenhum: a API sobe perfeita, a suíte fica verde e o
  sintoma só aparece em produção, disfarçado de "o e-mail não chegou".

  ## Por que a lista sai do `runtime.exs`, e não é digitada aqui

  Uma lista escrita à mão envelhece: quem acrescentar `MAIL_REPLY_TO` amanhã mexe no
  `runtime.exs`, não neste teste. Então o teste **lê as envs do próprio `runtime.exs`** e cobra
  cada uma no compose — o mesmo espírito do `Api.MailerConfigTest`, que também prova a
  configuração real em vez de uma cópia dela.

  O recorte é o prefixo de comunicação porque é o alcance do bug medido. As demais famílias
  (banco, R2, heartbeat) já estão no compose; estendê-las é trabalho de outro dia, com outro
  achado.

  ## Fase 2 entra também, e vazia

  `ZERNIO_*` e `WHATSAPP_HABILITADO` não são opcionais *neste* teste, embora o WhatsApp esteja
  desligado: `${ZERNIO_API_KEY:-}` no compose é a diferença entre "canal desligado" (o estado em
  que a fatia nasce) e "o dia de ligar o WhatsApp reencena exatamente este bug". Passar a env
  vazia não liga nada — quem liga é a flag.
  """

  use ExUnit.Case, async: true

  # O compose mora fora de `api/`, e a suíte roda a partir de `api/`. Dois lugares, duas formas de
  # alcançá-lo: no CI o checkout inteiro está ao lado (`../`); no container de dev, onde só `api/`
  # é montado em `/app`, o `docker-compose.yml` monta a raiz do repositório em `/repo` só-leitura.
  # Sem o segundo caminho o teste pularia justamente onde se desenvolve.
  @compose ["../compose.dokploy.yml", "/repo/compose.dokploy.yml"]
  @runtime "config/runtime.exs"

  @familias ~w(RESEND_ MAIL_ ZERNIO_ WHATSAPP_)

  test "o serviço `api` do compose de produção recebe toda env de comunicação do runtime.exs" do
    compose = File.read!(caminho_do_compose())

    for env <- envs_de_comunicacao() do
      assert compose =~ env,
             """
             `#{env}` é lida por config/runtime.exs mas não é passada ao container da API em \
             compose.dokploy.yml.

             Sintoma em produção: nenhum erro. A API sobe, a suíte passa, e o e-mail simplesmente \
             não sai (ou o webhook responde 401 em todo evento). Ver o moduledoc.
             """
    end
  end

  # Falha em vez de pular quando o compose não é alcançável: um teste de configuração que some
  # sozinho no ambiente errado é pior do que não existir — ele reporta verde sem ter olhado nada.
  defp caminho_do_compose do
    Enum.find(@compose, &File.exists?/1) ||
      flunk("compose.dokploy.yml não encontrado em nenhum de: #{Enum.join(@compose, ", ")}")
  end

  # Todo `System.get_env("X")` do runtime.exs cujo nome começa por uma das famílias de comunicação.
  defp envs_de_comunicacao do
    nomes =
      ~r/System\.get_env\("([A-Z0-9_]+)"/
      |> Regex.scan(File.read!(@runtime))
      |> Enum.map(fn [_todo, nome] -> nome end)
      |> Enum.filter(fn nome -> Enum.any?(@familias, &String.starts_with?(nome, &1)) end)
      |> Enum.uniq()

    # Guarda contra o teste virar vacuidade: se a regex parar de casar (o `runtime.exs` muda de
    # forma), a lista fica vazia e o `for` acima passa sem verificar nada.
    assert length(nomes) >= 5, "a extração do runtime.exs devolveu #{length(nomes)} envs"

    nomes
  end
end
