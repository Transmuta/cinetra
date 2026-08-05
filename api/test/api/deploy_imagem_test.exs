defmodule Api.DeployImagemTest do
  @moduledoc """
  A imagem que o CI aprovou é a imagem que o servidor roda — **R-M4** (doc 95), a metade que a onda
  3 do [doc 102](../../../docs/102-plano-de-acao-infraestrutura.md) deixou explicitamente pendente:
  *"publicar num registry e mandar o Dokploy consumir por digest […] precisa de credencial de
  registry e de reconfigurar o Dokploy — decisão que não é minha"*.

  ## O que estava errado enquanto o `build:` viveu aqui

  Duas coisas, e a segunda é a que ninguém vê:

    * **o build acontecia na máquina de produção.** O Dokploy constrói no servidor a cada webhook,
      e isso mede ~90% dos 2 vCPU (D-21) — competindo com o produto que serve os pacientes, num
      momento em que o produto está justamente trocando de container;

    * **o artefato aprovado não era o artefato implantado.** O job `imagem` do CI construía as duas
      imagens e as jogava fora; o servidor construía *outras*, a partir do mesmo Git mas com outro
      cache, outro relógio e outra rede. Quando as duas divergem, o log da que falhou está no
      painel do Dokploy e não no GitHub — que é o sintoma que o próprio R-M4 descreve.

  ## Por que `pull_policy: always` não é detalhe

  Com tag móvel (`main`, `develop`) a imagem nova tem o **mesmo nome** da que já está no disco do
  servidor. Sem `pull_policy: always`, o `docker compose up` encontra o nome localmente e **não
  baixa nada**: o webhook é aceito, o stack "sobe", o `/api/ready` responde 200 — e o código é o
  do deploy anterior. Deploy verde que não implantou é pior que deploy vermelho, e vale em dobro
  para o `migrate`, onde significa rodar a migration da versão errada.

  ## O limite honesto

  Isto lê **texto do compose**. Prova que a declaração está lá; não prova que a tag existe no
  registro, que o servidor consegue baixá-la, nem que o digest é o que o CI construiu. O lado do
  CI — publicar de fato — é cobrado em `Api.CiWorkflowTest`, que lê o outro artefato.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Compose

  @registro "ghcr.io"

  # Os serviços que rodam código NOSSO. `db` fica de fora de propósito: é `postgres:16` fixado por
  # digest de índice multi-arch (R-M8), que é outra coisa e já tem outro dono.
  @do_produto ~w(migrate api web)

  setup_all do
    {:ok, compose: Compose.ler()}
  end

  describe "o servidor consome, não constrói (R-M4)" do
    test "nenhum serviço do produto tem `build:` no compose de produção", %{compose: compose} do
      for nome <- @do_produto do
        linhas = Compose.servico(compose, nome)

        refute Enum.any?(linhas, &Regex.match?(~r/^\s+build:/, &1)),
               """
               O serviço `#{nome}` ainda declara `build:` em compose.dokploy.yml.

               Isso põe o build na máquina de PRODUÇÃO a cada webhook — ~90% dos 2 vCPU (D-21), \
               concorrendo com o produto — e faz o artefato implantado ser um que nenhum gate do \
               CI viu. Troque por `image:` apontando para o que o job `imagem` publicou.

               (O `compose.prod.yml` do smoke local continua buildando: ali é o ponto.)
               """
      end
    end

    test "todo serviço do produto aponta para uma imagem do registro", %{compose: compose} do
      for nome <- @do_produto do
        linhas = Compose.servico(compose, nome)

        ancora =
          Enum.find_value(linhas, fn linha ->
            case Regex.run(~r/^\s+image:\s*\*(\S+)/, linha) do
              [_todo, nome_da_ancora] -> nome_da_ancora
              nil -> nil
            end
          end)

        assert ancora,
               """
               O serviço `#{nome}` não declara `image:` por âncora.

               As âncoras existem para que `migrate` e `api` sejam estruturalmente a MESMA \
               imagem: rodar a migration de uma versão e servir outra é o modo de falha que o \
               expand-contract (doc 59 §8) pressupõe impossível.
               """

        assert compose =~ ~r/&#{Regex.escape(ancora)}\s+\S*#{Regex.escape(@registro)}\S+/,
               "a âncora `#{ancora}` existe mas não aponta para uma imagem em #{@registro}"
      end
    end

    test "todo serviço do produto baixa a imagem a cada subida", %{compose: compose} do
      for nome <- @do_produto do
        linhas = Compose.servico(compose, nome)

        assert Enum.any?(linhas, &Regex.match?(~r/^\s+pull_policy:\s*always/, &1)),
               """
               O serviço `#{nome}` não declara `pull_policy: always`.

               Com tag móvel a imagem nova tem o mesmo NOME da que já está no disco do servidor. \
               Sem esta linha o Docker acha o nome localmente e não baixa: o webhook é aceito, o \
               stack sobe, o `/api/ready` responde 200 — servindo o código do deploy anterior.

               No `migrate` isso é pior ainda: é rodar a migration da versão errada.
               """
      end
    end

    test "a tag da imagem é obrigatória — sem ela o stack não sobe", %{compose: compose} do
      assert compose =~ ~r/\$\{IMAGE_TAG:\?/,
             """
             `IMAGE_TAG` tem default no compose (ou não é interpolada).

             Default aqui é a falha silenciosa clássica deste arquivo: um stack sem a variável \
             sobe com a tag do OUTRO ambiente — HML servindo a imagem de produção. `${IMAGE_TAG:?…}` \
             faz o compose recusar com a mensagem em vez de adivinhar.
             """
    end
  end
end
