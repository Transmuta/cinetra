defmodule Api.Audit.AuditLogTest do
  @moduledoc """
  A leitura da trilha para a tela `/auditoria` (doc 63): `Api.Audit.list_events/2` — o feed
  cronológico **da clínica inteira**, as facetas, o diff resolvido na escrita e a redação dos
  campos sensíveis (D-Aud4).

  Substitui `Api.Scheduling.AuditLogTest`, que exercitava o modelo anterior (uma tabela de
  versões por recurso, com o diff remontado na leitura). O que mudou de contrato e está afirmado
  aqui:

    * o feed **não é mais por recurso** — sem `:resource` vem tudo, em ordem de recência;
    * `action` é **string** e o `diff` volta do jsonb com **chaves string**;
    * `page.total` voltou (a retenção de 90 dias limita a tabela — D-Aud1 encerrado).

  A RLS (ADR-018) **não** é exercida aqui — o sandbox conecta como `postgres` (BYPASSRLS). A
  prova do isolamento de `audit_events` é por `psql`, no `rls_smoke_test`.
  """
  use Api.DataCase, async: false

  alias Api.Audit
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp setup_clinic, do: clinica(dono: "Dona Ana", prof: "Dra. Bea", paciente: "Caio Paciente")

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp schedule(ctx, attrs \\ %{}) do
    base = %{
      starts_at: at("08:00"),
      professional_id: ctx.prof.id,
      appointment_type_id: ctx.tipo.id,
      patient_ids: [ctx.paciente.id]
    }

    {:ok, appt} = Scheduling.schedule_appointment(Map.merge(base, attrs), scope: ctx.scope)
    appt
  end

  # Um agendamento com uma vida: criado → remarcado (08→09) → cancelado.
  defp appt_with_history(ctx) do
    appt = schedule(ctx)

    {:ok, _} =
      Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{starts_at: at("09:00")})

    {:ok, _} =
      Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{
        cancel_reason: "paciente pediu"
      })

    appt
  end

  defp acoes(entries), do: Enum.map(entries, & &1.action)

  defp campo(entry, nome), do: Enum.find(entry.diff, &(&1["field"] == nome))

  defp so(entries, resource), do: Enum.filter(entries, &(&1.resource == resource))

  describe "feed da clínica inteira" do
    test "reúne recursos diferentes numa ordem cronológica só" do
      ctx = setup_clinic()
      appt_with_history(ctx)
      # A falta é o que rende linha de PRESENÇA: as escritas em cascata (a criação, o
      # cancelamento) contam pela linha do bloco — ver "um fato, uma linha", abaixo.
      faltou(ctx, schedule(ctx, %{starts_at: at("15:00")}))
      {:ok, _} = Api.Records.update_patient(ctx.paciente, %{tel: "11999998888"}, scope: ctx.scope)

      %{entries: entries} = Audit.list_events(ctx.scope)

      # A pergunta que o modelo anterior NÃO respondia: o que aconteceu na clínica. Numa página
      # só aparecem agenda, participante e ficha — a mais recente no topo.
      recursos = entries |> Enum.map(& &1.resource) |> Enum.uniq()
      assert :patient in recursos
      assert :appointment in recursos
      assert :attendance in recursos

      # A ordem entre requisições diferentes não é afirmada aqui de propósito: `at` é o relógio
      # do ESCOPO (ADR-009), fixo por requisição, e a fixture cria o paciente por um caminho com
      # escopo próprio. O que importa — e o que o modelo anterior não dava — é os três recursos
      # caberem numa página só, ordenada.
      assert Enum.find(entries, &(&1.resource == :patient and &1.action == "update"))
    end

    test "o agendamento tem sua vida na ordem certa" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries, page: page} = Audit.list_events(ctx.scope)

      assert acoes(so(entries, :appointment)) == ["cancel", "reschedule", "schedule"]

      # **Sem total** (D-Aud1, reafirmado pelo bate-volta): o `COUNT(*)` custava 265× a própria
      # página e era ~99% do tempo de banco da tela. O `more` continua exato — o Ash busca
      # `limit + 1` — e é ele que habilita a seta.
      # O `page` do DOMÍNIO é o `Ash.Page.Offset` cru: a forma do wire é da fronteira (doc 96,
      # H-8). O que este teste continua provando é a decisão de custo — a leitura da trilha é
      # `count: false`, então não há total a contar.
      assert page.count == nil
      assert page.offset == 0
      assert page.limit == 50
      assert page.more? == false
    end

    test "pagina: limit/offset recortam e `more` sinaliza continuação" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: primeira, page: p1} = Audit.list_events(ctx.scope, limit: 2, offset: 0)
      assert length(primeira) == 2
      assert p1.more? == true

      %{entries: segunda, page: p2} = Audit.list_events(ctx.scope, limit: 2, offset: 2)
      assert p2.offset == 2
      refute Enum.any?(segunda, fn e -> e.id in Enum.map(primeira, & &1.id) end)
    end

    test "limit fora do teto cai no teto; offset negativo vira 0" do
      ctx = setup_clinic()
      schedule(ctx)

      %{page: page} = Audit.list_events(ctx.scope, limit: 9_999, offset: -5)
      assert page.limit == 200
      assert page.offset == 0
    end
  end

  describe "diff resolvido na escrita" do
    test "remarcar rende starts_at com o valor anterior E o novo" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :appointment)
      reschedule = Enum.find(entries, &(&1.action == "reschedule"))

      starts = campo(reschedule, "starts_at")
      assert starts
      refute is_nil(starts["from"])
      refute is_nil(starts["to"])
      assert starts["from"] != starts["to"]
    end

    test "cancelar rende status agendado → cancelado" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :appointment)
      cancel = Enum.find(entries, &(&1.action == "cancel"))

      assert campo(cancel, "status") == %{
               "field" => "status",
               "from" => "agendado",
               "to" => "cancelado"
             }
    end

    test "não mostra o contador de locking, o derivado nem FK-uuid" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope)
      campos = entries |> Enum.flat_map(& &1.diff) |> Enum.map(& &1["field"]) |> Enum.uniq()

      refute "version" in campos
      refute "ends_at" in campos
      refute "clinic_id" in campos
      refute "created_by_id" in campos
      refute "patient_id" in campos
      refute "appointment_id" in campos
    end
  end

  describe "redação de campo sensível (D-Aud4)" do
    test "o CPF do paciente entra como 'mudou', sem os valores" do
      ctx = setup_clinic()

      {:ok, _} =
        Api.Records.update_patient(ctx.paciente, %{cpf: "39053344705"}, scope: ctx.scope)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :patient)
      entry = Enum.find(entries, &(&1.action == "update"))

      assert campo(entry, "cpf") == %{"field" => "cpf", "redacted" => true}
      refute Map.has_key?(campo(entry, "cpf"), "to")
    end

    test "o PIX do profissional idem — o evento fica, o valor não" do
      ctx = setup_clinic()

      {:ok, _} =
        Api.Directory.update_professional(ctx.prof, %{pix: "chave@banco.com"}, scope: ctx.scope)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :professional)
      entry = Enum.find(entries, &(&1.action == "update"))

      assert campo(entry, "pix") == %{"field" => "pix", "redacted" => true}
    end

    test "campo NÃO sensível do mesmo recurso continua com os valores" do
      ctx = setup_clinic()

      {:ok, _} =
        Api.Directory.update_professional(ctx.prof, %{crefito: "12345-F"}, scope: ctx.scope)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :professional)
      entry = Enum.find(entries, &(&1.action == "update"))
      assert campo(entry, "crefito")["to"] == "12345-F"
    end
  end

  describe "os recursos que não tinham trilha nenhuma (doc 61 §2)" do
    test "consentimento do paciente: false → true fica registrado" do
      ctx = setup_clinic()
      {:ok, _} = Api.Records.update_patient(ctx.paciente, %{lgpd: true}, scope: ctx.scope)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :patient)
      entry = Enum.find(entries, &(&1.action == "update"))

      assert campo(entry, "lgpd") == %{"field" => "lgpd", "from" => false, "to" => true}
      assert entry.label == "Caio Paciente"
    end

    test "revogar acesso (um destroy) deixa rastro, com o nome de quem perdeu o acesso" do
      ctx = setup_clinic()
      _ = escopo_de_membro!(ctx, :recepcao)

      membership =
        Api.Accounts.list_memberships!(authorize?: false)
        |> Enum.find(&(&1.clinic_id == ctx.clinic.id and &1.papel == :recepcao))

      :ok = Api.Accounts.revoke_access(membership, actor: ctx.owner)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :membership)
      revogacao = Enum.find(entries, &(&1.action_type == :destroy))

      # O `destroy` é o caso que mais dói sem trilha: o registro some INTEIRO e não sobra nem o
      # estado final do qual inferir o que houve. O `label` (lido do usuário na hora) é o que
      # mantém a linha legível depois disso.
      assert revogacao
      assert revogacao.label == "recepcao"
      assert revogacao.actor.nome == "Dona Ana"
    end

    test "troca de papel: recepção → admin" do
      ctx = setup_clinic()
      _ = escopo_de_membro!(ctx, :recepcao)

      membership =
        Api.Accounts.list_memberships!(authorize?: false)
        |> Enum.find(&(&1.clinic_id == ctx.clinic.id and &1.papel == :recepcao))

      {:ok, _} = Api.Accounts.update_membership(membership, %{papel: :admin}, actor: ctx.owner)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :membership)
      troca = Enum.find(entries, &(&1.action == "update"))

      assert campo(troca, "papel") == %{"field" => "papel", "from" => "recepcao", "to" => "admin"}
    end

    # Bate-volta (causa C5). Quem já tem clínica ativa e cria uma segunda passa `scope:` — e o
    # `Api.Scope` implementa `get_tenant`, então `changeset.tenant` vem preenchido com a clínica
    # ANTIGA. Enquanto a precedência era `changeset.tenant || tenant_from`, o evento de criação
    # caía no tenant errado: o nome da clínica nova aparecia no `/auditoria` da anterior (e a
    # RLS não protege — a linha foi gravada legitimamente dentro do tenant errado), enquanto a
    # nova nascia sem o registro da própria criação.
    test "criar uma SEGUNDA clínica não grava o evento na trilha da primeira" do
      ctx = clinica()

      nova =
        Api.Accounts.onboard_clinic!("Clínica Nova #{System.unique_integer([:positive])}", %{},
          scope: ctx.scope
        )

      # Nada da clínica nova na trilha da antiga...
      %{entries: antigas} = Audit.list_events(ctx.scope, resource: :clinic)
      refute Enum.any?(antigas, &(&1.record_id == nova.id))

      # ...e a clínica nova tem o próprio nascimento registrado.
      escopo_novo = escopo(ctx.owner, nova)
      %{entries: novas} = Audit.list_events(escopo_novo, resource: :clinic)
      assert Enum.find(novas, &(&1.record_id == nova.id and &1.action == "onboard"))
    end

    test "dados da clínica: o tenant sai do próprio registro (tenant_from: :id)" do
      ctx = setup_clinic()
      {:ok, _} = Api.Accounts.update_clinic_info(ctx.clinic, %{nome: "Nova"}, actor: ctx.owner)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :clinic)
      entry = Enum.find(entries, &(&1.action == "update_info"))
      assert campo(entry, "nome")["to"] == "Nova"
    end
  end

  describe "facetas" do
    test "por recurso, uma ou várias (a tela agrupa cadastros)" do
      ctx = setup_clinic()
      appt_with_history(ctx)
      {:ok, _} = Api.Records.update_patient(ctx.paciente, %{tel: "11999998888"}, scope: ctx.scope)

      %{entries: so_ficha} = Audit.list_events(ctx.scope, resource: :patient)
      assert Enum.all?(so_ficha, &(&1.resource == :patient))

      %{entries: cadastros} = Audit.list_events(ctx.scope, resource: [:patient, :professional])
      assert Enum.all?(cadastros, &(&1.resource in [:patient, :professional]))
      assert length(cadastros) >= length(so_ficha)
    end

    test "por registro: só o histórico daquele agendamento" do
      ctx = setup_clinic()
      alvo = appt_with_history(ctx)
      outro = schedule(ctx, %{starts_at: at("14:00")})

      %{entries: entries} = Audit.list_events(ctx.scope, record_id: alvo.id)

      assert acoes(so(entries, :appointment)) == ["cancel", "reschedule", "schedule"]
      refute Enum.any?(entries, &(&1.record_id == outro.id))
    end

    # O recorte de um BLOCO inclui o que aconteceu com os participantes dele. Casar só o
    # `record_id` deixava o "Ver histórico" da tela sem a metade que conta a história: quem
    # entrou, quem faltou e por quê moram na presença, que tem `record_id` próprio — sobravam as
    # linhas do bloco, boa parte delas o mero reflexo daquelas.
    test "por registro: o histórico do bloco traz os participantes dele" do
      ctx = setup_clinic()
      alvo = schedule(ctx)
      faltou(ctx, alvo)
      outro = schedule(ctx, %{starts_at: at("14:00")})

      %{entries: entries} = Audit.list_events(ctx.scope, record_id: alvo.id)

      participantes = so(entries, :attendance)
      assert participantes != []
      assert Enum.all?(participantes, &(&1.meta["appointment_id"] == alvo.id))
      assert Enum.all?(participantes, &(&1.patient.nome == "Caio Paciente"))

      # E o recorte continua sendo um recorte: nada do outro bloco entra.
      refute Enum.any?(entries, &(&1.meta["appointment_id"] == outro.id))
    end

    test "por ação — nome desconhecido devolve VAZIO, não o feed inteiro" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope, action: "cancel")
      assert acoes(entries) == ["cancel"]

      # O modelo anterior tinha uma whitelist de nomes e um nome fora dela virava filtro NULO —
      # o feed inteiro voltava e quem filtrou não percebia. Com `action` em texto, o filtro
      # desconhecido é apenas um filtro que não casa.
      assert %{entries: []} = Audit.list_events(ctx.scope, action: "acao_que_nao_existe")
    end

    test "o `more` respeita o filtro (não é a clínica inteira)" do
      ctx = setup_clinic()

      # O alvo tem quatro eventos (três do bloco, um da presença que o cancelamento cascateou);
      # a clínica, muitos mais.
      alvo = appt_with_history(ctx)
      for hora <- ["10:00", "11:00", "14:00"], do: schedule(ctx, %{starts_at: at(hora)})

      %{page: sem_filtro} = Audit.list_events(ctx.scope, limit: 6)
      assert sem_filtro.more? == true

      %{page: com_filtro} = Audit.list_events(ctx.scope, record_id: alvo.id, limit: 6)
      assert com_filtro.more? == false
    end

    test "por autor: a admin que remarca aparece separada do owner" do
      ctx = setup_clinic()
      appt = schedule(ctx)

      admin_scope = escopo_de_membro!(ctx, :admin)

      {:ok, _} =
        Scheduling.transition_appointment(admin_scope, appt.id, :reschedule, %{
          starts_at: at("09:00")
        })

      %{entries: entries} = Audit.list_events(ctx.scope, user_id: admin_scope.user.id)
      assert Enum.all?(entries, &(&1.actor.id == admin_scope.user.id))
      assert "reschedule" in acoes(entries)
    end

    test "por janela (from/to) sobre o instante do evento" do
      ctx = setup_clinic()
      schedule(ctx)

      futuro = DateTime.add(DateTime.utc_now(), 3600, :second)
      passado = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert %{entries: [_ | _]} = Audit.list_events(ctx.scope, from: passado, to: futuro)
      assert %{entries: []} = Audit.list_events(ctx.scope, from: futuro)
    end
  end

  describe "enriquecimento" do
    # O participante entra pelo `add_participant`, e não pela criação: a presença que nasce COM o
    # bloco não é evento próprio (ver a cascata, acima). O que se afirma aqui é o enriquecimento
    # da linha de presença, que continua existindo — só que pela porta em que ela informa algo.
    defp turma_com_participante(ctx) do
      turma = tipo!(ctx, grupo: true, capacidade: 4)
      primeiro = paciente!(ctx, "Primeiro Paciente")
      appt = schedule(ctx, %{appointment_type_id: turma.id, patient_ids: [primeiro.id]})

      {:ok, _} =
        Scheduling.add_appointment_participants(appt, %{patient_ids: [ctx.paciente.id]},
          scope: ctx.scope
        )

      appt
    end

    test "autor e profissional saem por nome; o paciente do participante também" do
      ctx = setup_clinic()
      turma_com_participante(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope)

      bloco = Enum.find(entries, &(&1.resource == :appointment))
      assert bloco.actor == %{id: ctx.owner.id, nome: "Dona Ana"}
      assert bloco.professional == %{id: ctx.prof.id, nome: "Dra. Bea"}

      participante = Enum.find(entries, &(&1.resource == :attendance))
      assert participante.patient == %{id: ctx.paciente.id, nome: "Caio Paciente"}
    end

    # As duas metades da identificação que faltavam na tela. O `Appointment` não tem paciente
    # (quem tem são as presenças) e a `Attendance` não tem profissional (quem tem é o bloco),
    # então cada linha exibia só a metade que o próprio registro carregava — "Atualizou a
    # situação · Dra. Bea" sem dizer de quem era a sessão.
    test "a linha do bloco diz QUEM estava nele" do
      ctx = setup_clinic()
      schedule(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :appointment)
      bloco = Enum.find(entries, &(&1.action == "schedule"))

      assert bloco.participants == [%{id: ctx.paciente.id, nome: "Caio Paciente"}]
    end

    test "a linha do participante diz COM QUEM era a sessão" do
      ctx = setup_clinic()
      turma_com_participante(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :attendance)
      participante = Enum.find(entries, &(&1.action == "create"))

      assert participante.professional == %{id: ctx.prof.id, nome: "Dra. Bea"}
      # A turma inteira só aparece na linha do bloco: aqui o paciente já é o sujeito da frase.
      assert participante.participants == []
    end

    test "remarcar trocando de profissional mostra os NOMES, não dois uuids" do
      ctx = setup_clinic()
      appt = schedule(ctx)

      outra = profissional!(ctx, "Dr. Ciro")

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
          starts_at: at("08:00"),
          professional_id: outra.id
        })

      %{entries: entries} = Audit.list_events(ctx.scope, resource: :appointment)
      remarcou = Enum.find(entries, &(&1.action == "reschedule"))

      # Sem isto a única coluna que mudou era um `*_id`, e a regra "FK é ruído" a engolia: a
      # linha saía com o diff VAZIO. Medido: três remarcações mudas no banco de dev.
      assert campo(remarcou, "professional_id") == %{
               "field" => "professional_id",
               "from" => "Dra. Bea",
               "to" => "Dr. Ciro"
             }
    end
  end

  # **Um fato, uma linha.** Bloco e presença são duas tabelas para a mesma sessão, e toda escrita
  # numa delas cascateia para a outra dentro da mesma transação — então cada clique rendia duas
  # linhas (ou cinco, numa turma de quatro), no mesmo segundo, dizendo a mesma coisa.
  #
  # A regra que decide quem sobra: **quem decidiu conta, o reflexo cala**.
  describe "um fato, uma linha (cascata)" do
    defp turma_de_dois(ctx) do
      turma = tipo!(ctx, grupo: true, capacidade: 4)
      dois = paciente!(ctx, "Dois Paciente")

      appt =
        schedule(ctx, %{
          appointment_type_id: turma.id,
          patient_ids: [ctx.paciente.id, dois.id]
        })

      {appt, dois}
    end

    defp do_bloco(ctx, appt) do
      %{entries: entries} = Audit.list_events(ctx.scope, record_id: appt.id)
      entries
    end

    test "criar o agendamento rende uma linha só, a do bloco" do
      ctx = setup_clinic()
      appt = schedule(ctx)

      entries = do_bloco(ctx, appt)

      assert acoes(so(entries, :appointment)) == ["schedule"]
      assert so(entries, :attendance) == []
    end

    test "cancelar a turma rende UMA linha, não uma por participante" do
      ctx = setup_clinic()
      {appt, _dois} = turma_de_dois(ctx)

      {:ok, _} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{cancel_reason: "x"})

      entries = do_bloco(ctx, appt)

      # Quem decidiu foi o bloco; as duas presenças só refletem o cancelamento. Antes eram três
      # linhas no mesmo segundo — e numa turma cheia, cinco.
      assert acoes(so(entries, :appointment)) == ["cancel", "schedule"]
      assert so(entries, :attendance) == []
    end

    test "reabrir a turma idem" do
      ctx = setup_clinic()
      {appt, _dois} = turma_de_dois(ctx)

      {:ok, _} = Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{})
      {:ok, _} = Scheduling.transition_appointment(ctx.scope, appt.id, :reopen, %{})

      entries = do_bloco(ctx, appt)

      assert acoes(so(entries, :appointment)) == ["reopen", "cancel", "schedule"]
      assert so(entries, :attendance) == []
    end

    # O caminho inverso: aqui quem decide é a PRESENÇA, e o desfecho do bloco é derivado dela.
    # O rollup nunca registra escolha de ninguém — e a linha dele, num bloco de um paciente, era
    # a mesma frase dita de outro jeito, no mesmo segundo.
    test "marcar a falta conta pela presença, mesmo quando o desfecho do bloco muda" do
      ctx = setup_clinic()
      appt = schedule(ctx)

      {:ok, _} =
        Scheduling.transition_participant(ctx.scope, appt.id, ctx.paciente.id, :no_show, %{
          motivo: "Doente"
        })

      entries = do_bloco(ctx, appt)

      assert acoes(so(entries, :attendance)) == ["mark_absent"]
      assert acoes(so(entries, :appointment)) == ["schedule"]
    end

    # Entrar numa turma que JÁ EXISTE é um fato novo — e é a linha da presença que diz QUEM entrou.
    # A do bloco ("Adicionou um participante") saía com o diff vazio, sem nomear ninguém.
    test "entrar numa turma rende a linha da presença, e só ela" do
      ctx = setup_clinic()
      turma = tipo!(ctx, grupo: true, capacidade: 4)
      appt = schedule(ctx, %{appointment_type_id: turma.id})
      duda = paciente!(ctx, "Duda Paciente")

      {:ok, _} =
        Scheduling.add_appointment_participants(appt, %{patient_ids: [duda.id]}, scope: ctx.scope)

      entries = do_bloco(ctx, appt)

      assert [presenca] = so(entries, :attendance)
      assert presenca.action == "create"
      assert presenca.patient.nome == "Duda Paciente"
      assert acoes(so(entries, :appointment)) == ["schedule"]
    end

    test "sair da turma idem — a linha é a da presença" do
      ctx = setup_clinic()
      {appt, dois} = turma_de_dois(ctx)

      {:ok, _} =
        Scheduling.remove_appointment_participants(appt, %{patient_ids: [dois.id]},
          scope: ctx.scope
        )

      entries = do_bloco(ctx, appt)

      assert [saida] = so(entries, :attendance)
      assert saida.action == "remove"
      assert saida.patient.nome == "Dois Paciente"
      assert acoes(so(entries, :appointment)) == ["schedule"]
    end

    # O nascimento da clínica é UM fato, e vinha com quinze linhas: o catálogo de cinco tipos e a
    # semana de expediente que o `onboard` semeia (doc 20 T3 / doc 22 §2), mais o convite e o
    # aceite do próprio dono. Nenhuma delas é decisão de alguém — a decisão é "Criou a clínica",
    # e o dono ser owner é invariante do onboard (ADR-016), não concessão de acesso a terceiro.
    test "criar a clínica rende uma linha só — o seed não vira trilha" do
      dono = usuario!("Nova Dona")
      clinic = Api.Accounts.onboard_clinic!("Clínica #{unico()}", %{}, actor: dono)

      %{entries: entries} = Audit.list_events(escopo(dono, clinic))

      assert acoes(entries) == ["onboard"]
    end

    # `pkg_hold` é gancho da série (a pausa do pacote segura a sessão), não decisão de ninguém:
    # quem conta é "Pausou o pacote", uma linha só em vez de uma por sessão segurada.
    test "segurar a sessão por pausa de pacote não escreve linha — nem no bloco, nem na presença" do
      ctx = setup_clinic()
      appt = schedule(ctx)

      [att] =
        Scheduling.list_attendances!(
          scope: ctx.scope,
          query: [filter: [appointment_id: appt.id]]
        )

      {:ok, _} =
        Scheduling.set_attendance_pkg_hold(att, %{pkg_hold: true},
          tenant: ctx.clinic.id,
          authorize?: false
        )

      {:ok, _} =
        Scheduling.set_appointment_pkg_hold(appt, %{pkg_hold: true},
          tenant: ctx.clinic.id,
          authorize?: false
        )

      assert acoes(do_bloco(ctx, appt)) == ["schedule"]
    end
  end

  # O bloco não decide o próprio desfecho: ele o DERIVA das presenças, pela ação interna
  # `apply_participant_rollup`, que roda a cada transição de participante e sempre bumpa a
  # `version` de propósito (é o lock otimista do bloco). Só que "sempre escreve" virava "sempre
  # aparece na trilha" — e o que a linha do rollup conta é sempre o eco da linha da presença,
  # gravada no mesmo segundo.
  describe "a escrita derivada do bloco (rollup)" do
    defp faltou(ctx, appt) do
      {:ok, _} =
        Scheduling.transition_participant(ctx.scope, appt.id, ctx.paciente.id, :no_show, %{
          motivo: "Doente"
        })
    end

    defp rollups(ctx) do
      %{entries: entries} = Audit.list_events(ctx.scope, action: "apply_participant_rollup")
      entries
    end

    test "o rollup não escreve linha — nem quando o desfecho do bloco muda" do
      ctx = setup_clinic()
      appt = schedule(ctx)
      faltou(ctx, appt)

      assert rollups(ctx) == []

      # E o fato continua registrado, com o motivo, na linha de quem decidiu: a presença.
      %{entries: presencas} = Audit.list_events(ctx.scope, resource: :attendance)
      falta = Enum.find(presencas, &(&1.action == "mark_absent"))
      assert campo(falta, "motivo")["to"] == "Doente"
    end

    test "justificar a falta continua contando pela presença" do
      ctx = setup_clinic()
      appt = schedule(ctx)
      faltou(ctx, appt)

      {:ok, _} =
        Scheduling.transition_participant(ctx.scope, appt.id, ctx.paciente.id, :justify, %{
          justificada: true
        })

      # A justificativa é da PRESENÇA e nem sequer muda o desfecho do bloco — o rollup reescreve
      # `faltou` por cima de `faltou`.
      assert rollups(ctx) == []

      %{entries: presencas} = Audit.list_events(ctx.scope, resource: :attendance)
      assert Enum.find(presencas, &(&1.action == "justify_absence"))
    end
  end

  describe "autorização (owner·admin) — a porta dos fundos da A7" do
    test "profissional e recepção recebem página vazia" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      prof_scope = escopo_de_membro!(ctx, :profissional, ctx.prof.id)
      recep_scope = escopo_de_membro!(ctx, :recepcao)

      assert %{entries: []} = Audit.list_events(prof_scope)
      assert %{entries: []} = Audit.list_events(recep_scope)
    end

    test "owner e admin leem a trilha" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      admin_scope = escopo_de_membro!(ctx, :admin)

      assert %{entries: [_ | _]} = Audit.list_events(ctx.scope)
      assert %{entries: [_ | _]} = Audit.list_events(admin_scope)
    end

    test "ninguém escreve na trilha de fora, nem o owner" do
      ctx = setup_clinic()

      assert {:error, _} =
               Audit.record_event(
                 %{
                   resource: :appointment,
                   action: "forjado",
                   action_type: :create,
                   at: DateTime.utc_now()
                 },
                 scope: ctx.scope
               )
    end
  end
end
