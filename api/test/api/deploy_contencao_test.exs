defmodule Api.DeployContencaoTest do
  @moduledoc """
  Os **freios**: o que não causa nada sozinho, e decide o tamanho do estrago quando algo dá errado.
  Onda 2 do [doc 102](../../../docs/102-plano-de-acao-infraestrutura.md) — R-A4, R-A7, R-A6, R-B8,
  R-M2, R-M11, R-M12 e R-M16 do [doc 95](../../../docs/95-analise-infraestrutura.md).

  Todo item aqui é invisível enquanto nada falha. É por isso que eles ficam para depois da onda 1 —
  e é por isso que precisam de um teste: nada no uso normal os cobra.

  ## Por que teto de memória, se a máquina medida usa 3,5 GB dos 8 GB

  Porque teto não é previsão de consumo — é o **limite do pior caso**. O [doc 87
  §2.1](../../../docs/87-servidor-hostinger-riscos-e-cuidados.md) registra exatamente o erro de
  confundir os dois: a estimativa somou `mem_limit` como se fosse consumo e errou por ~3×.

  Sem teto, quem escolhe a vítima de um vazamento é o `oom_score` do kernel, que privilegia o
  processo **maior** — com boa chance o Postgres. Um vazamento no BFF derruba o banco. E o
  agravante já estava escrito em `87:145-155`: o alerta `cinetra-container-no-teto` filtra por
  `container_spec_memory_limit_bytes > 0`, então os containers **sem** teto ficavam fora do alerta
  que vigia teto — por construção, e eram justamente os que servem o paciente.

  **O que o teto NÃO faz, dito com precisão:** a soma dos tetos aqui declarados passa da RAM da
  máquina, e isso é deliberado — teto é bound de pior caso, não reserva. Ele impede **um** container
  de comer tudo; ele não impede o esgotamento agregado. Quem responde por isso é a medição sob
  carga real, que é o [D-21](../../../docs/50-debitos-tecnicos.md).

  ## Healthcheck do Docker ≠ healthcheck do Traefik

  Distinção que o doc 87 §4.7 não fazia e que muda o resultado: **o do Traefik decide roteamento;
  o do Docker decide reinício.** Com o processo travado sem morrer — event loop bloqueado no Node,
  pool esgotado no BEAM —, o Traefik tira da rotação (bom) e o Docker continua reportando `Up`, de
  modo que `restart: unless-stopped` nunca dispara. O container fica zumbi indefinidamente. Só o
  primeiro existia.

  ## O limite honesto de todo este arquivo

  Ele prova **configuração declarada**. Que o teto contenha de fato um vazamento, que o healthcheck
  de fato reinicie um processo travado e que o Grafana de fato suba com o Loki degradado são
  comportamentos que só o servidor mostra. O que estes testes impedem é a configuração **sumir em
  silêncio** — que é como ela nunca chegou a existir.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Compose

  # Os que ficam de pé. O `migrate` é one-shot (`restart: "no"`) — teto de memória num processo
  # que roda uma vez e morre protege contra nada.
  @produto_longa_duracao ~w(db api web)

  # Os 8 da observabilidade (o `docker-proxy` nasceu na onda 5). O `tempo` aparece nas asserções de teto e de log, mas **não** na de
  # healthcheck: a imagem é distroless e todo `test:` falha por falta de `/bin/sh`, deixando o
  # container eternamente `unhealthy` com o serviço perfeito. Essa ausência é justificada por
  # escrito em `compose.obs.yml:426-435` e quem a verifica é o `verificar.sh` §14, de fora.
  @obs_servicos ~w(docker-proxy loki grafana prometheus node-exporter cadvisor tempo alloy)
  @obs_sem_healthcheck ~w(tempo)

  setup_all do
    {:ok, produto: Compose.ler(), obs: Compose.ler_obs()}
  end

  describe "teto de memória (R-A4)" do
    test "todo serviço de longa duração do produto declara mem_limit", %{produto: compose} do
      for nome <- @produto_longa_duracao do
        assert declara?(compose, nome, "mem_limit"),
               """
               O serviço `#{nome}` não declara `mem_limit`.

               Sem teto, quem escolhe a vítima de um vazamento é o `oom_score` do kernel, que \
               privilegia o processo MAIOR — com boa chance o Postgres. Um vazamento no BFF \
               derruba o banco.

               E o container sem teto fica fora do alerta `cinetra-container-no-teto` por \
               construção: ele filtra por `container_spec_memory_limit_bytes > 0`.
               """
      end
    end

    test "e os da observabilidade continuam declarando", %{obs: compose} do
      for nome <- @obs_servicos, do: assert(declara?(compose, nome, "mem_limit"))
    end
  end

  describe "healthcheck do Docker (R-A7, R-B8)" do
    test "api e web declaram healthcheck — o do Traefik não reinicia nada", %{produto: compose} do
      for nome <- ~w(api web) do
        assert declara?(compose, nome, "healthcheck"),
               """
               O serviço `#{nome}` não declara `healthcheck` de Docker.

               Os labels do Traefik que ele tem decidem ROTEAMENTO. Com o processo travado sem \
               morrer, o Traefik tira da rotação e o Docker segue reportando `Up` — então \
               `restart: unless-stopped` nunca dispara e o container fica zumbi. São dois \
               mecanismos e só um existia.
               """
      end
    end

    test "os serviços da obs declaram healthcheck, exceto o Tempo", %{obs: compose} do
      for nome <- @obs_servicos, nome not in @obs_sem_healthcheck do
        assert declara?(compose, nome, "healthcheck"), "`#{nome}` (obs) sem healthcheck"
      end
    end

    # A contraprova. Se alguém "consertar" a ausência do Tempo, ganha um container eternamente
    # `unhealthy` com o serviço perfeito — e a lição de `compose.obs.yml:426-435` se perde.
    test "o Tempo continua SEM healthcheck, e isso é a decisão registrada", %{obs: compose} do
      refute declara?(compose, "tempo", "healthcheck"),
             "o Tempo ganhou healthcheck — a imagem é distroless e todo `test:` falha por falta de /bin/sh"
    end
  end

  describe "memória compartilhada do Postgres (R-M2)" do
    test "o db declara shm_size", %{produto: compose} do
      assert declara?(compose, "db", "shm_size"),
             """
             `/dev/shm` fica no default de 64 MB do Docker.

             Uma query com plano paralelo — os agregados das views `metrics_*` e os relatórios são \
             candidatos — falha com `could not resize shared memory segment […] No space left on \
             device`. Sintoma que não parece disco e não parece memória, e por isso custa caro.
             """
    end
  end

  describe "rotação de log dos containers de observabilidade (R-A6)" do
    test "todo serviço da obs declara logging", %{obs: compose} do
      for nome <- @obs_servicos do
        assert declara?(compose, nome, "logging"),
               """
               `#{nome}` (obs) não declara `logging` — fica no `json-file` SEM LIMITE do Docker.

               E como `cinetra-obs` está deliberadamente fora da allowlist de coleta, esses \
               arquivos não são embarcados nem consultáveis: crescem invisíveis, no mesmo disco do \
               `pgdata`. É a ferramenta de disco cheio enchendo o disco.
               """
      end
    end
  end

  describe "teto de CPU na observabilidade (R-M12)" do
    test "todo serviço da obs declara cpus", %{obs: compose} do
      for nome <- @obs_servicos do
        assert declara?(compose, nome, "cpus"),
               """
               `#{nome}` (obs) não declara `cpus`.

               `mem_limit` não contém consulta ligada a CPU. Uma consulta LogQL de 30 dias — aberta \
               DURANTE um incidente, que é quando o painel é usado — descomprime e varre chunks, \
               satura os 2 vCPU, a BEAM entra em `run_queue` e o p95 sobe. A ferramenta de \
               diagnóstico vira a causa.
               """
      end
    end
  end

  describe "o motor de alerta não depende de uma das fontes (R-M16)" do
    test "o Grafana não espera o Loki ficar saudável para subir", %{obs: compose} do
      bloco = Compose.servico(compose, "grafana")

      depende_de_loki_saudavel? =
        bloco
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.any?(fn linhas ->
          Enum.any?(linhas, &(&1 =~ ~r/^\s+loki:/)) and
            Enum.any?(linhas, &(&1 =~ ~r/condition:\s*service_healthy/))
        end)

      refute depende_de_loki_saudavel?,
             """
             O Grafana declara `depends_on: loki: condition: service_healthy`.

             Ele hospeda TODAS as 9 regras de alerta, inclusive as 4 que só leem o Prometheus. \
             Reboot da máquina com o volume do Loki cheio ou com permissão errada (o caso previsto \
             em `criar-volume-limitado.sh:52-55`) → o healthcheck do Loki nunca passa → o Grafana \
             NUNCA SOBE → somem junto os alertas de disco e de memória, que são os que diriam o \
             que está acontecendo.

             `restart: unless-stopped` não ajuda: o `depends_on` bloqueia a partida.
             """
    end
  end

  # `^\s+chave:` dentro do bloco do serviço, e não `compose =~ chave`: os dois arquivos CITAM
  # essas chaves em comentários que explicam por que elas existem, e um comentário casaria com a
  # busca no texto inteiro. É a mesma lição que está escrita no `servico/2`.
  defp declara?(compose, servico, chave) do
    compose
    |> Compose.servico(servico)
    |> Enum.any?(&Regex.match?(~r/^\s+#{Regex.escape(chave)}:/, &1))
  end
end
