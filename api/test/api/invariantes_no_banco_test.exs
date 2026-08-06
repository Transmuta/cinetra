defmodule Api.InvariantesNoBancoTest do
  @moduledoc """
  As invariantes que o **Ash valida e o banco não protegia** (doc 92, §6 e Onda 3).

  O achado que originou este arquivo é de forma, não de dado: o schema tem 4 `CHECK` de domínio
  em 25 tabelas. Quase toda regra de coerência do sistema — "capacidade só existe em turma",
  "dia da semana vai de 0 a 6", "regra de data precisa ter data" — vive numa `validate` do
  recurso, e portanto **só na fronteira do Ash**. Migration, `Ash.Seed`, script de manutenção e
  `psql` passam por baixo dela.

  ## Por que isso importa se "tudo escreve pelo Ash"

  Porque nem tudo escreve. As três coisas que já aconteceram neste projeto e escrevem por fora
  são migration de backfill, `Ash.Seed` em teste e correção manual em produção — e é justamente
  no terceiro caso, quando alguém está com pressa consertando outra coisa, que a rede tem valor.
  É o mesmo raciocínio que `Api.Packages.PackageTest` escreveu ao pôr o teto de `total` também no
  banco: *a constraint do atributo protege a entrada da API; a do banco protege o dado.*

  ## Por que os testes usam `INSERT` cru

  Porque é a única forma de provar que a proteção está **no banco**. Um teste pela ação do Ash
  ficaria verde com a `validate` sozinha e não distinguiria os dois mundos — que é exatamente a
  distinção sob teste.

  Cada bloco abaixo tem o par: a linha inválida é recusada, **e** a linha válida entra. Sem a
  segunda metade, uma constraint escrita errado (estrita demais) passaria despercebida.
  """
  use Api.DataCase, async: false

  alias Api.Waitlist

  defp uuid(v), do: Ecto.UUID.dump!(v)

  # `package_schedules.dows` — 0=domingo … 6=sábado.
  #
  # Este é o caso que mais incomoda dos cinco, porque o comentário do atributo em
  # `Api.Packages.PackageSchedule` **afirma** que a constraint existe ("a constraint fecha o
  # range") e ela não existia. Documentação e banco se contradizendo é pior que ausência das
  # duas: quem lê o código acredita que está coberto e não olha de novo.
  describe "package_schedules.dows" do
    setup do
      ctx = clinica(tipo: [nome: "Pilates #{unico()}"])

      {:ok, pkg} =
        Api.Packages.create_package(
          %{
            nome: "Pilates 10",
            total: 10,
            falta_punitiva: true,
            cor: "#0FB5A6",
            data_inicio: ~D[2026-07-20],
            patient_id: ctx.paciente.id,
            appointment_type_id: ctx.tipo.id,
            grade: %{dows: [1], horarios: %{"1" => "08:00"}, professional_id: ctx.prof.id}
          },
          scope: ctx.scope
        )

      # A grade nasce com o pacote; para testar a constraint precisamos de um pacote SEM grade.
      Api.Repo.query!("DELETE FROM package_schedules WHERE package_id = $1", [uuid(pkg.id)])

      %{ctx: ctx, pkg: pkg}
    end

    defp insere_grade(ctx, pkg, dows) do
      Api.Repo.query!(
        "INSERT INTO package_schedules (id, clinic_id, package_id, professional_id, dows, " <>
          "horarios, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, '{}', now(), now())",
        [uuid(Ash.UUID.generate()), uuid(ctx.clinic.id), uuid(pkg.id), uuid(ctx.prof.id), dows]
      )
    end

    test "o banco recusa dow fora de 0..6", %{ctx: ctx, pkg: pkg} do
      assert_raise Postgrex.Error, ~r/package_schedules_dows_range/, fn ->
        insere_grade(ctx, pkg, [7])
      end
    end

    test "o banco recusa dow negativo", %{ctx: ctx, pkg: pkg} do
      assert_raise Postgrex.Error, ~r/package_schedules_dows_range/, fn ->
        insere_grade(ctx, pkg, [-1])
      end
    end

    test "a semana inteira continua válida", %{ctx: ctx, pkg: pkg} do
      assert %{num_rows: 1} = insere_grade(ctx, pkg, [0, 1, 2, 3, 4, 5, 6])
    end
  end

  # `appointment_types.capacidade` — o candidato que **foi recusado**, e este teste guarda a
  # recusa (doc 92, P2-7).
  #
  # A auditoria propunha `(grupo AND capacidade IS NOT NULL) OR (NOT grupo AND capacidade IS
  # NULL)`. Aplicado, quebrou `Api.Scheduling.AppointmentTest` — e o teste que caiu explica por
  # quê: o sistema mantém um fallback **defensivo** (`Clinic.cap_turma_padrao`) para turma sem
  # teto, escrito exatamente para a linha que veio de fora das ações. Está no moduledoc de
  # `Api.Scheduling.Appointment.Validations.GroupCapacity`, com essas palavras.
  #
  # É a distinção de que este arquivo inteiro depende: `capacidade sse grupo` é regra **da
  # ação**, não invariante **do dado**. Endurecê-la no banco não teria protegido nada — teria
  # proibido o único estado para o qual o fallback existe.
  describe "appointment_types: turma sem capacidade é ACEITA (decisão registrada)" do
    test "o banco aceita grupo sem capacidade — quem decide o teto é o fallback da clínica" do
      ctx = clinica()

      assert %{num_rows: 1} =
               Api.Repo.query!(
                 "INSERT INTO appointment_types (id, clinic_id, nome, duracao_minutos, cor, " <>
                   "icon, grupo, capacidade, ativo, inserted_at, updated_at) VALUES " <>
                   "($1, $2, $3, 50, '#0FB5A6', 'dot', true, NULL, true, now(), now())",
                 [uuid(Ash.UUID.generate()), uuid(ctx.clinic.id), "T#{unico()}"]
               )
    end
  end

  # `clinic_hours.dow` e `professional_hours.dow` — 0..6, como em `package_schedules`. Um `dow: 7`
  # aqui não estoura nada: ele vira uma linha de expediente que **nenhum dia da semana alcança**,
  # e o sintoma é "a clínica não abre nesse dia" sem nada no log.
  describe "expediente: dow entre 0 e 6" do
    test "clinic_hours recusa dow 7" do
      ctx = clinica()

      assert_raise Postgrex.Error, ~r/clinic_hours_dow_range/, fn ->
        Api.Repo.query!(
          "INSERT INTO clinic_hours (id, clinic_id, dow, periods, inserted_at, updated_at) " <>
            "VALUES ($1, $2, 7, '{}', now(), now())",
          [uuid(Ash.UUID.generate()), uuid(ctx.clinic.id)]
        )
      end
    end

    test "professional_hours recusa dow 7" do
      ctx = clinica()

      assert_raise Postgrex.Error, ~r/professional_hours_dow_range/, fn ->
        Api.Repo.query!(
          "INSERT INTO professional_hours (id, clinic_id, professional_id, dow, modo, periods, " <>
            "inserted_at, updated_at) VALUES ($1, $2, $3, 7, 'proprio', '{}', now(), now())",
          [uuid(Ash.UUID.generate()), uuid(ctx.clinic.id), uuid(ctx.prof.id)]
        )
      end
    end

    test "domingo (0) e sábado (6) continuam válidos" do
      ctx = clinica()

      for dow <- [0, 6] do
        assert %{num_rows: 1} =
                 Api.Repo.query!(
                   "INSERT INTO clinic_hours (id, clinic_id, dow, periods, inserted_at, " <>
                     "updated_at) VALUES ($1, $2, $3, '{}', now(), now()) " <>
                     "ON CONFLICT (clinic_id, dow) DO UPDATE SET updated_at = now()",
                   [uuid(Ash.UUID.generate()), uuid(ctx.clinic.id), dow]
                 )
      end
    end
  end

  # `availability_rules` — a forma da regra. `:semana` precisa de dias; `:data` precisa da data.
  # Uma regra sem nenhum dos dois é uma disponibilidade que **nunca casa com vaga nenhuma**: o
  # paciente fica na fila para sempre, e o `SlotFinder` não tem como reclamar.
  describe "availability_rules: a forma bate com o tipo" do
    setup do
      ctx = clinica()
      {:ok, entry} = Waitlist.enqueue_entry(ctx.scope, %{patient_id: ctx.paciente.id})
      %{ctx: ctx, entry: entry}
    end

    defp insere_regra(ctx, entry, tipo, dows, data) do
      Api.Repo.query!(
        "INSERT INTO availability_rules (id, clinic_id, waitlist_entry_id, tipo, dows, data, " <>
          "periodos, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, '{}', now(), now())",
        [uuid(Ash.UUID.generate()), uuid(ctx.clinic.id), uuid(entry.id), tipo, dows, data]
      )
    end

    test "regra de semana sem dias é recusada", %{ctx: ctx, entry: entry} do
      assert_raise Postgrex.Error, ~r/availability_rules_forma/, fn ->
        insere_regra(ctx, entry, "semana", [], nil)
      end
    end

    test "regra de data sem data é recusada", %{ctx: ctx, entry: entry} do
      assert_raise Postgrex.Error, ~r/availability_rules_forma/, fn ->
        insere_regra(ctx, entry, "data", [], nil)
      end
    end

    test "as duas formas coerentes entram", %{ctx: ctx, entry: entry} do
      assert %{num_rows: 1} = insere_regra(ctx, entry, "semana", [1, 3], nil)
      assert %{num_rows: 1} = insere_regra(ctx, entry, "data", [], ~D[2026-09-01])
    end
  end

  # `memberships.professional_id` — o "UUID mole" que apontava para lugar nenhum (doc 92, P1-3).
  #
  # A metade da aplicação entrou na Onda 1: as três portas de convite/edição agora recusam
  # profissional de outra clínica (`Validations.ProfessionalInClinic`). Esta é a metade do banco,
  # e ela fecha um caso que validação nenhuma alcança — a escrita que não passa pelo Ash.
  #
  # **O que esta FK NÃO faz**, e é decisão consciente: ela é *global*, então garante que o
  # profissional **existe**, não que ele é **desta clínica**. Fechar a segunda metade exigiria um
  # `UNIQUE (id, clinic_id)` em `professionals` e uma FK composta; ficou de fora porque a
  # validação já cobre todos os caminhos vivos. Ver a nota no `references` do recurso.
  describe "memberships.professional_id aponta para profissional que existe" do
    test "o banco recusa professional_id inexistente" do
      ctx = clinica()
      outro = Api.Generators.usuario!("Convidado")

      assert_raise Postgrex.Error, ~r/memberships_professional_id_fkey/, fn ->
        Api.Repo.query!(
          "INSERT INTO memberships (id, user_id, clinic_id, professional_id, papel, status, " <>
            "inserted_at, updated_at) VALUES ($1, $2, $3, $4, 'profissional', 'ativo', " <>
            "now(), now())",
          [
            uuid(Ash.UUID.generate()),
            uuid(outro.id),
            uuid(ctx.clinic.id),
            uuid(Ash.UUID.generate())
          ]
        )
      end
    end

    # `nilify`: o profissional pode ser apagado um dia (a LGPD do D-1); o vínculo sobrevive sem a
    # coluna, que é a verdade — a pessoa continua na equipe, só não tem mais coluna na agenda.
    test "apagar o profissional esvazia o vínculo em vez de derrubá-lo" do
      ctx = clinica()
      membro = Api.Generators.usuario!("Fisio")

      {:ok, m} =
        Api.Accounts.invite_member(
          %{
            papel: :profissional,
            user_id: membro.id,
            clinic_id: ctx.clinic.id,
            professional_id: ctx.prof.id
          },
          authorize?: false
        )

      Api.Repo.query!("DELETE FROM professionals WHERE id = $1", [uuid(ctx.prof.id)])

      assert %{rows: [[nil]]} =
               Api.Repo.query!("SELECT professional_id FROM memberships WHERE id = $1", [
                 uuid(m.id)
               ])
    end
  end

  # `messages.provider_message_id` — a chave que o webhook usa para achar a mensagem. A leitura
  # `:by_provider_id` é `get? true`, e sob índice NÃO-único uma duplicata (um retry do provedor,
  # que é o caso normal de acontecer) derruba o webhook com erro obscuro em vez de casar a linha.
  #
  # Parcial em `IS NOT NULL` porque mensagem ainda não despachada não tem id do provedor, e
  # `NULL` não conflita com `NULL` em índice único — mas ser explícito aqui deixa a intenção
  # legível e o índice menor.
  describe "messages.provider_message_id é único quando existe" do
    setup do
      ctx = clinica()
      paciente = paciente_com(ctx, comunicacao: true, email: "ana#{unico()}@example.com")
      appt = agendamento!(ctx, paciente: paciente)
      [presenca] = appt.attendances

      {:ok, message} =
        Api.Messaging.Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)

      %{ctx: ctx, message: message}
    end

    # A mensagem-semente nasce pelo domínio; a cópia é `INSERT … SELECT` sobre a linha dela.
    # Clonar em vez de montar à mão evita repetir aqui as três FKs obrigatórias de `messages`
    # (presença, agendamento, paciente) — e mantém o teste sobre a constraint, não sobre o
    # trabalho de construir uma mensagem válida.
    defp clonar_mensagem(message, provider_id) do
      # `status = 'enviado'` na cópia, e não o da semente: já existe um único parcial
      # `messages_uma_pendente_por_presenca` sobre `(attendance_id, kind) WHERE status =
      # 'pendente'`, e clonar em `pendente` esbarraria NELE — o teste passaria a medir a
      # constraint errada. `enviado` é também o estado real em que um `provider_message_id`
      # existe: ele só é preenchido quando o provedor aceita a mensagem.
      Api.Repo.query!(
        "INSERT INTO messages (id, clinic_id, canal, kind, template, vars, destino, status, " <>
          "provider_message_id, attendance_id, appointment_id, patient_id, inserted_at, " <>
          "updated_at) SELECT $1, clinic_id, canal, kind, template, vars, destino, 'enviado', " <>
          "$2, attendance_id, appointment_id, patient_id, now(), now() FROM messages WHERE id = $3",
        [uuid(Ash.UUID.generate()), provider_id, uuid(message.id)]
      )
    end

    # Sem `in_clinic/2` em volta: o sandbox conecta como `postgres` (BYPASSRLS), então a GUC não
    # muda nada aqui — e envolver o `assert_raise` numa transação explícita quebraria o teste por
    # outro motivo, não pelo que ele mede: a violação aborta a transação, e o `in_clinic` volta
    # `{:error, :rollback}` antes de qualquer asserção ser lida.
    test "o segundo com o mesmo id do provedor é recusado", %{message: message} do
      assert %{num_rows: 1} = clonar_mensagem(message, "wamid.ABC")

      assert_raise Postgrex.Error, ~r/messages_provider_id_index/, fn ->
        clonar_mensagem(message, "wamid.ABC")
      end
    end

    test "várias ainda sem id do provedor continuam valendo", %{message: message} do
      assert %{num_rows: 1} = clonar_mensagem(message, nil)
      assert %{num_rows: 1} = clonar_mensagem(message, nil)
      assert %{num_rows: 1} = clonar_mensagem(message, nil)
    end
  end
end
