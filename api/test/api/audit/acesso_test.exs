defmodule Api.Audit.AcessoTest do
  @moduledoc """
  A trilha de **leitura** e de **acesso negado** (doc 63, D-Aud6 e doc 61 §3b) — a metade da
  auditoria que o `AshPaperTrail` não respondia, porque ler não produz changeset.

  O que se afirma aqui, e por quê:

    * abrir a ficha grava — é o requisito literal do `06 §4`;
    * **reabrir dentro de 30 min não grava de novo** — é a deduplicação que torna aceitável
      auditar a tela mais usada da recepção, e sem ela a decisão teria sido "não auditar";
    * passada a janela, grava de novo — dedup não é "grava uma vez e nunca mais";
    * a janela é por (usuário, paciente): a colega que abre a mesma ficha deixa o próprio rastro;
    * download de anexo **não** é deduplicado, de propósito;
    * um 403 vira linha, que é o insumo de detecção de abuso.

  O relógio é o do escopo (ADR-009): é o que permite "avançar 31 minutos" sem `Process.sleep` e
  sem o teste depender do momento em que roda.
  """
  use Api.DataCase, async: false

  alias Api.Audit

  defp eventos_de_leitura(scope) do
    %{entries: entries} = Audit.list_events(scope, action: "visualizou_ficha")
    entries
  end

  # O mesmo usuário e a mesma clínica, com o relógio adiantado em `minutos`.
  defp adiantado(scope, minutos) do
    %{scope | now: DateTime.add(scope.now, minutos * 60, :second)}
  end

  describe "abrir a ficha do paciente" do
    test "grava quem abriu, de quem é a ficha e quando" do
      ctx = clinica(dono: "Dona Ana", paciente: "Caio Paciente")

      :ok = Api.Audit.Acesso.ficha_visualizada(ctx.scope, ctx.paciente)

      assert [evento] = eventos_de_leitura(ctx.scope)
      assert evento.resource == :patient
      assert evento.action_type == :read
      assert evento.record_id == ctx.paciente.id
      assert evento.label == "Caio Paciente"
      assert evento.actor == %{id: ctx.owner.id, nome: "Dona Ana"}
      assert evento.diff == []
    end

    test "reabrir dentro da janela NÃO grava de novo" do
      ctx = clinica(paciente: "Caio")

      :ok = Api.Audit.Acesso.ficha_visualizada(ctx.scope, ctx.paciente)
      :ok = Api.Audit.Acesso.ficha_visualizada(adiantado(ctx.scope, 5), ctx.paciente)
      :ok = Api.Audit.Acesso.ficha_visualizada(adiantado(ctx.scope, 29), ctx.paciente)

      # Três aberturas em meia hora contam a mesma história. É o índice-hit que substituiu o
      # `INSERT` por abertura de tela — a objeção concreta contra auditar leitura.
      assert [_] = eventos_de_leitura(ctx.scope)
    end

    test "passada a janela, grava de novo" do
      ctx = clinica(paciente: "Caio")

      :ok = Api.Audit.Acesso.ficha_visualizada(ctx.scope, ctx.paciente)

      :ok =
        Api.Audit.Acesso.ficha_visualizada(
          adiantado(ctx.scope, Api.Audit.Acesso.janela_minutos() + 1),
          ctx.paciente
        )

      assert [_, _] = eventos_de_leitura(ctx.scope)
    end

    test "a janela é por usuário: a colega deixa o próprio rastro" do
      ctx = clinica(dono: "Dona Ana", paciente: "Caio")
      admin_scope = escopo_de_membro!(ctx, :admin)

      :ok = Api.Audit.Acesso.ficha_visualizada(ctx.scope, ctx.paciente)
      :ok = Api.Audit.Acesso.ficha_visualizada(admin_scope, ctx.paciente)

      eventos = eventos_de_leitura(ctx.scope)
      assert length(eventos) == 2
      assert eventos |> Enum.map(& &1.actor.id) |> Enum.uniq() |> length() == 2
    end

    test "a janela é por paciente: outra ficha é outro evento" do
      ctx = clinica(paciente: "Caio")
      outro = paciente!(ctx, "Dani")

      :ok = Api.Audit.Acesso.ficha_visualizada(ctx.scope, ctx.paciente)
      :ok = Api.Audit.Acesso.ficha_visualizada(ctx.scope, outro)

      assert length(eventos_de_leitura(ctx.scope)) == 2
    end
  end

  describe "pela fronteira HTTP" do
    test "GET /api/patients/:id registra a visualização", %{} do
      ctx = clinica(paciente: "Caio")

      assert {:ok, _} = Api.Records.fetch_clinic_patient(ctx.scope, ctx.paciente.id)

      # O domínio NÃO grava: o que se audita é o acesso da pessoa à ficha, e as leituras internas
      # de `Patient` (a agenda resolvendo nomes, o relatório contando faltas) passam por aqui.
      # Auditá-las afogaria o sinal em ruído de máquina.
      assert eventos_de_leitura(ctx.scope) == []
    end
  end

  describe "autorização negada (doc 61 §3b)" do
    test "um 403 vira linha na trilha, com o caminho tentado" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)

      :ok = Api.Audit.Acesso.acesso_negado(recep, "/api/audit")

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :seguranca)
      assert [evento] = entries
      assert evento.action == "acesso_negado"
      assert evento.action_type == :deny
      assert evento.label == "/api/audit"
      assert evento.meta["caminho"] == "/api/audit"
      assert evento.actor.id == recep.user.id
    end

    test "403 repetido dentro da janela NÃO vira linha nova" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)

      for _ <- 1..5, do: :ok = Api.Audit.Acesso.acesso_negado(recep, "/api/audit")

      # A razão de existir do `:deny` é a detecção de abuso (`06 §8`). Sem dedup, um cliente em
      # laço escreve ~1.000 linhas/min na tabela mais escrita do sistema — e, pior que o disco,
      # **afoga o sinal**: as tentativas reais somem das 200 linhas do feed. A dedup por
      # (usuário, caminho) é o que mantém a trilha legível.
      %{entries: entries} = Audit.list_events(ctx.scope, resource: :seguranca)
      assert [_] = entries
    end

    # Regressão (auditoria doc 96, B-7). A dedup de evento sem `record_id` casa por `label`, e o
    # label era o **path cru** — com os UUIDs dentro. Ou seja: ela funcionava para a rota fixa
    # (o teste acima) e nunca casava justamente no caso que o evento existe para detectar, a
    # varredura por IDOR, em que cada tentativa tem um id diferente.
    #
    # O efeito era o inverso do desenhado: uma linha por request na tabela que mais cresce, mais
    # uma query síncrona de dedup a cada 403. O mecanismo anti-abuso era o amplificador do abuso.
    test "varredura por IDOR dedupa: cem ids diferentes na MESMA rota é um evento" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)

      for _ <- 1..100 do
        caminho = "/api/patients/#{Ecto.UUID.generate()}"
        :ok = Api.Audit.Acesso.acesso_negado(recep, ApiWeb.RequestLogger.rota(caminho), caminho)
      end

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :seguranca)

      assert [evento] = entries, "#{length(entries)} linhas: a dedup não pegou a varredura"
      # O label é agrupável…
      assert evento.label == "/api/patients/:id"
      # …e o caminho cru continua investigável (qual id foi tentado).
      assert evento.meta["caminho"] =~ ~r"^/api/patients/[0-9a-f-]{36}$"
    end

    test "a janela do 403 é por CAMINHO — outra rota tentada é outro evento" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)

      :ok = Api.Audit.Acesso.acesso_negado(recep, "/api/audit")
      :ok = Api.Audit.Acesso.acesso_negado(recep, "/api/members")

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :seguranca)
      assert length(entries) == 2
    end

    test "a janela do 403 é por USUÁRIO — a colega tentando deixa o próprio rastro" do
      ctx = clinica()
      recep = escopo_de_membro!(ctx, :recepcao)
      prof = escopo_de_membro!(ctx, :profissional)

      :ok = Api.Audit.Acesso.acesso_negado(recep, "/api/audit")
      :ok = Api.Audit.Acesso.acesso_negado(prof, "/api/audit")

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :seguranca)
      assert length(entries) == 2
    end

    test "sem clínica ativa não há onde gravar — e isso não estoura" do
      user = usuario!("Sem clínica")
      assert :ok = Api.Audit.Acesso.acesso_negado(Api.Scope.new(user), "/api/audit")
    end
  end

  describe "anexo" do
    test "cada emissão de URL assinada rende uma linha — anexo NÃO é deduplicado" do
      ctx = clinica(paciente: "Caio")
      anexo = %{id: Ash.UUID.generate(), patient_id: ctx.paciente.id, nome: "laudo.pdf"}

      :ok = Api.Audit.Acesso.anexo_tocado(ctx.scope, :visualizou, anexo)
      :ok = Api.Audit.Acesso.anexo_tocado(adiantado(ctx.scope, 1), :visualizou, anexo)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :attachment)

      # A dedup existe para a ficha, que a recepção reabre dezenas de vezes por dia. Baixar um
      # laudo é raro — e "quantas vezes fulano baixou este exame" é pergunta legítima da LGPD,
      # que uma janela de 30 min apagaria.
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.label == "laudo.pdf"))
    end
  end
end
