defmodule Api.OnDeleteTest do
  @moduledoc """
  H64 (Onda 5) — a semântica de `ON DELETE`, relação a relação.

  **Por que este teste lê o catálogo do Postgres e não exercita ações.** Nenhum recurso do
  projeto tem ação `destroy` sobre `User`, `Clinic`, `Patient`, `Professional` ou `Package`: tudo
  arquiva. A semântica de deleção é, portanto, **latente** — ela não roda hoje, mas decide o que
  acontece quando a eliminação da LGPD (F8) for construída, e o que acontece se alguém apagar à
  mão em produção. Assertir sobre a ação seria assertir sobre código que não existe; a regra vive
  na constraint, e é a constraint que este teste lê.

  A tabela abaixo é o contrato. Mudar uma linha aqui sem mudar o `references` do recurso é o
  ponto: é o que impede a semântica de voltar a divergir em silêncio, como o doc 13 achou.
  """
  use Api.DataCase, async: true

  # `{tabela, coluna} => ação esperada`
  #
  # `CASCADE` — o filho não existe sem o pai (tudo que pende de `clinics` é o tenant inteiro).
  # `RESTRICT` — o pai não é apagável enquanto houver filho; é o par de "este recurso arquiva".
  # `SET NULL` — o vínculo é **informativo**: o filho sobrevive sem ele.
  @esperado %{
    # Tenant: apagar a clínica leva tudo dela.
    {"professionals", "clinic_id"} => "CASCADE",
    {"memberships", "clinic_id"} => "CASCADE",
    {"memberships", "user_id"} => "CASCADE",
    {"user_identities", "user_id"} => "CASCADE",
    {"appointment_types", "clinic_id"} => "CASCADE",
    {"schedule_exceptions", "clinic_id"} => "CASCADE",
    {"schedule_exceptions", "professional_id"} => "CASCADE",
    {"clinic_hours", "clinic_id"} => "CASCADE",
    {"professional_hours", "clinic_id"} => "CASCADE",
    {"professional_hours", "professional_id"} => "CASCADE",
    {"patients", "clinic_id"} => "CASCADE",
    {"appointments", "clinic_id"} => "CASCADE",
    {"attendances", "clinic_id"} => "CASCADE",
    {"attendances", "appointment_id"} => "CASCADE",
    {"waitlist_entries", "clinic_id"} => "CASCADE",
    {"waitlist_entries", "patient_id"} => "CASCADE",
    {"availability_rules", "clinic_id"} => "CASCADE",
    {"availability_rules", "waitlist_entry_id"} => "CASCADE",
    {"notifications", "clinic_id"} => "CASCADE",
    {"notifications", "recipient_id"} => "CASCADE",
    {"packages", "clinic_id"} => "CASCADE",
    {"package_schedules", "clinic_id"} => "CASCADE",
    {"package_schedules", "package_id"} => "CASCADE",

    # Cadastros que arquivam em vez de apagar: a constraint é quem garante que "arquiva" não
    # vira "apaga" por um `DELETE` à mão.
    {"attendances", "patient_id"} => "RESTRICT",
    {"appointments", "appointment_type_id"} => "RESTRICT",
    {"appointments", "professional_id"} => "RESTRICT",
    {"packages", "appointment_type_id"} => "RESTRICT",
    {"packages", "patient_id"} => "RESTRICT",
    {"package_schedules", "professional_id"} => "RESTRICT",

    # H64: os três que eram `NO ACTION` por omissão, não por escolha. Todos são o **autor** de
    # algo — informação de auditoria, não parte do dado. Deixá-los travando o `DELETE` tornava
    # um `User` impossível de apagar, o que é exatamente o que a eliminação da LGPD precisará
    # fazer; e a trilha do AshPaperTrail preserva o histórico de qualquer forma.
    {"appointments", "created_by_id"} => "SET NULL",
    {"appointments_versions", "user_id"} => "SET NULL",
    {"attendances_versions", "user_id"} => "SET NULL",

    # H64: esta não tinha FK **nenhuma** — o `package_id` era um uuid solto ("gancho da Fatia 3,
    # sem FK"), escrito antes de `Package` existir como tabela. `SET NULL` porque a sessão é do
    # paciente e sobrevive ao pacote; o vínculo é que se perde.
    {"attendances", "package_id"} => "SET NULL"
  }

  defp fks do
    %{rows: rows} =
      Api.Repo.query!("""
      SELECT c.conrelid::regclass::text, a.attname,
             CASE c.confdeltype
               WHEN 'a' THEN 'NO ACTION' WHEN 'r' THEN 'RESTRICT' WHEN 'c' THEN 'CASCADE'
               WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT' END
      FROM pg_constraint c
      JOIN unnest(c.conkey) k(attnum) ON true
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
      WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
      """)

    Map.new(rows, fn [tabela, coluna, acao] -> {{tabela, coluna}, acao} end)
  end

  test "cada FK tem a semântica de ON DELETE que o projeto escolheu" do
    reais = fks()

    for {chave, esperada} <- @esperado do
      assert reais[chave] == esperada,
             "#{elem(chave, 0)}.#{elem(chave, 1)}: esperado #{esperada}, no banco #{inspect(reais[chave])}"
    end
  end

  # O contrato só vale se for completo: uma FK nova entrando sem linha na tabela acima voltaria a
  # ser "NO ACTION por omissão", que é a causa D do doc 13 renascendo.
  test "nenhuma FK ficou de fora do contrato — FK nova exige decisão explícita" do
    faltando = Map.keys(fks()) -- Map.keys(@esperado)

    assert faltando == [],
           "FKs sem semântica declarada em @esperado: #{inspect(faltando)}"
  end

  # ---------------------------------------------------------------------------
  # O CUSTO da FK (bate-volta da Onda 5)
  # ---------------------------------------------------------------------------
  #
  # Semântica e custo são o mesmo assunto visto de dois lados: escolher `CASCADE`/`SET NULL`
  # decide **o que** o Postgres faz ao apagar o pai; ter índice decide **quanto custa**. A
  # checagem que ele emite é `WHERE <coluna_fk> = $1` — sem `clinic_id`, porque o Postgres não
  # tem noção de tenant. Um índice `(clinic_id, coluna)` **não** serve: a coluna não lidera, e o
  # plano vira varredura do índice inteiro (ou seq scan, quando não há índice algum).
  #
  # É a classe de achado que este projeto já pegou três vezes — doc 26 achado (h), D-E e D-F do
  # doc 30 —, e é por isso que `appointments` declara `index [..], all_tenants?: true`.

  # As quatro FKs **anteriores a esta onda** que ainda não têm índice liderando. Estão aqui como
  # dívida declarada, não como permissão: cada uma tem um índice composto que cobre parcialmente
  # (a coluna aparece, mas não lidera), então o plano é varredura de índice, não seq scan. Sair
  # desta lista é trabalho de outra frente — entrar nela sem querer é o que o teste impede.
  @sem_indice_liderando_conhecidas [
    {"attendances", "appointment_id"},
    {"attendances", "patient_id"},
    {"packages", "patient_id"},
    {"package_schedules", "package_id"}
  ]

  defp fks_com_indice_liderando do
    %{rows: rows} =
      Api.Repo.query!("""
      WITH fk AS (
        SELECT c.conrelid::regclass::text AS tabela, a.attname AS coluna
        FROM pg_constraint c
        JOIN unnest(c.conkey) k(attnum) ON true
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
      ),
      lidera AS (
        SELECT t.relname AS tabela, a.attname AS coluna
        FROM pg_index i
        JOIN pg_class t ON t.oid = i.indrelid
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = i.indkey[0]
        WHERE t.relnamespace = 'public'::regnamespace
      )
      SELECT fk.tabela, fk.coluna,
             EXISTS (SELECT 1 FROM lidera l WHERE l.tabela = fk.tabela AND l.coluna = fk.coluna)
      FROM fk
      """)

    Map.new(rows, fn [tabela, coluna, tem?] -> {{tabela, coluna}, tem?} end)
  end

  test "toda FK tem índice que serve à checagem do DELETE (WHERE fk = $1)" do
    sem_indice =
      fks_com_indice_liderando()
      |> Enum.reject(fn {_chave, tem?} -> tem? end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    novas = sem_indice -- @sem_indice_liderando_conhecidas

    assert novas == [],
           "FK sem índice liderando (o DELETE do pai varre o filho): #{inspect(novas)}"
  end
end
