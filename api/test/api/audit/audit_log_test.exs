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
      refute Map.has_key?(page, :total)
      assert page.offset == 0
      assert page.limit == 50
      assert page.more == false
    end

    test "pagina: limit/offset recortam e `more` sinaliza continuação" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: primeira, page: p1} = Audit.list_events(ctx.scope, limit: 2, offset: 0)
      assert length(primeira) == 2
      assert p1.more == true

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
      _outro = schedule(ctx, %{starts_at: at("14:00")})

      %{entries: entries} = Audit.list_events(ctx.scope, record_id: alvo.id)

      assert Enum.all?(entries, &(&1.record_id == alvo.id))
      assert acoes(entries) == ["cancel", "reschedule", "schedule"]
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
      alvo = appt_with_history(ctx)
      _outro = schedule(ctx, %{starts_at: at("14:00")})

      %{page: sem_filtro} = Audit.list_events(ctx.scope, limit: 3)
      assert sem_filtro.more == true

      %{page: com_filtro} = Audit.list_events(ctx.scope, record_id: alvo.id, limit: 3)
      assert com_filtro.more == false
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
    test "autor e profissional saem por nome; o paciente do participante também" do
      ctx = setup_clinic()
      schedule(ctx)

      %{entries: entries} = Audit.list_events(ctx.scope)

      bloco = Enum.find(entries, &(&1.resource == :appointment))
      assert bloco.actor == %{id: ctx.owner.id, nome: "Dona Ana"}
      assert bloco.professional == %{id: ctx.prof.id, nome: "Dra. Bea"}

      participante = Enum.find(entries, &(&1.resource == :attendance))
      assert participante.patient == %{id: ctx.paciente.id, nome: "Caio Paciente"}
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
