defmodule Api.Waitlist.WaitlistEntryTest do
  @moduledoc """
  A fila de espera (doc 25, Entrega 5): enfileirar com regras, upsert por paciente, a ordem de
  domínio (prioridade), editar, sair da fila, isolamento por-tenant e a coerência das regras.

  A RLS (ADR-018) **não** é exercida aqui — o sandbox conecta como `postgres` (BYPASSRLS). A
  prova do isolamento é por `psql`, fora da suíte, e está no critério de pronto da fatia.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Waitlist

  defp email, do: "fila-#{System.unique_integer([:positive])}@example.com"

  defp owner_and_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp member_with_role(clinic, papel) do
    user = Accounts.register_user!("Membro #{papel}", email(), authorize?: false)

    {:ok, m} =
      Accounts.invite_member(%{papel: papel, user_id: user.id, clinic_id: clinic.id},
        authorize?: false
      )

    {:ok, _} = Accounts.accept_invite(m, authorize?: false)
    user
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp patient(clinic, owner, nome \\ "Paciente") do
    Records.create_patient!(nome, %{}, tenant: clinic.id, actor: owner)
  end

  defp semana(dows, periodos), do: %{tipo: :semana, dows: dows, periodos: periodos}

  describe "enqueue" do
    test "cria o item com prioridade, janela, preferidos e regras" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      p = patient(clinic, owner)

      {:ok, entry} =
        Waitlist.enqueue_entry(scope, %{
          patient_id: p.id,
          prio: :urgente,
          janela: :manha,
          professional_ids: [],
          obs: "Dor aguda",
          rules: [semana([1, 3], [["09:00", "11:00"]])]
        })

      assert entry.prio == :urgente
      assert entry.janela == :manha
      assert entry.obs == "Dor aguda"
      assert entry.patient_id == p.id
      assert entry.clinic_id == clinic.id
      assert [rule] = entry.rules
      assert rule.tipo == :semana
      assert rule.dows == [1, 3]
      assert rule.periodos == [["09:00", "11:00"]]
    end

    test "sem regras é válido (encaixa em qualquer horário da janela)" do
      {owner, clinic} = owner_and_clinic()
      p = patient(clinic, owner)

      {:ok, entry} =
        Waitlist.enqueue_entry(scope_for(owner, clinic), %{patient_id: p.id, prio: :normal})

      assert entry.rules == []
      assert entry.janela == :qualquer
    end
  end

  describe "upsert por paciente (addFila [:1189])" do
    test "re-enfileirar o mesmo paciente edita o item, não duplica" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      p = patient(clinic, owner)

      {:ok, first} =
        Waitlist.enqueue_entry(scope, %{
          patient_id: p.id,
          prio: :normal,
          rules: [semana([1], [["08:00", "12:00"]])]
        })

      {:ok, second} =
        Waitlist.enqueue_entry(scope, %{
          patient_id: p.id,
          prio: :urgente,
          rules: [semana([2], [["14:00", "16:00"]])]
        })

      assert first.id == second.id
      assert second.prio == :urgente
      # As regras foram substituídas (:direct_control), não acumuladas.
      assert [rule] = second.rules
      assert rule.dows == [2]

      %{entries: entries} = Waitlist.list_entries(scope)
      assert length(entries) == 1
    end
  end

  describe "ordem de domínio (prioridade)" do
    test "urgente vem antes de normal, que vem antes de baixa" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      for prio <- [:baixa, :urgente, :normal] do
        Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner).id, prio: prio})
      end

      prios = scope |> Waitlist.list_entries() |> Map.fetch!(:entries) |> Enum.map(& &1.prio)
      assert prios == [:urgente, :normal, :baixa]
    end

    # A ordem agora é do BANCO (`prio_rank`), mas `priority_rank/1` continua ordenando o que já
    # está em memória (o `who_fits`). Duas representações da mesma regra só são seguras enquanto
    # concordam — e é isso que este teste trava, item a item, em vez de confiar na revisão.
    test "o rank do banco concorda com o rank do Elixir" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      for prio <- [:baixa, :urgente, :normal, :alta] do
        Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner).id, prio: prio})
      end

      entries =
        scope
        |> Waitlist.list_entries()
        |> Map.fetch!(:entries)
        |> Ash.load!(:prio_rank, authorize?: false, tenant: clinic.id)

      for e <- entries do
        assert e.prio_rank == Waitlist.priority_rank(e.prio),
               "prio_rank do banco (#{e.prio_rank}) diverge do Elixir para #{e.prio}"
      end
    end
  end

  # F6: a fila carregava tudo. A paginação e a ordenação-no-banco são a mesma mudança: paginar
  # sobre uma ordem aplicada em memória daria "página 2" que não continua a página 1.
  describe "paginação (F6)" do
    test "limit/offset recortam a fila SEM quebrar a ordem de prioridade" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)

      for prio <- [:baixa, :normal, :urgente, :alta, :normal] do
        Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner).id, prio: prio})
      end

      pagina1 = Waitlist.list_entries(scope, limit: 2)
      pagina2 = Waitlist.list_entries(scope, limit: 2, offset: 2)

      assert Enum.map(pagina1.entries, & &1.prio) == [:urgente, :alta]
      assert Enum.map(pagina2.entries, & &1.prio) == [:normal, :normal]

      # O total é do RECORTE inteiro, não da página — é o "de Z" do rótulo.
      assert pagina1.page.total == 5
      assert pagina1.page.more == true
      assert pagina2.page.offset == 2

      ids1 = MapSet.new(pagina1.entries, & &1.id)
      ids2 = MapSet.new(pagina2.entries, & &1.id)
      assert MapSet.disjoint?(ids1, ids2), "a página 2 repetiu item da página 1"
    end

    test "sem opção nenhuma continua devolvendo a fila (o default não é 'vazio')" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner).id})

      assert %{entries: [_], page: %{total: 1, more: false}} = Waitlist.list_entries(scope)
    end

    test "limit e offset absurdos não derrubam a request" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner).id})

      assert %{entries: []} = Waitlist.list_entries(scope, limit: 10_000_000, offset: 999_999_999)
      assert %{entries: [_]} = Waitlist.list_entries(scope, limit: -5, offset: -3)
    end
  end

  describe "update / dequeue" do
    test "update muda a prioridade e as regras" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      p = patient(clinic, owner)

      {:ok, entry} = Waitlist.enqueue_entry(scope, %{patient_id: p.id, prio: :normal})

      {:ok, updated} =
        Waitlist.update_entry(scope, entry.id, %{
          prio: :alta,
          rules: [semana([5], [["13:00", "18:00"]])]
        })

      assert updated.prio == :alta
      assert [%{dows: [5]}] = updated.rules
    end

    test "dequeue remove o item" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      {:ok, entry} = Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner).id})

      assert :ok = Waitlist.dequeue_entry(scope, entry.id)
      assert %{entries: []} = Waitlist.list_entries(scope)
    end

    test "update/dequeue de item inexistente devolve :not_found" do
      {owner, clinic} = owner_and_clinic()
      scope = scope_for(owner, clinic)
      id = Ecto.UUID.generate()

      assert {:error, :not_found} = Waitlist.update_entry(scope, id, %{prio: :alta})
      assert {:error, :not_found} = Waitlist.dequeue_entry(scope, id)
    end
  end

  describe "isolamento por-tenant" do
    test "a lista não vaza item de outra clínica" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      Waitlist.enqueue_entry(scope_for(owner_b, clinic_b), %{
        patient_id: patient(clinic_b, owner_b, "Da B").id
      })

      %{entries: entries} = Waitlist.list_entries(scope_for(owner_a, clinic_a))
      assert entries == []
    end

    test "enqueue com paciente de outra clínica é recusado (não cria item-fantasma)" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()
      paciente_b = patient(clinic_b, owner_b, "De B")

      assert {:error, %Ash.Error.Invalid{}} =
               Waitlist.enqueue_entry(scope_for(owner_a, clinic_a), %{patient_id: paciente_b.id})
    end

    test "não dá para editar item de outra clínica (404, não vazamento)" do
      {owner_a, clinic_a} = owner_and_clinic()
      {owner_b, clinic_b} = owner_and_clinic()

      {:ok, entry_b} =
        Waitlist.enqueue_entry(scope_for(owner_b, clinic_b), %{
          patient_id: patient(clinic_b, owner_b).id
        })

      assert {:error, :not_found} =
               Waitlist.update_entry(scope_for(owner_a, clinic_a), entry_b.id, %{prio: :alta})
    end
  end

  describe "coerência das regras (RuleShape)" do
    setup do
      {owner, clinic} = owner_and_clinic()
      %{scope: scope_for(owner, clinic), patient_id: patient(clinic, owner).id}
    end

    test "regra :semana sem dias é recusada", %{scope: scope, patient_id: pid} do
      assert {:error, %Ash.Error.Invalid{}} =
               Waitlist.enqueue_entry(scope, %{
                 patient_id: pid,
                 rules: [%{tipo: :semana, dows: [], periodos: [["09:00", "11:00"]]}]
               })
    end

    test "regra :data sem data é recusada", %{scope: scope, patient_id: pid} do
      assert {:error, %Ash.Error.Invalid{}} =
               Waitlist.enqueue_entry(scope, %{
                 patient_id: pid,
                 rules: [%{tipo: :data, periodos: [["09:00", "11:00"]]}]
               })
    end

    test "regra sem faixa de horário é recusada", %{scope: scope, patient_id: pid} do
      assert {:error, %Ash.Error.Invalid{}} =
               Waitlist.enqueue_entry(scope, %{
                 patient_id: pid,
                 rules: [semana([1], [])]
               })
    end

    test "faixa malformada é recusada", %{scope: scope, patient_id: pid} do
      assert {:error, %Ash.Error.Invalid{}} =
               Waitlist.enqueue_entry(scope, %{
                 patient_id: pid,
                 rules: [semana([1], [["11:00", "09:00"]])]
               })
    end
  end

  describe "find_slots (integração motor + banco)" do
    test "emite as vagas gerais dentro do expediente da clínica" do
      {owner, clinic} = owner_and_clinic()
      membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)

      # Segunda 2026-07-20, 07:00 local (10:00Z): o expediente 08–12/13–18 ainda está no futuro.
      scope = Api.Scope.with_membership(owner, membership, now: ~U[2026-07-20 10:00:00Z])
      Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)
      {:ok, entry} = Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner).id})

      segunda =
        scope |> Waitlist.find_slots(entry) |> Enum.filter(&(&1.date == ~D[2026-07-20]))

      # Onboard abre seg–sex 08–12 / 13–18 → primeira brecha de cada período.
      assert Enum.map(segunda, & &1.start) == [480, 780]
      assert Enum.all?(segunda, &(&1.freed == false))
    end

    test "slots_by_entry (batch) mapeia cada item e bate com find_slots por item" do
      {owner, clinic} = owner_and_clinic()
      membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)
      scope = Api.Scope.with_membership(owner, membership, now: ~U[2026-07-20 10:00:00Z])
      Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)
      {:ok, a} = Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner, "A").id})
      {:ok, b} = Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner, "B").id})

      by_entry = Waitlist.slots_by_entry(scope, [a, b])

      assert Map.keys(by_entry) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert by_entry[a.id] == Waitlist.find_slots(scope, a)
      assert by_entry[b.id] == Waitlist.find_slots(scope, b)
    end

    test "slots_by_entry com fila vazia devolve mapa vazio" do
      {owner, clinic} = owner_and_clinic()
      membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)
      scope = Api.Scope.with_membership(owner, membership, now: ~U[2026-07-20 10:00:00Z])

      assert Waitlist.slots_by_entry(scope, []) == %{}
    end
  end

  describe "who_fits (quem cabe na vaga — D-E5.4)" do
    test "só os compatíveis: preferência de profissional + janela + regras" do
      {owner, clinic} = owner_and_clinic()
      membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)
      scope = Api.Scope.with_membership(owner, membership, now: ~U[2026-07-20 10:00:00Z])
      prof_a = Directory.create_professional!("Dra. A", %{}, tenant: clinic.id, actor: owner)
      prof_b = Directory.create_professional!("Dr. B", %{}, tenant: clinic.id, actor: owner)

      # Cabe: sem preferência, janela qualquer.
      {:ok, _} = Waitlist.enqueue_entry(scope, %{patient_id: patient(clinic, owner, "Cabe").id})
      # Não cabe: prefere o prof_b, e a vaga é do prof_a.
      {:ok, _} =
        Waitlist.enqueue_entry(scope, %{
          patient_id: patient(clinic, owner, "OutroProf").id,
          professional_ids: [prof_b.id]
        })

      # Não cabe: janela tarde, e a vaga é de manhã.
      {:ok, _} =
        Waitlist.enqueue_entry(scope, %{
          patient_id: patient(clinic, owner, "SoTarde").id,
          janela: :tarde
        })

      # Vaga que abriu: prof_a, segunda 09:00–09:50 (manhã).
      {:ok, starts} =
        Api.Scheduling.LocalTime.to_utc(~D[2026-07-20], "09:00", "America/Sao_Paulo")

      ends = DateTime.add(starts, 50 * 60, :second)

      nomes =
        scope
        |> Waitlist.who_fits(prof_a.id, starts, ends)
        |> Enum.map(& &1.patient.nome)

      assert nomes == ["Cabe"]
    end
  end

  describe "RBAC" do
    test "todos os papéis que agendam administram a fila" do
      {owner, clinic} = owner_and_clinic()

      for papel <- [:admin, :recepcao, :profissional] do
        scope = scope_for(member_with_role(clinic, papel), clinic)
        p = patient(clinic, owner, "P #{papel}")

        assert {:ok, entry} = Waitlist.enqueue_entry(scope, %{patient_id: p.id})
        assert %{entries: entries} = Waitlist.list_entries(scope)
        assert entry.id in Enum.map(entries, & &1.id)
      end
    end
  end
end
