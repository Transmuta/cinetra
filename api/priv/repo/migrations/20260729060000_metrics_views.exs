defmodule Api.Repo.Migrations.MetricsViews do
  @moduledoc """
  Views `metrics_*` — a superfície que o Grafana lê do banco (doc 73).

  ## Por que view, e não `GRANT SELECT` na tabela

  Log responde "o que o sistema fez"; ele **não** responde "em que estado o negócio está". Fila do
  Oban com job atrasado, lembrete `pendente` com `agendado_para` no passado, taxa de falta por
  profissional — nada disso existe em linha de log, e o `oban_jobs` ainda perde a evidência para o
  Pruner em 7 dias. Ler o banco fecha essa lacuna.

  O custo de fechá-la mal seria alto: um datasource com `SELECT` nas tabelas põe `patients.cpf`,
  `patients.obs` e o nome de todo titular a um clique numa UI web — exatamente o dado que o
  `RequestLogger` sanitiza e que o Alloy redige com três regexes. **A view é o allowlist**: cada
  coluna aqui foi escolhida uma a uma, e coluna nova numa tabela **não** aparece sozinha do outro
  lado. Erra fechado, como o resto do projeto (doc 62 §7.3).

  O que **nunca** entra, e por quê:

    * `patient_id` em qualquer grão — é o único identificador que o doc 05 §1.3 proíbe de sair,
      porque liga o registro a um titular. Paciente aqui só existe como **contagem**
      (`metrics_patients_resumo`).
    * **texto livre** — `appointments.obs`, `attendances.motivo`, `waitlist_entries.obs`,
      `notifications.title/body`, `packages.nome`. Campo digitado por humano carrega o que o humano
      quis: "Maria faltou de novo" é dado de saúde num campo que ninguém classificou.
    * `messages.erro`. Este merece nota porque a intuição erra: o texto **cru do provedor** é o que
      fica na coluna (`webhooks.ex` grava `reason`/`error.message`), e a classificação só acontece
      na leitura, no `Falhas.para_tela/1` do controller. Num bounce, o texto cru costuma citar o
      destinatário — e-mail ou telefone do paciente. O painel mostra **quantas** falharam, por
      canal e por template; o *motivo* se lê na tela da clínica, sob RLS, que é onde ele importa.
    * `audit_events.label`, `user_label`, `diff`, `meta` — o `diff` guarda valor antes/depois, ou
      seja o conteúdo do campo alterado. `resource`/`action_type`/`user_id` bastam para "quem
      tentou o que" sem carregar o que foi escrito.
    * `oban_jobs.args` e `errors` — `args` carrega ids de domínio e `errors` carrega stacktrace com
      mensagem de exceção, que é texto livre por natureza.

  ## Uma coluna que engana, e por isso é calculada aqui

  `appointments.duration_minutos` **não** é a duração do bloco: é o *override* de A-D8, e vem
  **NULA** no caso comum (a duração de verdade mora no tipo de atendimento). Um painel que somasse
  a coluna crua ignoraria quase todo agendamento e desenharia uma linha vazia sem erro nenhum —
  medido, foi o primeiro defeito que a verificação destes dashboards pegou. A view entrega
  `duracao_minutos` derivada de `ends_at - starts_at`, que é o intervalo de fato reservado, e não
  expõe o override para ninguém tropeçar de novo.

  Entram, deliberadamente: `clinic_id`, `user_id`/`actor` e o rótulo do **profissional**. Os dois
  primeiros o doc 05 §1.3 permite de propósito (é o que torna o log investigável); o terceiro é
  quem opera a agenda — sem ele "taxa de falta por profissional" vira uma lista de UUID e ninguém
  usa. Paciente não tem rótulo aqui em hipótese alguma.

  ## RLS: a view roda como o dono

  As tabelas têm RLS `FORCE` (ADR-018) e o role de leitura é `NOBYPASSRLS`, então um `SELECT`
  direto dele voltaria **vazio** — o mesmo fail-closed que já custou bugs ao projeto. A view é
  criada por `postgres` e o Postgres a executa com os direitos do **dono** (`security_invoker` é
  `false` por padrão), então ela enxerga todas as clínicas. É intencional: o painel é da operação
  do produto, não de uma clínica. O que impede o abuso não é a RLS aqui, é a lista de colunas.

  ## A armadilha de manutenção (leia antes de xingar o `ash.codegen`)

  View depende de coluna. Se um dia uma migration do Ash tentar **mudar o tipo** de uma coluna
  citada aqui, o Postgres recusa com `cannot alter type of a column used by a view or rule`. O
  conserto é mecânico e está documentado no doc 73 §6: `DROP VIEW` das `metrics_*`, roda a
  migration, `mix ecto.migrate` recria (esta migration é idempotente — `CREATE OR REPLACE`).
  Acrescentar coluna, renomear tabela ou dropar coluna **não** citada não incomoda.
  """
  use Ecto.Migration

  # Ordem alfabética por assunto, para achar rápido. Toda view começa por `id` e `clinic_id`
  # quando existem, para que os painéis fiquem parecidos entre si.
  @views [
    {"metrics_clinics",
     """
     SELECT id, nome, timezone, slot_minutos, cap_turma_padrao,
            msg_confirmacao_auto, msg_lembrete_horas,
            (zernio_account_id IS NOT NULL) AS whatsapp_configurado,
            inserted_at
       FROM clinics
     """, "Clínicas — sem CNPJ e sem endereço; nome serve de rótulo nos painéis."},
    {"metrics_professionals",
     """
     SELECT id, clinic_id,
            coalesce(nullif(nome_exibicao, ''), nome) AS rotulo,
            sub AS especialidade, ativo, segue_horario_clinica, inserted_at
       FROM professionals
     """,
     "Profissionais — rótulo de exibição e especialidade. Nada de CPF, contato ou dado bancário."},
    {"metrics_appointment_types",
     """
     SELECT id, clinic_id, nome, duracao_minutos, grupo, capacidade, ativo, inserted_at
       FROM appointment_types
     """, "Tipos de atendimento — catálogo, sem dado pessoal por construção."},
    {"metrics_appointments",
     """
     SELECT id, clinic_id, professional_id, appointment_type_id, created_by_id,
            status, starts_at, ends_at,
            round(extract(epoch FROM ends_at - starts_at) / 60.0) AS duracao_minutos,
            encaixe, veio_da_fila, dias_na_fila, pkg_hold,
            (cancel_reason IS NOT NULL) AS tem_motivo_cancelamento,
            (reschedule_reason IS NOT NULL) AS tem_motivo_remarcacao,
            excluded_at, inserted_at, updated_at
       FROM appointments
     """,
     "Agenda no grão do bloco. Duração calculada de ends_at-starts_at (a coluna duration_minutos é override e vem NULA no caso comum). Texto livre vira booleano."},
    {"metrics_attendances",
     """
     SELECT id, clinic_id, appointment_id, status, falta_justificada,
            (package_id IS NOT NULL) AS em_pacote,
            session_starts_at, inserted_at, updated_at
       FROM attendances
     """,
     "Presença por participante (D10). Sem `patient_id` e sem `motivo` — o desfecho basta para a taxa de falta."},
    {"metrics_messages",
     """
     SELECT id, clinic_id, canal, kind, template, status, provider,
            (erro IS NOT NULL) AS falhou_com_motivo,
            resposta,
            enfileirado_em, agendado_para, enviado_em, entregue_em, lido_em,
            falhou_em, respondido_em, inserted_at
       FROM messages
     """,
     "Funil de entrega. Sem `destino`, sem `vars` e sem `erro` — ver o moduledoc sobre o texto cru do provedor."},
    {"metrics_waitlist_entries",
     """
     SELECT id, clinic_id, prio, janela,
            coalesce(array_length(professional_ids, 1), 0) AS qtd_profissionais,
            inserted_at, updated_at
       FROM waitlist_entries
     """, "Fila de espera — prioridade, janela e idade. Sem `obs` e sem paciente."},
    {"metrics_packages",
     """
     SELECT id, clinic_id, appointment_type_id, status, total, falta_punitiva,
            data_inicio, inserted_at, updated_at
       FROM packages
     """, "Pacotes — `nome` fica de fora porque costuma citar o paciente."},
    {"metrics_audit_events",
     """
     SELECT id, clinic_id, resource, action_type, action, user_id, at, inserted_at
       FROM audit_events
     """,
     "Trilha no grão do evento. Sem `label`/`user_label`/`diff`/`meta` — o `diff` guarda o valor alterado."},
    {"metrics_notifications",
     """
     SELECT id, clinic_id, kind, recipient_id, read_at, inserted_at
       FROM notifications
     """, "Caixa do sino. `title`/`body`/`data` ficam fora: citam paciente e horário."},
    {"metrics_memberships",
     """
     SELECT id, clinic_id, user_id, professional_id, papel, status, inserted_at
       FROM memberships
     """, "Equipe por clínica — papel e status, para cruzar uso com RBAC."},
    {"metrics_oban_jobs",
     """
     SELECT id, state::text AS state, queue, worker, attempt, max_attempts, priority,
            coalesce(array_length(errors, 1), 0) AS qtd_erros,
            inserted_at, scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at
       FROM oban_jobs
     """,
     "Fila de trabalho. `args` (ids de domínio) e `errors` (stacktrace) ficam fora; a contagem de erros basta."},
    {"metrics_patients_resumo",
     """
     SELECT clinic_id,
            count(*) AS total,
            count(*) FILTER (WHERE ativo) AS ativos,
            count(*) FILTER (WHERE comunicacao) AS aceitam_comunicacao,
            count(*) FILTER (WHERE tel IS NOT NULL AND tel <> '') AS com_telefone,
            count(*) FILTER (WHERE email IS NOT NULL AND email <> '') AS com_email,
            max(inserted_at) AS cadastro_mais_recente
       FROM patients
      GROUP BY clinic_id
     """,
     "Paciente entra SÓ agregado — a única view sem grão de linha, e é de propósito: aqui não há id para vazar."}
  ]

  def up do
    Enum.each(@views, fn {nome, sql, comentario} ->
      execute("CREATE OR REPLACE VIEW #{nome} AS #{sql}")
      execute("COMMENT ON VIEW #{nome} IS '#{comentario}'")
    end)

    # O role de leitura é provisionado fora daqui (`Api.Release.setup_metrics_role/0` em produção,
    # `priv/sql/setup_metrics_role.sql` em dev), porque ele tem senha e senha não mora em migration.
    # O grant vive junto do role — este bloco só cobre o caso de a migration rodar DEPOIS, com o
    # role já criado, para não deixar view nova sem permissão.
    execute("""
    DO $$
    DECLARE v text;
    BEGIN
      IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'cinetra_metrics') THEN
        FOR v IN SELECT viewname FROM pg_views
                  WHERE schemaname = 'public' AND viewname LIKE 'metrics\\_%'
        LOOP
          EXECUTE format('GRANT SELECT ON public.%I TO cinetra_metrics', v);
        END LOOP;
      END IF;
    END
    $$
    """)
  end

  def down do
    Enum.each(@views, fn {nome, _sql, _comentario} ->
      execute("DROP VIEW IF EXISTS #{nome}")
    end)
  end
end
