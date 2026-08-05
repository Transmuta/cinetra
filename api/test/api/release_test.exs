defmodule Api.ReleaseTest do
  @moduledoc """
  `Api.Release` é o que roda no **caminho crítico do deploy** — `bin/api eval Api.Release.setup()`,
  pelo serviço `migrate` do `compose.dokploy.yml`, antes de a API subir. Ele aplica as migrations e
  provisiona os dois roles do banco.

  R-M23 (doc 95, onda 3 do doc 102): era o código **menos testado** de todo o caminho de deploy —
  um único teste, sobre validação de identificador. `setup/0`, `migrate/0`, `setup_metrics_role/0`
  e o `with_admin_config/1` não tinham cobertura nenhuma.

  ## A regressão que mais importa, e por que ela é invisível

  `with_admin_config/1` aponta o Repo para a conexão de **owner** (`DATABASE_ADMIN_URL`), roda a
  função e restaura a config no `after`. Se esse `after` sumir — ou se alguém trocar o `try/after`
  por um `try/rescue` distraído —, o processo segue com o Repo apontando para o owner.

  O owner **bypassa RLS**. E a suíte inteira já roda como superusuário, então ela não veria: este
  é exatamente o tipo de buraco que o job `api-rls` existe para cobrir em *outro* lugar, e que
  aqui não tem quem cubra. Daí os testes abaixo, em especial o do caminho de exceção — porque o
  caminho feliz restaura por acidente em qualquer implementação, e só o de erro distingue
  `try/after` de "restaurei no fim da função".

  ## Por que `async: false`

  Estes testes mexem em `Application.put_env(:api, Api.Repo, …)` e em variáveis de ambiente do
  sistema, que são estado **global** do nó. Rodar em paralelo com qualquer teste que use o Repo
  produziria falha intermitente — e intermitência num teste de RLS é pior que ausência de teste,
  porque ensina a equipe a re-rodar até passar.
  """
  use ExUnit.Case, async: false

  @repo_config_original Application.compile_env(:api, Api.Repo, [])

  describe "validação do identificador (a injeção que CREATE ROLE permitiria)" do
    # `CREATE ROLE` não aceita bind params, então o nome do role é interpolado no SQL. A validação
    # é o que separa isso de uma injeção — e ela roda ANTES de tocar o banco.
    test "setup_app_role/0 recusa DATABASE_APP_USER que não é identificador SQL" do
      com_env(%{
        "DATABASE_APP_USER" => "app\"; DROP TABLE users; --",
        "DATABASE_APP_PASSWORD" => "irrelevante"
      })

      assert_raise ArgumentError, ~r/identificador SQL/, fn -> Api.Release.setup_app_role() end
    end

    test "setup_metrics_role/0 aplica a mesma validação ao usuário de métricas" do
      com_env(%{
        "DATABASE_METRICS_PASSWORD" => "irrelevante",
        "DATABASE_METRICS_USER" => "metrics; GRANT ALL ON patients TO PUBLIC; --"
      })

      assert_raise ArgumentError, ~r/identificador SQL/, fn ->
        Api.Release.setup_metrics_role()
      end
    end
  end

  describe "setup_metrics_role/0 — ausente é DESLIGADO, não erro" do
    # O painel de banco é opcional por decisão registrada (doc 73): sem a senha o role não é
    # criado, e os painéis ficam com erro de datasource VISÍVEL, em vez de painel vazio que
    # ninguém desconfia. O que este teste prende é que a ausência não derruba o `setup/0` inteiro
    # — ou seja, que um deploy sem Grafana continua deployando.
    test "sem DATABASE_METRICS_PASSWORD devolve :desligado sem tocar o banco" do
      sem_env(["DATABASE_METRICS_PASSWORD"])

      assert Api.Release.setup_metrics_role() == :desligado
    end

    test "senha vazia conta como ausente" do
      com_env(%{"DATABASE_METRICS_PASSWORD" => ""})

      assert Api.Release.setup_metrics_role() == :desligado
    end
  end

  describe "with_admin_config/1 — o Repo não pode ficar apontado para o owner (R-M23)" do
    test "durante a função, a url é a de admin" do
      com_env(%{"DATABASE_ADMIN_URL" => "ecto://owner:senha@db/cinetra"})

      vista = Api.Release.with_admin_config(fn -> url_configurada() end)

      assert vista == "ecto://owner:senha@db/cinetra"
    end

    test "depois da função, a config volta ao que era" do
      antes = Application.get_env(:api, Api.Repo, [])
      com_env(%{"DATABASE_ADMIN_URL" => "ecto://owner:senha@db/cinetra"})

      Api.Release.with_admin_config(fn -> :ok end)

      assert Application.get_env(:api, Api.Repo, []) == antes
    end

    # **O teste que importa.** O caminho feliz restauraria por acidente em quase qualquer
    # implementação; só o caminho de exceção distingue um `try/after` de um "restaurei na última
    # linha da função". E o caminho de exceção é o real: uma migration que falha é o motivo de o
    # `migrate` existir como serviço fail-closed.
    test "restaura mesmo quando a função levanta" do
      antes = Application.get_env(:api, Api.Repo, [])
      com_env(%{"DATABASE_ADMIN_URL" => "ecto://owner:senha@db/cinetra"})

      assert_raise RuntimeError, "migration explodiu", fn ->
        Api.Release.with_admin_config(fn -> raise "migration explodiu" end)
      end

      assert Application.get_env(:api, Api.Repo, []) == antes,
             """
             A config do Repo NÃO voltou depois de a função levantar.

             O processo segue apontando para a conexão de OWNER, que bypassa RLS. A suíte não vê \
             isso — ela já roda como superusuário —, e é por isso que este teste existe: é a \
             regressão mais cara possível neste arquivo e a que menos dá sintoma.
             """
    end

    # Sem `DATABASE_ADMIN_URL` a função não deve mexer em nada: é o caso dos setups em que a
    # própria `DATABASE_URL` já é de owner (dev, CI).
    test "sem DATABASE_ADMIN_URL não toca a configuração" do
      sem_env(["DATABASE_ADMIN_URL"])
      antes = Application.get_env(:api, Api.Repo, [])

      assert Api.Release.with_admin_config(fn -> url_configurada() end) == antes[:url]
      assert Application.get_env(:api, Api.Repo, []) == antes
    end

    # A troca é só do `:url`. Se ela passasse a substituir a config inteira, `pool_size`,
    # `socket_options` e o resto do que o `runtime.exs` monta sumiriam durante o `migrate` — e o
    # sintoma seria um deploy lento ou um timeout, sem nada apontando para cá.
    test "preserva as demais chaves da configuração enquanto roda" do
      Application.put_env(:api, Api.Repo, pool_size: 3, url: "ecto://app@db/x", timeout: 1234)
      on_exit(fn -> Application.put_env(:api, Api.Repo, @repo_config_original) end)
      com_env(%{"DATABASE_ADMIN_URL" => "ecto://owner@db/x"})

      config = Api.Release.with_admin_config(fn -> Application.get_env(:api, Api.Repo) end)

      assert config[:url] == "ecto://owner@db/x"
      assert config[:pool_size] == 3
      assert config[:timeout] == 1234
    end
  end

  defp url_configurada, do: Application.get_env(:api, Api.Repo, [])[:url]

  defp com_env(mapa) do
    anteriores = Map.new(mapa, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(mapa, fn {k, v} -> System.put_env(k, v) end)
    on_exit(fn -> restaurar_env(anteriores) end)
  end

  defp sem_env(chaves) do
    anteriores = Map.new(chaves, &{&1, System.get_env(&1)})
    Enum.each(chaves, &System.delete_env/1)
    on_exit(fn -> restaurar_env(anteriores) end)
  end

  defp restaurar_env(anteriores) do
    Enum.each(anteriores, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)
  end
end
