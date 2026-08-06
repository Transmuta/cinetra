defmodule Api.ComposeEnvTest do
  @moduledoc """
  O `docker-compose.yml` (dev) e o `compose.dokploy.yml` (prod/HML) precisam repassar as **mesmas**
  variáveis de ambiente ao serviço `api`.

  ## O bug que este teste existe para não deixar voltar

  Quando o WhatsApp entrou (doc 65, fase 2), o `runtime.exs` passou a ler `ZERNIO_API_KEY`,
  `ZERNIO_ACCOUNT_ID`, `ZERNIO_BASE_URL` e `ZERNIO_WEBHOOK_SECRET`. O `compose.dokploy.yml` ganhou
  as quatro; o `docker-compose.yml` de dev, **nenhuma** — só a flag `WHATSAPP_HABILITADO`.

  O efeito é o pior tipo de silêncio, e custou uma sessão inteira de diagnóstico em 2026-08-01:
  o `.env` com a chave certa, o container recriado, a clínica configurada, o paciente com celular
  — e **toda** mensagem continuando a sair por e-mail, sem erro nenhum em lugar nenhum. Não havia
  o que ler no log, porque nada tinha falhado: sem credencial o adapter não está `configurado?`,
  `Transport.disponivel?(:whatsapp)` é `false`, e o `Dispatch` cai para a reserva — exatamente
  como ele deve fazer. O comportamento correto de uma camada escondia a configuração faltando na
  outra.

  Nenhum teste de unidade pega isso: o defeito não está em nenhum módulo, está na **distância**
  entre dois arquivos YAML que ninguém compara. Por isso o teste é sobre os arquivos.

  ## Por que a direção é prod → dev

  Um ambiente de dev que não recebe uma variável de produção é uma fatia que **não dá para
  exercitar antes do deploy**. O contrário — dev com algo a mais — é comum e legítimo (o
  `/dev/mailbox`, o seed), então a asserção é de mão única.

  ## Relação com o `Api.DeployEnvTest`

  Eles se completam. Aquele cobra que o compose de **produção** passe as envs que o `runtime.exs`
  lê — deriva a lista da configuração real, que é o desenho mais forte. Este cobra a **paridade
  dev ↔ prod**, e é o buraco que custou a sessão de 2026-08-01: produção tinha as quatro
  `ZERNIO_*`, o dev não tinha nenhuma, e um teste que só olha produção passa verde por cima disso.

  Se um dia o `DeployEnvTest` passar a cobrar as duas pontas a partir do `runtime.exs`, este vira
  redundante e deve sair — lista derivada é melhor que comparação de arquivos.
  """
  use ExUnit.Case, async: true

  # A raiz do repositório, pelos dois caminhos em que ela aparece:
  #
  #   * `/repo` — o bind mount read-only que o `docker-compose.yml` monta para este teste e para o
  #     `Api.DeployEnvTest`. É o único jeito de enxergá-la de dentro do container, que monta só
  #     `api/` em `/app`;
  #   * `../` — o CI, que faz checkout do repositório inteiro e roda com `working-directory: api`.
  #
  # Testar a existência em vez de escolher por env: um `if CI` erraria em toda máquina que não é
  # nenhum dos dois, e o modo de falhar seria pular em silêncio.
  @raiz if File.exists?("/repo/docker-compose.yml"),
          do: "/repo",
          else: Path.expand("../../..", __DIR__)
  @dev Path.join(@raiz, "docker-compose.yml")
  @prod Path.join(@raiz, "compose.dokploy.yml")

  # O que prod tem a mais **por ser prod**. Lista explícita, com o motivo de cada uma: a
  # alternativa (ignorar toda diferença) devolveria o teste ao nada que ele substitui, e uma lista
  # sem motivo vira o lugar onde se enfia o que incomoda.
  @so_em_producao [
    # Dev monta a conexão de DATABASE_HOST/USER/PASSWORD separados (docker-compose.yml); a URL
    # única é o formato que o release espera.
    "DATABASE_URL",
    # Só o release roda o endpoint por env; em dev o `mix phx.server` já sobe servindo.
    "PHX_SERVER",
    # `config/dev.exs` traz segredos fixos de desenvolvimento — não há o que injetar.
    "TOKEN_SIGNING_SECRET",
    "SECRET_KEY_BASE",
    # O host público, que em dev é sempre localhost.
    "PHX_HOST",
    # `dev.exs` cai em `http://localhost:5173`, que é o endereço certo em dev e o único possível.
    "WEB_APP_URL",
    # Heartbeat de cron (doc 74): monitora job que só roda em servidor de verdade.
    "HEARTBEAT_BASE_URL",
    "HEARTBEAT_SLUG_PREFIX",
    # O header de IP real vem do proxy. Em dev não há proxy, e confiar num header aqui seria
    # deixar qualquer request escolher o próprio IP para o rate limit.
    "TRUSTED_CLIENT_IP_HEADER"
  ]

  describe "as variáveis do serviço api" do
    test "tudo que produção repassa, o dev também repassa" do
      faltando = MapSet.difference(vars(@prod), vars(@dev))

      faltando =
        faltando |> MapSet.to_list() |> Enum.reject(&(&1 in @so_em_producao)) |> Enum.sort()

      assert faltando == [],
             """
             Estas variáveis chegam à API em produção e NÃO em dev:

               #{Enum.join(faltando, "\n  ")}

             Some-as no `environment:` do serviço `api` em docker-compose.yml, ou declare-as em
             @so_em_producao com o motivo. Uma variável que só existe em prod é uma fatia que
             ninguém consegue exercitar antes do deploy — e o sintoma costuma ser silêncio, não
             erro.
             """
    end
  end

  # As chaves do bloco `environment:` do serviço `api`.
  #
  # Lido com YAML de verdade, e não por regex: os dois arquivos são editados à mão, e um regex
  # que erre a indentação passaria a devolver conjunto vazio — um teste que fica verde por não
  # enxergar nada é pior do que não ter teste.
  defp vars(arquivo) do
    arquivo
    |> YamlElixir.read_from_file!()
    |> get_in(["services", "api", "environment"])
    |> Map.keys()
    |> MapSet.new()
  end
end
