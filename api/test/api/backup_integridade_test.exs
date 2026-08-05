defmodule Api.BackupIntegridadeTest do
  @moduledoc """
  R-M10 (doc 95, onda 1 do doc 102): o `backup.sh` declarava sucesso sem nunca ter **aberto** o
  dump que acabou de gerar.

  ## O buraco

  O script gerava (`pg_dump`), subia (`rclone copyto`) e sinalizava o heartbeat — e entre gerar e
  sinalizar não havia leitura nenhuma do arquivo. Um dump truncado (disco cheio no meio do
  `pg_dump`, que é o cenário do R-M11, onde o `mktemp` divide disco com o `pgdata`) sobe inteiro
  para o R2 e o monitor externo recebe **"ok"**.

  Isso é pior que não monitorar: o heartbeat é a única coisa que responde "o backup está vivo?", e
  ele passa a responder sim para um arquivo que não restaura. A descoberta fica para o dia do
  incidente, que é exatamente quando não há segunda chance. O `restore.sh:5` já dizia a frase
  certa — *"backup não testado não é backup"* — e dependia de um humano lembrar.

  ## A recomendação original estava errada, e a medição foi quem disse

  O [doc 95](../../../docs/95-analise-infraestrutura.md) (R-M10) pedia `pg_restore --list`. Medido
  contra o `db` em 2026-08-04, ele **não serve**: `--list` lê apenas o TOC, que no formato custom
  fica no início do arquivo, e sai **0** sobre um dump cortado ao meio e sobre um dump com 512
  bytes zerados no meio dos dados. Quem adotasse a recomendação teria uma verificação decorativa —
  e uma falsa sensação de cobertura, que é o mesmo defeito do R-C1 num lugar diferente.

  O que funciona é `pg_restore -f /dev/null`: converte o arquivo inteiro em SQL e descarta,
  obrigando a leitura e a descompressão de cada bloco. Nos mesmos dois arquivos ruins ele sai 1,
  com `could not read from input file: end of file` e `could not uncompress data: incorrect data
  check`. É por isso que o teste prende o `-f`, e não uma menção genérica a `pg_restore`.

  ## O que este teste prova, e o que ele não prova

  Ele prova a **ordem**: que existe uma verificação do dump e que ela vem ANTES do sinal de
  sucesso. As duas regressões plausíveis são exatamente essas duas — alguém remove a linha, ou
  alguém a move para depois do `sinal` (onde ela não protege nada, porque o "ok" já foi enviado).

  Ele **não** re-executa a medição acima: comportamento de binário de terceiro foi medido ao vivo
  e está registrado no doc 102 §4. Rodar o script de verdade aqui exigiria `rclone`, credencial do
  R2 e `age`, o que faria o teste depender da rede para provar uma linha de ordenação.

  ## Por que em Elixir, e não num teste de shell

  O repositório não tem framework de teste de shell, e montar um para um script de 90 linhas seria
  desproporcional. Este arquivo segue o precedente que já existe para artefato de deploy fora de
  `api/`: `Api.DeployEnvTest` e `Api.DeployCicloDeVidaTest` leem o `compose.dokploy.yml` pela mesma
  razão e com a mesma técnica.
  """

  use ExUnit.Case, async: true

  # Mesma dupla de caminhos do `Api.ComposeDeProducao`, e pelo mesmo motivo: no CI o checkout
  # inteiro está ao lado (`../`); no container de dev, onde só `api/` é montado em `/app`, o
  # `docker-compose.yml` monta a raiz do repositório em `/repo`. Sem o segundo, o teste pularia
  # justamente onde se desenvolve.
  @caminhos ["../deploy/backup/backup.sh", "/repo/deploy/backup/backup.sh"]

  # A linha que manda "sucesso" ao heartbeat: `sinal` sem argumento. Com argumento (`sinal /fail`)
  # é o oposto, então o casamento precisa ser do começo ao fim da linha.
  @sinal_de_sucesso ~r/^\s*sinal\s*$/

  # `-f` e não `--list`, e a diferença é a correção mais importante deste arquivo: `pg_restore
  # --list` lê apenas o TOC, que no formato custom mora no INÍCIO do arquivo, e por isso sai 0
  # sobre um dump em que todo o dado se perdeu. Medido (doc 102 §4): cortado ao meio → `--list`
  # sai 0, `-f /dev/null` sai 1. Se alguém "simplificar" esta linha de volta para `--list`, a
  # verificação volta a ser decorativa — então é o `-f` que este teste prende.
  @verificacao_do_dump ~r/pg_restore\s+-f\s/

  # A conferência de espaço livre: `pg_database_size` do lado do banco contra `df` do lado do
  # disco. Casa a linha do `df` porque é ela que só existe se a conferência existir.
  @preflight_de_disco ~r/df\s/

  setup_all do
    caminho =
      Enum.find(@caminhos, &File.exists?/1) ||
        flunk("backup.sh não encontrado em nenhum de: #{Enum.join(@caminhos, ", ")}")

    {:ok, linhas: caminho |> File.read!() |> String.split("\n")}
  end

  test "o dump é aberto e verificado antes de o backup ser declarado bom", %{linhas: linhas} do
    verificacao = indice(linhas, @verificacao_do_dump)
    sucesso = indice(linhas, @sinal_de_sucesso)

    assert verificacao,
           """
           `backup.sh` não verifica o dump em lugar nenhum (nenhum `pg_restore -f`).

           Um dump truncado — disco cheio no meio do `pg_dump` — sobe para o R2 e o heartbeat diz \
           "ok". O sinal que existe para responder "o backup está vivo?" passa a mentir, e a \
           descoberta fica para o dia do incidente.
           """

    assert sucesso, "`backup.sh` não tem mais a linha de sinal de sucesso — este teste ficou cego"

    assert verificacao < sucesso,
           """
           A verificação do dump está na linha #{verificacao + 1} e o sinal de sucesso na \
           #{sucesso + 1} — ou seja, o heartbeat recebe "ok" ANTES de alguém abrir o arquivo.

           Verificar depois de sinalizar não protege nada: o monitor externo já registrou o \
           sucesso. A ordem é a proteção inteira.
           """
  end

  # R-M11 (onda 2). O volume dedicado do compose torna o espaço do dump CONTÁVEL; ele não muda de
  # disco físico numa VPS de disco único, então quem de fato impede o dump de encher o disco do
  # banco é esta conferência — e ela só serve ANTES do `pg_dump`, porque abortar no meio já
  # consumiu o espaço.
  #
  # O agravante que torna isto mais que higiene: o serviço `backup` roda **antes** do `migrate` e é
  # fail-closed. Disco cheio durante o dump vira **deploy travado** por cima de disco cheio — e o
  # deploy travado costuma ser o hotfix do próprio incidente.
  test "o espaço livre é conferido ANTES de começar o dump", %{linhas: linhas} do
    preflight = indice(linhas, @preflight_de_disco)
    dump = indice(linhas, ~r/^pg_dump /)

    assert is_integer(preflight),
           """
           `backup.sh` não confere espaço livre antes do `pg_dump`.

           Sem isso, um disco quase cheio produz um dump truncado (ou enche o disco do `pgdata` \
           tentando) — e a verificação de integridade, que agora existe, só descobre isso depois \
           de o espaço já ter sido consumido.
           """

    assert is_integer(dump), "a linha do `pg_dump` sumiu — este teste ficou cego"
    assert preflight < dump, "a conferência de espaço está DEPOIS do pg_dump — não previne nada"
  end

  test "a verificação roda sob `set -e`, para que o trap ERR alcance a falha", %{linhas: linhas} do
    assert indice(linhas, ~r/^set -euo pipefail/),
           "sem `set -e` a saída != 0 do pg_restore não abortaria o script — e o `trap ERR` nunca dispararia"

    trap = indice(linhas, ~r/^trap 'sinal \/fail' ERR/)
    verificacao = indice(linhas, @verificacao_do_dump)

    # `is_integer` nos dois ANTES de comparar: em Elixir `50 < nil` é **true** (nil ordena acima de
    # número), então sem estas duas linhas esta asserção passava verde com a verificação ausente —
    # a mesma vacuidade que mordeu o `Api.DeployCicloDeVidaTest` na primeira execução dele.
    assert is_integer(trap), "o `trap ... ERR` sumiu do backup.sh"
    assert is_integer(verificacao), "a verificação do dump sumiu do backup.sh"

    # O `trap` precisa estar declarado ANTES da verificação, senão a falha dela sai silenciosa: o
    # script morre por `set -e` sem nunca mandar `/fail`, e o heartbeat lê isso como "não rodou",
    # que é indistinguível de "o cron parou".
    assert trap < verificacao,
           "o `trap ... ERR` precisa ser declarado antes da verificação, senão a falha dela não avisa ninguém"
  end

  defp indice(linhas, regex), do: Enum.find_index(linhas, &Regex.match?(regex, &1))
end
