defmodule Api.CiWorkflowTest do
  @moduledoc """
  O **caminho até produção** como superfície de ataque e de falha silenciosa. Onda 3 do
  [doc 102](../../../docs/102-plano-de-acao-infraestrutura.md) — R-A10, R-M6, R-M7, R-M5 e R-B3 do
  [doc 95](../../../docs/95-analise-infraestrutura.md).

  Nada aqui melhora a produção de hoje. Tudo aqui decide se a produção de amanhã nasce sã.

  ## O token (R-A10)

  Sem bloco `permissions:`, o `GITHUB_TOKEN` recebe o default configurado no repositório — que em
  repositórios mais antigos é **read/write em todos os escopos**. E este workflow executa código de
  terceiros com o token no ambiente: `mix deps.get` e `npm ci` rodam scripts de instalação de toda
  a árvore de dependências. Um pacote comprometido em qualquer ponto dela empurra commit, altera
  workflow ou publica release.

  O agravante específico deste repositório: o job `deploy` tem acesso a
  `DOKPLOY_DEPLOY_WEBHOOK_PROD` — o **gatilho de deploy de produção**.

  ## A tag móvel (R-M6)

  `@v4` é um ponteiro, não um commit. Quem controla `actions/cache` (ou qualquer uma das outras)
  pode mover a tag e executar código arbitrário no runner que tem os secrets de deploy — **sem um
  único commit neste repositório**, e portanto sem nada para revisar.

  SHA de 40 caracteres é imutável. O custo é que atualizar passa a ser um commit — que é
  exatamente o ponto, e é o que o Dependabot automatiza (R-M7).

  ## O deploy que só prova que o POST chegou (R-M5)

  `curl -fsS -X POST "$URL"` retorna assim que o Dokploy **aceita** o webhook. O CI fica verde
  mesmo que o build no servidor falhe, o `migrate` aborte ou o container novo não passe no
  healthcheck. É o sinal que a equipe vai aprender a confiar, e ele mede uma coisa só: que o HTTP
  POST chegou.

  ## O 302 que passa por 200 (R-M5, a continuação)

  `curl -fsS` falha em status **>= 400**. O painel do Dokploy está atrás do **Cloudflare Access**
  (doc 59 §5.1), e o Access não recusa quem não tem credencial: ele **redireciona** para a tela de
  login, com **302**. Logo o passo de disparo sai com código 0, o job fica verde, e o webhook
  nunca chegou ao Dokploy. É o mesmo defeito do R-M5 uma camada acima — desta vez o sinal não mede
  nem que o POST chegou.

  ## A imagem que nasce no CI (R-M4)

  A outra metade do R-M4: o CI publica as imagens e o servidor as consome. O que este arquivo
  cobra é o lado do CI; que o `compose.dokploy.yml` de fato consuma o que foi publicado é o
  assunto de `Api.DeployImagemTest`, que lê o outro artefato.

  ## O limite honesto

  Este arquivo lê **texto do workflow**. Ele prova que a declaração está lá; não prova que o token
  restrito basta para os passos, nem que o SHA fixado aponta para o que se pensa, nem que o
  `/ready` do ambiente certo foi consultado. O que ele impede é a declaração **sumir** — que é o
  estado em que ela sempre esteve.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Repo

  @workflow ".github/workflows/ci.yml"
  @dependabot ".github/dependabot.yml"
  @dockerfile_api "api/Dockerfile.prod"
  @dockerfile_api_dev "api/Dockerfile.dev"
  @dockerfile_web "web/Dockerfile.prod"
  @dockerfile_web_dev "web/Dockerfile.dev"

  setup_all do
    {:ok, ci: Repo.ler_do_repo(@workflow)}
  end

  # ---------------------------------------------------------------------------
  # O gate só vale se testar a MESMA toolchain que a imagem embarca.
  #
  # Medido em 2026-08-06: o Dependabot bumpou `api/Dockerfile.prod` para elixir 1.20.1-otp-29 e
  # `web/Dockerfile.prod` para node 25 (ecossistema `docker`), enquanto `ci.yml` seguiu em
  # elixir 1.18.4/OTP 27 e node 22. Ele não enxerga `elixir-version:`/`node-version:` porque são
  # string solta no YAML, não dependência.
  #
  # A consequência não foi teórica: no node 25, 20 testes quebravam em
  # `TypeError: localStorage.clear is not a function` — e o CI ficava VERDE, porque rodava no 22.
  # O gate provava uma versão e a imagem de produção embarcava outra.
  # ---------------------------------------------------------------------------
  describe "paridade de toolchain entre o CI e as imagens" do
    test "o CI roda o MESMO Elixir/OTP que a imagem de produção da API", %{ci: ci} do
      [_, elixir_img, otp_img] =
        Regex.run(~r/^FROM elixir:([\d.]+)-otp-(\d+)/m, Repo.ler_do_repo(@dockerfile_api))

      elixires = Regex.scan(~r/elixir-version:\s*"([^"]+)"/, ci) |> Enum.map(&List.last/1)
      otps = Regex.scan(~r/otp-version:\s*"([^"]+)"/, ci) |> Enum.map(&List.last/1)

      assert elixires != [], "nenhum `elixir-version:` no ci.yml — a forma do workflow mudou?"

      for versao <- elixires do
        assert versao == elixir_img,
               """
               ci.yml testa em Elixir #{versao}, mas api/Dockerfile.prod embarca #{elixir_img}.

               O gate deixa de provar o que vai para produção. Alinhe os dois — e rode a suíte na
               versão nova ANTES de mudar aqui.
               """
      end

      for versao <- otps do
        assert versao == otp_img,
               "ci.yml testa em OTP #{versao}, mas a imagem embarca OTP #{otp_img}."
      end

      assert Repo.ler_do_repo(@dockerfile_api_dev) =~ "FROM elixir:#{elixir_img}-otp-#{otp_img}",
             "api/Dockerfile.dev divergiu do prod — dev e produção compilando em toolchains " <>
               "diferentes é bug que só aparece no deploy."
    end

    test "o CI roda o MESMO Node que a imagem de produção do BFF", %{ci: ci} do
      web = Repo.ler_do_repo(@dockerfile_web)
      bases = Regex.scan(~r/^FROM node:(\d+)/m, web) |> Enum.map(&List.last/1) |> Enum.uniq()

      assert length(bases) == 1,
             "web/Dockerfile.prod mistura majors do Node entre os estágios: #{inspect(bases)}"

      [node_img] = bases

      assert rem(String.to_integer(node_img), 2) == 0,
             """
             node #{node_img} é ÍMPAR, e no Node só a linha par vira LTS — ímpar é "Current" e sai
             de manutenção em meses. Foi exatamente o PR #9 (node 22 → 25) de 2026-08-06.
             """

      nodes = Regex.scan(~r/node-version:\s*"([^"]+)"/, ci) |> Enum.map(&List.last/1)

      assert nodes != [], "nenhum `node-version:` no ci.yml — a forma do workflow mudou?"

      for versao <- nodes do
        assert versao == node_img,
               """
               ci.yml testa em Node #{versao}, mas web/Dockerfile.prod embarca #{node_img}.

               Foi assim que 20 testes quebrados no node 25 passaram despercebidos: o CI rodava
               no 22 e ficava verde.
               """
      end

      assert Repo.ler_do_repo(@dockerfile_web_dev) =~ ~r/^FROM node:#{node_img}\b/m,
             "web/Dockerfile.dev divergiu do prod."
    end
  end

  describe "permissão do GITHUB_TOKEN (R-A10)" do
    test "o workflow declara permissions no topo", %{ci: ci} do
      # Recorte até a primeira linha de `jobs:` — `permissions:` dentro de um job também casaria
      # no arquivo inteiro, e o que se cobra aqui é o default do workflow.
      topo = ci |> String.split("\njobs:") |> List.first()

      assert topo =~ ~r/^permissions:/m,
             """
             `.github/workflows/ci.yml` não declara `permissions:` no nível do workflow.

             Sem isso o `GITHUB_TOKEN` herda o default do repositório, que pode ser read/write em \
             TODOS os escopos — enquanto `mix deps.get` e `npm ci` executam código de terceiros no \
             runner, no mesmo workflow que guarda o webhook de deploy de PRODUÇÃO.

             Custo do conserto: duas linhas.
             """

      assert topo =~ ~r/^\s+contents:\s*read/m,
             "o bloco `permissions:` existe mas não reduz `contents` a `read`"
    end
  end

  describe "actions fixadas por SHA (R-M6)" do
    test "toda `uses:` aponta para um commit de 40 caracteres", %{ci: ci} do
      referencias =
        ~r/^\s*(?:-\s+)?uses:\s*(\S+)/m
        |> Regex.scan(ci)
        |> Enum.map(fn [_todo, ref] -> ref end)

      # Anti-vacuidade: se a extração parar de casar, o `for` abaixo não olha nada.
      assert length(referencias) >= 4,
             "a extração achou só #{length(referencias)} `uses:` — a forma do workflow mudou?"

      for ref <- referencias do
        assert ref =~ ~r/@[0-9a-f]{40}$/,
               """
               `uses: #{ref}` não está fixado por SHA.

               Tag é ponteiro MÓVEL: quem controla a action pode movê-la e executar código \
               arbitrário no runner que tem `DOKPLOY_DEPLOY_WEBHOOK_PROD` no ambiente — sem um \
               único commit neste repositório, e portanto sem nada para revisar.

               Ponha o SHA de 40 caracteres e deixe o comentário com a versão ao lado; o \
               Dependabot atualiza os dois.
               """
      end
    end
  end

  describe "varredura de dependência (R-M7)" do
    test "o CI audita as dependências dos dois lados", %{ci: ci} do
      assert ci =~ ~r/mix\s+(hex\.audit|deps\.audit)/,
             "nenhum passo audita as dependências Elixir — CVE conhecida entra e permanece sem sinal"

      assert ci =~ ~r/npm audit/,
             "nenhum passo roda `npm audit` — mesma cegueira do lado do BFF"
    end

    test "existe configuração de Dependabot para os quatro ecossistemas" do
      dependabot = Repo.ler_do_repo(@dependabot)

      for ecossistema <- ~w(github-actions mix npm docker) do
        assert dependabot =~ ecossistema,
               """
               `.github/dependabot.yml` não cobre `#{ecossistema}`.

               Fixar por SHA (R-M6) sem Dependabot troca "atualiza sozinho e sem revisão" por \
               "nunca atualiza" — que é pior para CVE. As duas metades andam juntas.
               """
      end
    end

    test "toda atualização mira `develop`, e nenhuma cai direto em `main`" do
      dependabot = Repo.ler_do_repo(@dependabot)

      ecossistemas = Regex.scan(~r/^\s*-\s*package-ecosystem:\s*(\S+)/m, dependabot)
      alvos = Regex.scan(~r/^\s*target-branch:\s*(\S+)/m, dependabot)

      assert ecossistemas != [],
             "a extração não achou nenhum `package-ecosystem:` — o formato do arquivo mudou?"

      assert length(alvos) == length(ecossistemas),
             """
             #{length(ecossistemas)} ecossistemas configurados, mas só #{length(alvos)} com \
             `target-branch:`.

             Sem `target-branch`, o Dependabot abre contra a branch DEFAULT — que aqui é `main`. \
             E `ci.yml` dispara `DOKPLOY_DEPLOY_WEBHOOK_PROD` em todo push para `main`. Logo cada \
             merge de bump vira um deploy de PRODUÇÃO que nunca passou por HML, pulando o \
             `develop` que é o fluxo de todo o resto do repositório.

             Medido em 2026-08-05: a primeira varredura abriu 18 PRs, os 18 contra `main`.
             """

      for [_, alvo] <- alvos do
        assert alvo == "develop",
               "`target-branch: #{alvo}` — o alvo tem de ser `develop`, que é a branch de HML."
      end
    end

    test "toda atualização espera antes de adotar versão recém-publicada" do
      dependabot = Repo.ler_do_repo(@dependabot)

      ecossistemas = Regex.scan(~r/^\s*-\s*package-ecosystem:\s*(\S+)/m, dependabot)
      carencias = Regex.scan(~r/^\s*cooldown:\s*$/m, dependabot)

      assert length(carencias) == length(ecossistemas),
             """
             #{length(ecossistemas)} ecossistemas configurados, mas só #{length(carencias)} com \
             `cooldown:`.

             Este é o ÚNICO item deste arquivo que endereça pacote MALICIOSO, e não CVE. \
             `mix deps.audit`, `npm audit` e o próprio Dependabot comparam a versão contra banco \
             de advisory — e publicação maliciosa não está em banco nenhum no instante em que \
             você instala. O advisory nasce depois.

             Sem carência o Dependabot AUMENTA a exposição: a função dele é levar para a versão \
             mais nova o mais rápido possível, que é exatamente onde o malware está. Publicação \
             maliciosa tem meia-vida curta — o registro despublica, o mantenedor recupera a \
             conta —, então esperar alguns dias evita quase toda a janela.

             Atualização de SEGURANÇA do GitHub passa por fora do cooldown, como deve.
             """

      for [_, dias] <- Regex.scan(~r/^\s*default-days:\s*(\d+)/m, dependabot) do
        assert String.to_integer(dias) >= 3,
               "`default-days: #{dias}` é curto demais para o pacote malicioso ser despublicado."
      end
    end
  end

  describe "o deploy é verificado depois de disparado (R-M5)" do
    test "o job de deploy espera o ambiente responder antes de ficar verde", %{ci: ci} do
      deploy = bloco_do_job(ci, "deploy")
      texto = Enum.join(deploy, "\n")

      assert texto =~ "/api/ready" or texto =~ "/ready",
             """
             O job `deploy` dispara o webhook e termina.

             O `curl -fsS -X POST` retorna assim que o Dokploy ACEITA o webhook. O CI fica verde \
             mesmo que o build no servidor falhe, o `migrate` aborte ou o container novo não passe \
             no healthcheck. O sinal de "deploy ok" mede apenas que o POST chegou.
             """
    end

    # O teste acima aceita `/api/ready` OU `/ready`, e foi por essa fresta que o defeito passou: o
    # passo batia em `${BASE}/api/ready`, que **não existe do lado de fora**. Medido no
    # `compose.dokploy.yml`: o Traefik só encaminha para a API `PathPrefix(/socket)` (`:253`) e
    # `PathPrefix(/webhooks)` (`:259`); todo o resto de `Host(WEB_HOST)` (`:360`) vai para o BFF, e
    # o `web/src/routes/api/` não tem `ready` — logo, 404 do catch-all do SvelteKit.
    #
    # O efeito é pior que inofensivo: sem `DEPLOY_URL_*` o passo avisa e sai verde; COM a variável
    # configurada, ele recebe 404 sessenta vezes e reprova um deploy que funcionou. Configurar a
    # variável piorava o CI, e é por isso que ela seguia pendente sem nada quebrar.
    #
    # `web/src/routes/ready/+server.ts:11-12` já dizia isso por escrito e existe exatamente para
    # resolver: o `/ready` do BFF atravessa a rede interna e consulta o `/api/ready` da API, que
    # toca o banco. Uma URL só, vermelha se qualquer elo do caminho quebrar (doc 62 §9.4).
    test "a verificação bate num caminho que o Traefik expõe ao mundo", %{ci: ci} do
      espera = passo_do_job(ci, "deploy", "Esperar")

      refute espera =~ ~r{\$\{BASE\}/api/ready},
             """
             O passo de verificação consulta `${BASE}/api/ready` — que é INALCANÇÁVEL de fora.

             No desenho BFF-only (doc 59 §3.1) o Traefik só manda `/socket` e `/webhooks` para a \
             API. `/api/ready` existe em `router.ex:76`, mas só por `http://api:4000` na rede \
             interna; pelo domínio público ele cai no catch-all do BFF e responde **404**.

             O alvo certo é `${BASE}/ready` — o readiness DO BFF, que consulta o `/api/ready` da \
             API pela rede interna e por isso fica vermelho se qualquer elo quebrar.
             """

      assert espera =~ ~r{\$\{BASE\}/ready},
             "o passo não consulta `${BASE}/ready` — a verificação de deploy ficou sem alvo"
    end
  end

  describe "o webhook atravessa o Cloudflare Access (R-M5, continuação)" do
    test "o disparo confere o STATUS da resposta, não só o código de saída do curl", %{ci: ci} do
      disparo = passo_do_job(ci, "deploy", "Disparar")

      assert disparo =~ "http_code",
             """
             O passo que dispara o webhook não olha o status da resposta.

             `curl -fsS -X POST` falha em >= 400. O painel do Dokploy está atrás do Cloudflare \
             Access (doc 59 §5.1), e o Access não RECUSA quem não tem credencial — ele \
             **redireciona para o login, com 302**. O curl sai com 0, o job fica verde, e o \
             Dokploy nunca recebeu nada.

             Capture `%{http_code}` e exija 2xx.
             """

      assert disparo =~ "cloudflareaccess.com",
             """
             O passo confere o status mas não distingue a interceptação do Access de um erro \
             qualquer do Dokploy.

             São diagnósticos opostos — um é credencial (token ausente, expirado ou política \
             errada no Zero Trust), o outro é o servidor. Sem separar os dois, quem lê o log \
             vermelho procura no lugar errado.
             """
    end

    # Medido ao vivo contra o servidor em 2026-08-05, contra o webhook de HML:
    #
    #   POST sem corpo                        -> 301 {"message":"Branch Not Match"}   (30 bytes)
    #   POST + X-GitHub-Event + ref=develop   -> 200 {"message":"Compose deployed successfully"}
    #
    # O endpoint do Dokploy NÃO é um gatilho genérico: ele espera o payload de um push de git e
    # compara o `ref` com a branch configurada no stack. Sem corpo não há branch, e ele recusa.
    #
    # Isso segurou o primeiro deploy real, e custou três rodadas de investigação no lugar errado —
    # o 301 foi lido como problema de URL, e o 403 que aparecia no teste manual (Client ID sem o
    # sufixo `.access`) reforçou a pista falsa de que o Cloudflare Access estava barrando. No CI o
    # Access sempre passou: a prova é que o erro original trazia `content-length: 30`, o tamanho
    # exato de `{"message":"Branch Not Match"}`.
    test "o disparo manda o payload de push que o Dokploy exige", %{ci: ci} do
      disparo = passo_do_job(ci, "deploy", "Disparar")

      assert disparo =~ "X-GitHub-Event",
             """
             O disparo não declara `X-GitHub-Event`.

             É por esse cabeçalho que o Dokploy reconhece o formato do payload. Sem ele o corpo \
             não é interpretado, e o webhook responde `301 {"message":"Branch Not Match"}` — um \
             3xx, então nem cai no ramo de erro que fala em recusa.
             """

      assert disparo =~ ~r/-d\s+"\{\\"ref\\":\\"\$REF\\"\}"/,
             """
             O disparo não manda `{"ref":"$REF"}` no corpo.

             `$REF` já chega como `refs/heads/<branch>`, que é exatamente o formato do campo `ref` \
             do evento de push do GitHub — é o que o Dokploy lê para decidir se a branch bate com \
             a do stack.

             Mandar o REF do evento (e não uma constante) é o que transforma isto num gate: se a \
             branch configurada no Dokploy divergir da que disparou o CI, ele RECUSA em vez de \
             implantar a versão errada.
             """
    end

    test "o 403 do Access não é confundido com recusa do Dokploy", %{ci: ci} do
      disparo = passo_do_job(ci, "deploy", "Disparar")

      assert disparo =~ "cf-access-aud",
             """
             O passo não distingue um 403 DO ACESSO de um 403 do Dokploy.

             Política `Service Auth` **nega com 403**, não redireciona — então a detecção que \
             procura `cloudflareaccess.com` no ramo 3xx não a alcança, e o 403 cai no ramo \
             genérico imprimindo "O Dokploy recusou o webhook". Diagnóstico invertido: manda quem \
             lê o log procurar no painel do Dokploy enquanto o problema está no Zero Trust.

             O cabeçalho `cf-access-aud` só aparece quando quem respondeu foi o Access, e ainda \
             diz QUAL aplicação — que é o dado com que se acha a política errada.
             """
    end

    test "o disparo manda o service token do Access quando ele existe", %{ci: ci} do
      disparo = passo_do_job(ci, "deploy", "Disparar")

      for cabecalho <- ["CF-Access-Client-Id", "CF-Access-Client-Secret"] do
        assert disparo =~ cabecalho,
               """
               O disparo não manda `#{cabecalho}`.

               É o par que o Cloudflare Access aceita no lugar de uma sessão de navegador \
               (Service Auth). Sem ele, o único jeito de o POST passar é uma política de **Bypass** \
               no path do webhook — que deixa o gatilho de deploy aberto a quem descobrir a URL.
               """
      end
    end
  end

  describe "as imagens de produção nascem no CI (R-M4)" do
    test "o job `imagem` publica no registro em push para main e develop", %{ci: ci} do
      imagem = ci |> bloco_do_job("imagem") |> Enum.join("\n")

      assert imagem =~ "ghcr.io",
             """
             O job `imagem` constrói e joga fora.

             Enquanto ele não publicar, o Dokploy segue buildando NO SERVIDOR a cada webhook — \
             ~90% dos 2 vCPU da máquina que serve os pacientes (D-21) — e o artefato que o CI \
             aprovou não é o artefato que entra em produção.
             """

      assert imagem =~ "docker/login-action",
             "o job publica sem autenticar no registro — o push vai falhar com 401"

      assert imagem =~ ~r/push:\s*\$\{\{/,
             """
             `push:` está cravado em vez de decidido pelo evento.

             PR tem de continuar só CONSTRUINDO (é o gate de Dockerfile); publicar é o que \
             acontece em push para `main`/`develop`, depois dos outros gates.
             """
    end

    test "a publicação cobra as variáveis que a CSP assa na imagem", %{ci: ci} do
      imagem = ci |> bloco_do_job("imagem") |> Enum.join("\n")

      for variavel <- ["WEB_HOST", "R2_ACCOUNT_ID"] do
        assert imagem =~ variavel,
               """
               O build de publicação não menciona `#{variavel}`.

               As duas entram na CSP em tempo de BUILD (`web/Dockerfile.prod`, `ARG`). Enquanto o \
               build acontecia no servidor, quem as fornecia era o Environment do stack no \
               Dokploy; movendo o build para o CI, a responsabilidade vem junto — e se elas \
               faltarem aqui, a imagem sobe com `connect-src` errado.

               O sintoma não é deploy vermelho: é WebSocket bloqueado e upload de anexo recusado \
               **no console do browser**, com o servidor perfeitamente verde.
               """
      end

      assert imagem =~ "::error",
             """
             O job não FALHA quando essas variáveis faltam.

             Publicar uma imagem com a CSP errada é pior do que não publicar: ela passa em todo \
             healthcheck e quebra só o que o usuário faz. Aborte o build.
             """
    end

    # DECIDIDO em 2026-08-05: **um lugar só** para configurar o repositório. Os três valores são
    # públicos por construção — o domínio e o id da conta R2 vão na CSP que todo browser recebe —,
    # então a aba Variables seria a semanticamente correta e é justamente por isso que esta escolha
    # precisa ficar presa: ela é uma preferência de operação, não uma consequência técnica, e sem
    # teste alguém a "corrige" de volta um dia por achar que foi engano.
    #
    # O custo aceito, para quem ler isto no futuro: o GitHub mascara secret em log, então a linha
    # de diagnóstico do passo imprime `host=***`.
    test "as três da CSP vêm da aba Secrets, junto com o resto", %{ci: ci} do
      alvo = passo_do_job(ci, "imagem", "Alvo do build")

      for variavel <- ~w(WEB_HOST_PROD WEB_HOST_HML R2_ACCOUNT_ID) do
        assert alvo =~ "secrets.#{variavel}",
               """
               `#{variavel}` não é lida de `secrets.` no passo que decide o alvo do build.

               Se ela voltou para `vars.`, o valor precisa estar na aba **Variables** — e quem \
               provisionou este repositório pôs tudo em **Secrets**. O sintoma é o build abortando \
               com "Secret de repositório ausente" sobre um valor que a pessoa jura ter criado.
               """
      end
    end
  end

  describe "job travado não queima o runner (R-B3)" do
    test "todo job declara timeout-minutes", %{ci: ci} do
      jobs = nomes_dos_jobs(ci)

      assert length(jobs) >= 4,
             "achei só #{length(jobs)} jobs (#{inspect(jobs)}) — a extração quebrou?"

      for job <- jobs do
        assert Enum.any?(bloco_do_job(ci, job), &Regex.match?(~r/^\s+timeout-minutes:/, &1)),
               "o job `#{job}` não declara `timeout-minutes` — travado, ele queima até o teto de 6 h do runner"
      end
    end
  end

  # Os nomes de job: duas casas de indentação sob `jobs:`, que é onde o GitHub os põe.
  defp nomes_dos_jobs(ci) do
    ci
    |> String.split("\njobs:", parts: 2)
    |> List.last()
    |> String.split("\n")
    |> Enum.flat_map(fn linha ->
      case Regex.run(~r/^  ([a-z][a-z0-9-]*):$/, linha) do
        [_todo, nome] -> [nome]
        nil -> []
      end
    end)
  end

  # O bloco de um job, do cabeçalho dele até o próximo no mesmo recuo. Mesma técnica do
  # `Api.ComposeDeProducao.servico/2` e **de propósito não é ela**: artefato diferente, mensagem de
  # falha diferente e limiar de vacuidade diferente. O risco que aquele módulo nomeia é fatiar *o
  # mesmo arquivo* de dois jeitos, não usar a mesma ideia em arquivos diferentes.
  defp bloco_do_job(ci, nome) do
    linhas = ci |> String.split("\njobs:", parts: 2) |> List.last() |> String.split("\n")

    inicio =
      Enum.find_index(linhas, &(&1 == "  #{nome}:")) ||
        flunk("job `#{nome}` não encontrado em #{@workflow}")

    bloco =
      linhas
      |> Enum.drop(inicio + 1)
      |> Enum.take_while(&(not Regex.match?(~r/^  \S/, &1)))

    assert length(bloco) > 3, "o recorte do job `#{nome}` devolveu #{length(bloco)} linhas"

    bloco
  end

  # UM passo do job, do `- name:` que casa `trecho` até o próximo `- name:` no mesmo recuo.
  #
  # Existe porque o recorte do job inteiro deixava a asserção **vaga**: medido, o job `deploy` já
  # continha `%{http_code}` no passo de VERIFICAÇÃO, então cobrar isso do job todo ficava verde
  # com o passo de disparo intocado — que é justamente o defeito. Anti-vacuidade do mesmo tipo que
  # o `Api.ComposeDeProducao.servico/2` faz por serviço.
  defp passo_do_job(ci, job, trecho) do
    linhas = bloco_do_job(ci, job)

    inicio =
      Enum.find_index(linhas, &Regex.match?(~r/^\s+- name:.*#{Regex.escape(trecho)}/, &1)) ||
        flunk("nenhum passo do job `#{job}` tem `- name:` contendo #{inspect(trecho)}")

    recuo =
      linhas
      |> Enum.at(inicio)
      |> then(&(String.length(&1) - String.length(String.trim_leading(&1))))

    passo =
      linhas
      |> Enum.drop(inicio + 1)
      |> Enum.take_while(&(not Regex.match?(~r/^\s{#{recuo}}- /, &1)))

    assert length(passo) > 2,
           "o recorte do passo #{inspect(trecho)} devolveu #{length(passo)} linhas"

    Enum.join(passo, "\n")
  end
end
