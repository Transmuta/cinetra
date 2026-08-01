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

  ## Onde ele de fato roda, e por quê

  **No CI, sim; dentro do container de dev, não.** O `docker-compose.yml` monta só `api/` em
  `/app`, então os dois arquivos da raiz não existem para quem roda `mix test` lá dentro. No CI o
  checkout traz o repositório inteiro e o job roda com `working-directory: api`, então eles estão
  um nível acima — que é onde este teste os procura.

  Quando os arquivos não estão ao alcance ele **falha explicitamente em vez de passar**. Um
  `assert true` disfarçado de cobertura seria pior do que não existir: diria "as duas configurações
  concordam" sobre um par de arquivos que ninguém abriu. Se o skip local incomodar, o conserto é
  montar a raiz no container — não afrouxar a asserção.
  """
  use ExUnit.Case, async: true

  @raiz Path.expand("../../..", __DIR__)
  @dev Path.join(@raiz, "docker-compose.yml")
  @prod Path.join(@raiz, "compose.dokploy.yml")

  # O que prod tem a mais **por ser prod**, e que em dev não faria sentido. Lista explícita: a
  # alternativa (ignorar toda diferença) devolveria o teste ao nada que ele substitui.
  @so_em_producao ~w(
    PHX_HOST
    SECRET_KEY_BASE
    POOL_SIZE
    DNS_CLUSTER_QUERY
    RELEASE_COOKIE
  )

  describe "as variáveis do serviço api" do
    @tag :compose
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
