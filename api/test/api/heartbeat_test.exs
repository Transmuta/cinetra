defmodule Api.HeartbeatTest do
  @moduledoc """
  Sinal de vida dos crons (doc 62 §9).

  O que estes testes protegem não é o ping — é a **robustez do gancho**. Um heartbeat que quebra
  cria o pior estado possível: o monitor externo passa a alarmar "não rodou" a cada ciclo, o
  alarme vira falso, e a equipe aprende a ignorar justamente o aviso que um dia será verdade.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Api.Heartbeat

  setup do
    original = Application.get_env(:api, Heartbeat)
    on_exit(fn -> Application.put_env(:api, Heartbeat, original || []) end)
    :ok
  end

  defp configurar(urls), do: Application.put_env(:api, Heartbeat, urls: urls)

  defp configurar(base, slugs),
    do: Application.put_env(:api, Heartbeat, base_url: base, slugs: slugs)

  defp evento(tipo, worker) do
    Heartbeat.handle([:oban, :job, tipo], %{duration: 1}, %{job: %{worker: worker}}, nil)
  end

  describe "worker sem URL configurada" do
    test "é no-op silencioso — é o caso de dev e teste" do
      configurar(%{})

      assert capture_log(fn ->
               assert :ok = evento(:stop, "Api.Messaging.ReminderJob")
             end) == ""
    end

    test "não confunde um worker com outro" do
      configurar(%{"Api.Housekeeping.PruneTrail" => "http://localhost:1/hb"})

      # `SendJob` roda a cada mensagem; se ele casasse com o check de um cron, o monitor nunca
      # detectaria o cron parado — o sinal viria do job errado.
      assert :ok = evento(:stop, "Api.Messaging.SendJob")
    end
  end

  describe "a armadilha do :telemetry" do
    # `:telemetry` DESANEXA um handler que levanta, em silêncio e até o próximo boot. Sem o
    # `rescue`, um heartbeat com bug derrubaria a si mesmo — e o sintoma seria o monitor alarmando
    # para sempre.

    test "metadata em formato inesperado não levanta" do
      configurar(%{"X" => "http://localhost:1/hb"})

      assert :ok = Heartbeat.handle([:oban, :job, :stop], %{}, %{}, nil)
      assert :ok = Heartbeat.handle([:oban, :job, :stop], %{}, %{job: %{}}, nil)
      assert :ok = Heartbeat.handle([:oban, :job, :stop], %{}, %{job: %{worker: nil}}, nil)
    end

    test "evento de outra família não levanta" do
      configurar(%{"X" => "http://localhost:1/hb"})

      assert :ok = Heartbeat.handle([:oban, :job, :start], %{}, %{job: %{worker: "X"}}, nil)
      assert :ok = Heartbeat.handle([:qualquer, :outro], %{}, %{}, nil)
    end

    test "config ausente por completo não levanta" do
      Application.delete_env(:api, Heartbeat)

      assert :ok = evento(:stop, "Api.Messaging.ReminderJob")
    end

    test "monitor inalcançável não derruba nem trava o job" do
      # Ver armadilha 2 do moduledoc: o handler roda NO PROCESSO DO JOB. Uma chamada HTTP síncrona
      # seguraria o slot da fila pelo tempo da rede alheia. A porta 1 não atende ninguém.
      configurar(%{"Api.Messaging.ReminderJob" => "http://127.0.0.1:1/hb"})

      {micros, resultado} = :timer.tc(fn -> evento(:stop, "Api.Messaging.ReminderJob") end)

      assert resultado == :ok
      assert div(micros, 1000) < 200, "o ping bloqueou o processo do job"
    end
  end

  describe "o que chega no monitor" do
    # Socket cru em vez de mock: o que precisa ser provado é a URL que sai pelo fio. Errar o
    # sufixo é a falha mais perigosa deste módulo — o monitor registraria "ok" para um job que
    # estourou, e passaria a mentir exatamente no caso que ele existe para pegar.
    defp escutar do
      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, porta} = :inet.port(socket)
      {socket, porta}
    end

    defp primeira_linha(socket) do
      {:ok, conexao} = :gen_tcp.accept(socket, 5_000)
      {:ok, dados} = :gen_tcp.recv(conexao, 0, 5_000)
      :gen_tcp.close(conexao)
      dados |> String.split("\r\n") |> hd()
    end

    test "sucesso bate na URL nua" do
      {socket, porta} = escutar()
      configurar(%{"W" => "http://127.0.0.1:#{porta}/hb"})

      evento(:stop, "W")

      assert primeira_linha(socket) =~ "GET /hb "
      :gen_tcp.close(socket)
    end

    test "exceção bate em /fail" do
      {socket, porta} = escutar()
      configurar(%{"W" => "http://127.0.0.1:#{porta}/hb"})

      evento(:exception, "W")

      assert primeira_linha(socket) =~ "GET /hb/fail "
      :gen_tcp.close(socket)
    end
  end

  describe "resolução da URL (base + slug)" do
    # Uma env por ambiente em vez de 14 colagens de UUID. O que estes testes protegem é a
    # montagem: URL errada aqui significa monitor apontando para o check errado — e um check que
    # recebe sinal do job errado fica VERDE enquanto o job que ele deveria observar está morto.

    test "monta base + slug" do
      {socket, porta} = escutar()
      configurar("http://127.0.0.1:#{porta}/abc123", %{"W" => "reminder"})

      evento(:stop, "W")

      assert primeira_linha(socket) =~ "GET /abc123/reminder "
      :gen_tcp.close(socket)
    end

    test "barra sobrando na base não vira barra dupla" do
      {socket, porta} = escutar()
      configurar("http://127.0.0.1:#{porta}/abc123/", %{"W" => "reminder"})

      evento(:stop, "W")

      linha = primeira_linha(socket)
      assert linha =~ "GET /abc123/reminder "
      refute linha =~ "//"
      :gen_tcp.close(socket)
    end

    test "a falha vai para base/slug/fail" do
      {socket, porta} = escutar()
      configurar("http://127.0.0.1:#{porta}/abc123", %{"W" => "reminder"})

      evento(:exception, "W")

      assert primeira_linha(socket) =~ "GET /abc123/reminder/fail "
      :gen_tcp.close(socket)
    end

    test "worker sem slug é ignorado, mesmo com base configurada" do
      configurar("http://127.0.0.1:1/abc123", %{"W" => "reminder"})

      # `SendJob` roda a cada mensagem. Se caísse num slug qualquer, encheria um check alheio de
      # sinal e o esconderia para sempre.
      assert :ok = evento(:stop, "Api.Messaging.SendJob")
    end

    test "base vazia desliga — não monta URL relativa" do
      configurar("", %{"W" => "reminder"})
      assert :ok = evento(:stop, "W")

      configurar(nil, %{"W" => "reminder"})
      assert :ok = evento(:stop, "W")
    end

    test "URL explícita tem precedência sobre o slug" do
      {socket, porta} = escutar()

      Application.put_env(:api, Heartbeat,
        base_url: "http://127.0.0.1:#{porta}/base",
        slugs: %{"W" => "slug-derivado"},
        urls: %{"W" => "http://127.0.0.1:#{porta}/explicita"}
      )

      evento(:stop, "W")

      # Quem configurou a URL cheia fez uma escolha; derivar por cima seria ignorá-la calado.
      assert primeira_linha(socket) =~ "GET /explicita "
      :gen_tcp.close(socket)
    end
  end

  describe "attach/0" do
    test "é idempotente — rebootar não duplica o handler" do
      assert :ok = Heartbeat.attach()
      assert :ok = Heartbeat.attach()

      anexados =
        [:oban, :job, :stop]
        |> :telemetry.list_handlers()
        |> Enum.count(&(&1.id == Heartbeat))

      assert anexados == 1

      :telemetry.detach(Heartbeat)
    end

    test "cobre sucesso E falha — 'não rodou' e 'rodou e falhou' são investigações diferentes" do
      Heartbeat.attach()

      # `list_handlers/1` recebe um PREFIXO de evento, não o id do handler.
      eventos =
        [:oban, :job]
        |> :telemetry.list_handlers()
        |> Enum.filter(&(&1.id == Heartbeat))
        |> Enum.map(& &1.event_name)

      assert [:oban, :job, :stop] in eventos
      assert [:oban, :job, :exception] in eventos

      :telemetry.detach(Heartbeat)
    end
  end
end
