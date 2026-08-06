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

  # O recorte do compose por serviço mora em `Api.ComposeDeProducao`: nasceu aqui e ganhou um
  # segundo cliente (`Api.DeployHorizontalidadeTest`), que o teria copiado.
  alias Api.ComposeDeProducao, as: Compose

  @runtime "config/runtime.exs"

  @familias ~w(RESEND_ MAIL_ ZERNIO_ WHATSAPP_)

  # A variável do stack que responde "qual header a edge garante?". Uma só, porque a resposta é
  # uma só — ver o teste abaixo.
  @fonte_do_ip "CLIENT_IP_HEADER"

  test "o serviço `api` do compose de produção recebe toda env de comunicação do runtime.exs" do
    servico = Compose.servico(Compose.ler(), "api")

    for env <- envs_de_comunicacao() do
      assert Enum.any?(servico, &Regex.match?(~r/^\s+#{Regex.escape(env)}:/, &1)),
             """
             `#{env}` é lida por config/runtime.exs mas não é passada ao container da API em \
             compose.dokploy.yml.

             Sintoma em produção: nenhum erro. A API sobe, a suíte passa, e o e-mail simplesmente \
             não sai (ou o webhook responde 401 em todo evento). Ver o moduledoc.
             """
    end
  end

  @doc false
  # "Qual header de proxy merece confiança?" é UMA decisão, e ela é respondida em dois arquivos
  # muito distantes: a lista do `ApiWeb.ClientIp` (API) e o `ADDRESS_HEADER` do adapter-node (BFF).
  #
  # Elas já discordaram uma vez, e o custo foi medido: o BFF passou a confiar em `CF-Connecting-IP`
  # e a lista da API ficou vazia, caindo no `x-forwarded-for` — que o Cloudflare **acrescenta** em
  # vez de sobrescrever, e cujo primeiro elemento é escrito pelo cliente. Separar a resposta em dois
  # lugares foi também a causa B do bate-volta doc 68.
  #
  # Então o teste não cobra um valor: cobra que os dois lados **derivem da mesma variável do
  # stack**. Assim a topologia é declarada uma vez, no painel do Dokploy, e não há como um ambiente
  # ter um lado configurado e o outro não.
  #
  # A terceira asserção fecha o laço pelo outro lado: passar a env no compose não faz nada se o
  # `runtime.exs` não a ler — e essa metade da ligação é invisível em qualquer inspeção do compose.
  test "o header de IP do cliente sai da MESMA variável nos dois serviços — e o runtime.exs a lê" do
    compose = Compose.ler()

    assert "TRUSTED_CLIENT_IP_HEADER" in envs_lidas_pelo_runtime(),
           "o compose passaria a env para um runtime.exs que não a lê — ligação pela metade"

    assert Compose.valor_de(Compose.servico(compose, "api"), "TRUSTED_CLIENT_IP_HEADER") =~
             @fonte_do_ip

    assert Compose.valor_de(Compose.servico(compose, "web"), "ADDRESS_HEADER") =~ @fonte_do_ip
  end

  # Todo `System.get_env("X")` do runtime.exs.
  defp envs_lidas_pelo_runtime do
    ~r/System\.get_env\("([A-Z0-9_]+)"/
    |> Regex.scan(File.read!(@runtime))
    |> Enum.map(fn [_todo, nome] -> nome end)
    |> Enum.uniq()
  end

  # As do recorte de comunicação, que é o alcance do bug que originou o primeiro teste.
  defp envs_de_comunicacao do
    nomes =
      envs_lidas_pelo_runtime()
      |> Enum.filter(fn nome -> Enum.any?(@familias, &String.starts_with?(nome, &1)) end)

    # Guarda contra o teste virar vacuidade: se a regex parar de casar (o `runtime.exs` muda de
    # forma), a lista fica vazia e o `for` acima passa sem verificar nada.
    assert length(nomes) >= 5, "a extração do runtime.exs devolveu #{length(nomes)} envs"

    nomes
  end
end
