defmodule Api.SegredoNoWorkingTreeTest do
  @moduledoc """
  R-C3 (doc 95, onda 1 do doc 102): a chave privada `age` que **decifra todo backup de produção**
  estava no working tree desta máquina de desenvolvimento.

  ## Por que isso é o pior achado da auditoria

  Um `.dump.age` do R2 sem a chave é ruído. Com a chave, é o banco inteiro: nome, CPF, telefone,
  e-mail e evolução clínica de todo paciente de todas as clínicas. O desenho diz o contrário em
  dois lugares — `deploy/backup/backup.sh` (*"a chave privada fica offline, usada só no restore"*)
  e `deploy/backup/restore.sh` (*"que vive FORA do servidor"*) — enquanto as duas metades do cofre
  estavam a uma pasta de distância uma da outra, numa estação que roda navegador e instala
  dependências de npm e de hex.

  ## As duas asserções, e por que são duas

  **1. A regra de ignore é um PADRÃO, não um nome.** O `.gitignore` protegia a string exata
  `cinetra-prod-age.key`. Verificado antes do conserto: `git check-ignore cinetra-hml-age.key` não
  casava. Ou seja, a guarda cobria a chave que já existia e deixava passar a próxima — a de HML, ou
  a rotação `cinetra-prod-age-2.key`, que é justamente o arquivo que aparece no dia em que alguém
  faz a coisa certa.

  **2. Não há chave nenhuma no working tree.** Esta é a que fecha o risco de verdade. A primeira
  só garante que a chave não vai para o commit; ela não impede a chave de **estar aqui**, e estar
  aqui já basta para um backup de home para nuvem pessoal, um `tar` da pasta do projeto ou
  qualquer comprometimento da estação reunir as duas metades.

  ## O limite honesto

  Este teste prova que a chave não está **neste diretório**. Ele não prova, e não tem como provar,
  que ela está guardada num lugar seguro — para onde a cópia foi é inverificável por automação. Se
  ela já circulou aqui, a postura barata é tratá-la como comprometida: gerar par novo e re-cifrar
  ou descartar os dumps antigos.
  """

  use ExUnit.Case, async: true

  # Mesma dupla de raízes do `Api.ComposeDeProducao`, pela mesma razão: no CI o checkout inteiro
  # está em `../`; no container de dev, onde só `api/` é montado em `/app`, a raiz do repositório
  # vem em `/repo` só-leitura.
  @raizes ["..", "/repo"]

  # `.key` e `.pem` porque são as duas extensões que aparecem em material de chave privada. O
  # `.pub` é o par PÚBLICO do `age` — ele PODE e deve viver no repositório (é o `recipient` que o
  # `backup.sh` usa para cifrar), então a regra precisa excluí-lo explicitamente.
  @extensoes_de_chave ~w(.key .pem)

  setup_all do
    raiz =
      Enum.find(@raizes, &File.exists?(Path.join(&1, ".gitignore"))) ||
        flunk("raiz do repositório não encontrada em nenhuma de: #{Enum.join(@raizes, ", ")}")

    {:ok, raiz: raiz, gitignore: raiz |> Path.join(".gitignore") |> File.read!()}
  end

  test "o .gitignore barra chave por PADRÃO, não pelo nome de uma chave específica", %{
    gitignore: gitignore
  } do
    regras = gitignore |> String.split("\n") |> Enum.map(&String.trim/1)

    assert "*.key" in regras,
           """
           O `.gitignore` não tem a regra `*.key`.

           Uma regra por NOME EXATO (como `cinetra-prod-age.key` era) cobre só a chave que já \
           existe. A próxima — a de HML, ou a rotação `cinetra-prod-age-2.key` — entra no commit, \
           e ela aparece justamente no dia em que alguém faz a coisa certa e rotaciona.
           """

    assert "!*.pub" in regras,
           """
           Falta a exceção `!*.pub`.

           A chave PÚBLICA do age precisa poder viver no repositório: é o `recipient` com que o \
           `backup.sh` cifra. Sem a exceção, uma regra ampla demais esconderia a metade que É \
           para ser versionada — e o sintoma seria o backup parar de cifrar em silêncio.
           """
  end

  test "não há chave privada no working tree", %{raiz: raiz} do
    chaves =
      raiz
      |> File.ls!()
      |> Enum.filter(fn nome -> Enum.any?(@extensoes_de_chave, &String.ends_with?(nome, &1)) end)
      |> Enum.sort()

    assert chaves == [],
           """
           Há material de chave privada na raiz do repositório: #{inspect(chaves)}

           Se for a chave `age` de produção, ela DECIFRA TODO BACKUP: nome, CPF, telefone, e-mail \
           e evolução clínica de todos os pacientes de todas as clínicas. O `backup.sh` afirma, \
           por escrito, que ela "fica offline, usada só no restore" — e o `restore.sh`, que ela \
           "vive FORA do servidor".

           Tire-a desta máquina. E se ela já esteve aqui, trate-a como comprometida: gere par \
           novo e re-cifre (ou descarte) os dumps antigos.
           """
  end
end
