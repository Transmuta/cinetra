defmodule Api.Housekeeping.PruneMessagesTest do
  @moduledoc """
  A poda de `messages` — **os dois relógios** (doc 101, M10 · `[D-11]`).

  A linha de `messages` acumula dois papéis com prazos diferentes: a **prova de que a clínica
  avisou** (que dispensou o `AshPaperTrail` justamente porque o registro é o histórico) e o **dado
  pessoal do titular** (`vars` com o nome do paciente, `destino` com o telefone ou e-mail
  congelado). Um número só erraria dos dois lados.

  O que este teste afirma:

    * sem política configurada, o job **não toca em nada** — é o desenho do D-11, e é o que
      impede uma régua de ninguém de entrar em produção no dia em que alguém puser o cron;
    * a janela curta **anonimiza sem apagar**: some o dado pessoal, fica a prova;
    * a janela longa apaga a linha;
    * o laço da anonimização **termina** (a condição exclui o que já foi anonimizado);
    * a poda não atravessa clínica.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Housekeeping.PruneMessages

  # As duas janelas do teste, passadas por `args` — nunca por config global, que vazaria para os
  # outros testes do arquivo.
  @curta 90
  @longa 1825

  # Paciente alcançável: consentimento + e-mail. O `clinica/1` cria um com telefone só, e sem
  # WhatsApp ligado o `Dispatch` devolve `{:skip, :canal_indisponivel}` — não haveria mensagem
  # nenhuma para podar.
  defp mensagem(ctx) do
    paciente = paciente_com(ctx, comunicacao: true, email: "p#{unico()}@example.com")
    appt = agendamento!(ctx, paciente: paciente)
    confirmacao!(ctx, appt, paciente)
  end

  # `inserted_at` é carimbo do banco e não há ação que o mova.
  defp envelhecer(id, dias) do
    Api.Repo.query!(
      "UPDATE messages SET inserted_at = inserted_at - ($1 || ' days')::interval WHERE id = $2",
      [to_string(dias), Ecto.UUID.dump!(id)]
    )
  end

  defp linha(id) do
    {:ok, %{rows: rows}} =
      Api.Repo.query(
        "SELECT vars, destino, status, provider_message_id, kind FROM messages WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    case rows do
      [[vars, destino, status, provider, kind]] ->
        %{vars: vars, destino: destino, status: status, provider: provider, kind: kind}

      [] ->
        nil
    end
  end

  defp podar(args \\ %{"reter_pii_dias" => @curta, "reter_dias" => @longa}),
    do: perform_job(PruneMessages, args)

  describe "sem política configurada" do
    # O ponto do D-11: o mecanismo existe e fica **desarmado** até alguém decidir o número. Se este
    # teste virar verde de outro jeito (um default embutido no módulo), a régua de ninguém entra em
    # produção calada no dia em que a linha do cron for escrita.
    test "não toca em linha nenhuma, e diz por quê" do
      ctx = clinica()
      m = mensagem(ctx)
      envelhecer(m.id, 10_000)

      assert {:ok, %{anonimizadas: 0, apagadas: 0, pendente: :politica}} =
               perform_job(PruneMessages, %{})

      assert %{destino: destino} = linha(m.id)
      assert destino != "[podado]"
    end

    test "meia política também é ausência de política" do
      assert PruneMessages.politica(%{"reter_pii_dias" => 90}) == :sem_politica
      assert PruneMessages.politica(%{"reter_dias" => 1825}) == :sem_politica
      assert PruneMessages.politica(%{}) == :sem_politica
    end

    # Anonimizar DEPOIS de apagar seria a mesma coisa que não anonimizar: a janela do dado pessoal
    # tem de ser a mais curta das duas, e política invertida é erro de digitação com consequência
    # de vazamento.
    test "janela de PII maior que a da linha é recusada" do
      assert PruneMessages.politica(%{"reter_pii_dias" => 2000, "reter_dias" => 90}) ==
               :sem_politica
    end
  end

  describe "a janela curta anonimiza sem apagar" do
    setup do
      ctx = clinica()
      m = mensagem(ctx)
      %{ctx: ctx, m: m}
    end

    test "some o dado pessoal, fica a prova", %{m: m} do
      antes = linha(m.id)
      assert antes.destino != "[podado]"
      assert map_size(antes.vars) > 0

      envelhecer(m.id, @curta + 1)
      assert {:ok, %{anonimizadas: 1, apagadas: 0}} = podar()

      depois = linha(m.id)
      assert depois.vars == %{}
      assert depois.destino == "[podado]"

      # A prova permanece: o que aconteceu, por qual canal e em que estado.
      assert depois.kind == antes.kind
      assert depois.status == antes.status
      assert depois.provider == antes.provider
    end

    test "a mensagem recente não é tocada", %{m: m} do
      assert {:ok, %{anonimizadas: 0, apagadas: 0}} = podar()
      assert linha(m.id).destino != "[podado]"
    end

    # Sem o `destino <> marcador` na condição, o laço reescreveria as mesmas linhas para sempre —
    # ele só para quando um lote vem menor que o teto. O sintoma seria um job que nunca termina.
    test "rodar duas vezes não reanonimiza (o laço termina)", %{m: m} do
      envelhecer(m.id, @curta + 1)

      assert {:ok, %{anonimizadas: 1}} = podar()
      assert {:ok, %{anonimizadas: 0}} = podar()
      assert linha(m.id).destino == "[podado]"
    end
  end

  describe "a janela longa apaga" do
    test "a linha inteira sai depois da janela de retenção" do
      ctx = clinica()
      m = mensagem(ctx)

      envelhecer(m.id, @longa + 1)
      assert {:ok, %{apagadas: 1}} = podar()
      assert linha(m.id) == nil
    end

    test "as duas janelas são parâmetro do job" do
      ctx = clinica()
      m = mensagem(ctx)

      assert {:ok, %{apagadas: 1}} =
               podar(%{"reter_pii_dias" => 0, "reter_dias" => 0})

      assert linha(m.id) == nil
    end
  end

  test "poda clínica a clínica, cada uma sob a própria GUC" do
    a = clinica()
    b = clinica()
    da_a = mensagem(a)
    da_b = mensagem(b)

    envelhecer(da_a.id, @curta + 1)

    assert {:ok, %{anonimizadas: 1}} = podar()

    assert linha(da_a.id).destino == "[podado]"
    assert linha(da_b.id).destino != "[podado]"
  end
end
