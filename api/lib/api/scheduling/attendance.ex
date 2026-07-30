defmodule Api.Scheduling.Attendance do
  @moduledoc """
  Presença de **um participante** num agendamento (doc 25 §4, D10/D11).

  É a peça que o protótipo não tem e que fecha o GAP-07 — *"a lacuna mais séria"* (`02:570`).
  Lá, a relação agendamento↔paciente vive no array `patientIds` e o vínculo com pacote num
  mapa `pkgOf` mantido à mão; presença individual numa turma simplesmente não é representável.
  Aqui cada participante tem status próprio: o bloco pode estar `:concluido` enquanto um
  participante `:faltou`.

  Nasce nesta fatia **sem UI de status** (a Entrega 4 é que mexe nas transições) porque sem ela
  a Fatia 3 teria de refazer a agenda inteira.

  `package_id` é por **participante**, não do agendamento (D11): não existe "pacote de turma" —
  cada paciente consome do seu.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    # Só o da caixa de notificações, e só para a falta por participante (#46, doc 41 etapa 5): o
    # `AgendaNotifier` continua **fora** daqui de propósito, senão o evento de tempo real sairia
    # duas vezes (a presença muda e o rollup escreve o bloco). Ver o moduledoc do `Appointment`.
    notifiers: [Api.Notifications.Notifier]

  # "Presença viva" — o predicado que decide se esta presença ainda conta como sessão de alguém.
  # Estava escrito em cinco lugares (`bulk.ex` ×2, `remove_participants.ex`, `rollup.ex`,
  # `preview.ex`) quando o bate-volta da Onda 3 o mediu; a sexta cópia seria a que divergiria.
  # Mora aqui, ao lado do enum que define os status, e sai por `viva?/1` (lista em memória) e pela
  # calculate `:viva?` (filtro que desce para o SQL).
  @mortas [:cancelada]

  @doc """
  Esta presença ainda está de pé? Cancelada é quem **saiu** do bloco — não é participante, não
  ocupa vaga na turma (o teto que o bate-volta viu contar quem saiu), não é alvo de massa e não
  entra no rollup do desfecho.

  Aceita a presença ou só o status, porque metade dos chamadores tem o registro e a outra metade
  tem só o átomo (o rollup recebe uma lista de status). O padrão é `%{status: …}` e não
  `%__MODULE__{}` porque o struct do recurso só existe **depois** do DSL — casar com ele aqui é
  erro de compilação ("cyclic module usage").
  """
  def viva?(status) when is_atom(status), do: status not in @mortas
  def viva?(%{status: status}), do: viva?(status)

  postgres do
    table "attendances"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
      # Sair da turma é destruir a `Attendance`; o bloco sumindo leva as suas junto.
      reference :appointment, on_delete: :delete
      # Paciente com histórico não é apagável — por isso `Patient` arquiva.
      reference :patient, on_delete: :restrict

      # H64: a sessão é do PACIENTE e sobrevive ao pacote; o que se perde é o vínculo. Por isso
      # `nilify`, e não `restrict` (que faria um pacote apagado travar) nem `delete` (que
      # apagaria histórico clínico junto com um registro comercial).
      reference :package, on_delete: :nilify
    end

    custom_indexes do
      # **Não** existe índice `(clinic_id, appointment_id)` aqui: ele é prefixo estrito do único
      # `one_per_patient_per_appt` — `(clinic_id, appointment_id, patient_id)` —, que serve as
      # mesmas buscas. Medido no bate-volta da Onda 3 (doc 43 §5f): `idx_scan=0` e 520 kB contra
      # 684 varreduras do único, ou seja, custo de escrita puro numa tabela que a massa reescreve
      # (destroy + insert por sessão).
      #
      # A-D5 (avisar sobre paciente em dois lugares), o agregado `Patient.faltas` e o histórico da
      # ficha leem por paciente. A terceira coluna é o que faz o `ORDER BY session_starts_at DESC
      # LIMIT 50` do histórico sair do índice, sem varrer nem ordenar (doc 43 §4) — e serve
      # igualmente as duas primeiras, que só precisam do prefixo (a lição de §5f: prefixo estrito
      # não pede índice próprio).
      index [:clinic_id, :patient_id, :session_starts_at]

      # O índice `(clinic_id, package_id)` vem da relação `belongs_to :package` (H64) e serve as
      # buscas da aplicação, que sempre têm o tenant. Este aqui serve outra coisa: a **checagem
      # de FK** que o Postgres emite ao apagar um `Package` — `WHERE package_id = $1`, sem
      # `clinic_id`, porque ele não tem noção de tenant. Sem `all_tenants? true` o ADR-017
      # prefixaria `clinic_id` e o índice não serviria a essa forma.
      #
      # Medido no bate-volta da Onda 5, com 10.219 linhas: pelo composto o plano é *Index Only
      # Scan* varrendo o índice inteiro (13 buffers, custo 197); com o dedicado, 2 buffers e
      # custo 13 — a mesma diferença que `appointments.created_by_id` já registrava (doc 26,
      # achado (h)).
      index [:package_id], all_tenants?: true
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      # `package_id` entra aqui (doc 41 etapa 2) porque quem cria a presença é o
      # `manage_relationship` do bloco (`Changes.ManageParticipants`): o vínculo com o pacote nasce
      # com ela, em vez de um `set_package` numa segunda escrita.
      accept [:patient_id, :appointment_id, :package_id, :session_starts_at]
    end

    # A presença acompanha o ciclo de vida do bloco (Entrega 4). Só é chamada **em cascata**,
    # de dentro da transação da ação do `Appointment` (ver `CascadeToAttendances`), com
    # `authorize?: false` — o bloco já autorizou. Aceita `status` e `falta_justificada` em
    # separado porque as transições mexem em um, a justificativa no outro.
    update :transition do
      require_atomic? false
      # `:motivo` entra aqui para o `reopen` do BLOCO poder limpá-lo (bate-volta). Sem ele a
      # cascata devolvia a presença a `:prevista` deixando o motivo da falta pendurado —
      # explicação de algo que deixou de ter acontecido. O `reopen_attendance` (por participante)
      # já limpava; eram duas portas para o mesmo desfecho com comportamentos diferentes.
      accept [:status, :falta_justificada, :motivo]
    end

    # As transições de presença POR PARTICIPANTE (Frente 6/A2, doc 41) — o **único** caminho de
    # desfecho desde o bate-volta da Onda 3: as ações de bloco equivalentes
    # (`mark_completed`/`mark_missed`/`set_falta_justificada`) foram removidas, porque duas máquinas
    # de estado escrevendo `Appointment.status` faziam todo guard novo nascer só de um lado.
    # Marca-se cada presença, e o desfecho do bloco vira ROLLUP (`RollupBlockStatus`). O guard de horário
    # (`SessionStarted`) e o de versão (409) moram no wrapper do domínio (`transition_participant`),
    # como no bloco — a presença não tem `starts_at`, e ler o bloco aqui cairia antes do
    # `SetTenantGuc` (RLS). O `StatusIn` (genérico, lê `data.status`) fica aqui: é o F4 do QA.
    update :mark_present do
      require_atomic? false
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:prevista]}
      change set_attribute(:status, :concluida)
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    # Faltar aceita `motivo` — opcional, texto livre (D-H3 com o D5 do doc 64).
    #
    # O motivo é **da presença, não do bloco**: depois da A2 a falta é por participante, e um
    # campo único no bloco mentiria numa turma onde três faltaram por razões diferentes. É o
    # mesmo raciocínio do D13, aplicado ao texto em vez de ao rótulo.
    #
    # E é **opcional por decisão**, não por esquecimento: apresentar não é exigir. A consequência
    # aceita no §8 é que qualquer relatório por causa nasce incompleto — se a gestão quiser o
    # número confiável, aí vira obrigatório, com ADR novo.
    update :mark_absent do
      require_atomic? false
      accept [:motivo]
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:prevista]}
      change set_attribute(:status, :faltou)
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    # Desfaz um clique errado nesta presença: volta a `:prevista` e zera a justificativa, então o
    # agregado `Patient.faltas` e o `usadas` do pacote recuam junto.
    update :reopen_attendance do
      require_atomic? false
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:concluida, :faltou]}
      change set_attribute(:status, :prevista)
      change set_attribute(:falta_justificada, false)
      # Zera o motivo junto: reabrir é desfazer um clique errado, e um motivo de falta pendurado
      # numa presença que voltou a `:prevista` seria explicação de algo que não aconteceu — o
      # mesmo cuidado que o `reopen` do bloco tem com o `cancel_reason`.
      change set_attribute(:motivo, nil)
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    # Justificar/desjustificar a falta desta presença (só quando faltou). Não mexe no status; o
    # rollup ainda roda (bumpa a versão do bloco e notifica), e é o que faz a falta parar de contar.
    update :justify_absence do
      require_atomic? false
      validate {Api.Scheduling.Appointment.Validations.StatusIn, from: [:faltou]}
      argument :justificada, :boolean, allow_nil?: false
      change set_attribute(:falta_justificada, arg(:justificada))
      change Api.Scheduling.Attendance.Changes.RollupBlockStatus
    end

    # Segura/solta a presença numa pausa de pacote (RN-23 em turma, doc 43 §5c). Cascata interna do
    # ciclo de vida do pacote, com `authorize?: false` — quem autorizou foi a ação do pacote, e esta
    # escrita não carrega nada do corpo do request. Espelha o `set_pkg_hold` do bloco.
    update :set_pkg_hold do
      require_atomic? false
      accept [:pkg_hold]
    end

    # Não existe ação de "carimbar o pacote depois". O vínculo participante↔pacote nasce **com** a
    # presença, na mesma escrita (`Changes.ManageParticipants`, via o argumento `package_id` de
    # `:schedule`/`:add_participant`). O `set_package` que existia aqui perdeu o último chamador de
    # produção na etapa 2 da A2 e ficou como superfície de escrita sem porta — saiu no bate-volta da
    # Onda 3 (doc 43 §5e). Se um dia precisar voltar, volta com chamador.

    # Sair da turma (doc 41 etapa 3). Chamada **em cascata**, de dentro da ação do bloco
    # (`Appointment.Changes.RemoveParticipants`), com `authorize?: false` — quem autoriza é o
    # bloco, e é lá que moram o guard do último participante e o `participant_removed`.
    # `require_atomic? false` pelo `SetTenantGuc` (before_action), como todas as escritas
    # por-tenant.
    destroy :remove do
      primary? true
      require_atomic? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin, :recepcao, :profissional], clinic_from: :tenant}
    end
  end

  preparations do
    # A7 vale para a agenda inteira, não só para o `Appointment`: sem este recorte, um
    # `profissional` que não enxerga o bloco do colega lia mesmo assim os pares
    # (appointment_id, patient_id) da clínica toda por aqui. `via: :appointment` porque o
    # `professional_id` mora no bloco, não no participante.
    prepare {Api.Scheduling.Preparations.OwnAgendaOnly, via: :appointment}

    # Presença segurada por pausa de pacote não é participante de nada até a retomada (doc 43 §5c).
    prepare Api.Scheduling.Preparations.HideHeldAttendances
  end

  changes do
    change Api.Tenancy.SetTenantGuc

    # A trilha (doc 63) — ver a nota gêmea em `Appointment` sobre a saída do `AshPaperTrail`.
    #
    # `pkg_hold` é gancho interno da série (a pausa do pacote segura a presença), como no bloco:
    # não é decisão de ninguém, e com ele fora do diff a escrita de `set_pkg_hold` fica vazia e
    # cala pelo `skip_unchanged`. Quem conta esse fato é "Pausou o pacote", uma linha só em vez de
    # uma por sessão.
    change {Api.Audit.Capture,
            resource: :attendance,
            meta: [:patient_id, :appointment_id, :package_id, :status, :session_starts_at],
            ignore: [:pkg_hold],
            skip_unchanged: [:set_pkg_hold]},
           on: [:create, :update, :destroy]
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :status, Api.Scheduling.AttendanceStatus,
      allow_nil?: false,
      default: :prevista,
      public?: true

    # Segurada por uma pausa de pacote (RN-23), quando o bloco é compartilhado — ver
    # `Preparations.HideHeldAttendances`. No bloco de um só, quem segura é o `Appointment.pkg_hold`.
    attribute :pkg_hold, :boolean, allow_nil?: false, default: false, public?: true

    # Entrega 4 (o bloco "Falta justificada" do drawer). Coluna agora, UI depois.
    attribute :falta_justificada, :boolean, allow_nil?: false, default: false, public?: true

    # Por que faltou — texto livre, opcional (D-H3/D5). Sem taxonomia fechada: o §8 decidiu
    # explicitamente que categoria não entra agora. O teto acompanha o `cancel_reason` do bloco,
    # que é o campo irmão deste.
    attribute :motivo, :string, public?: true, constraints: [max_length: 300]

    # `package_id` mudou de casa: virou `belongs_to :package` (H64, Onda 5) — ver `relationships`.

    # O instante da sessão, **denormalizado** do bloco (doc 43 §4). É por ele que o histórico da
    # ficha ordena e pagina.
    #
    # Era um aggregate (`first :session_starts_at, :appointment, :starts_at`), e o `ORDER BY …
    # LIMIT` até descia para o SQL — mas a subquery do aggregate **não é correlacionada**: o
    # planner varria os agendamentos da clínica inteira para o hash join (medido: `rows=51`
    # estimadas contra 10.185 reais, 291 buffers). O custo saía de "cresce com o paciente" para
    # "cresce com a clínica". Coluna + índice `(clinic_id, patient_id, session_starts_at)` deixa as
    # duas curvas planas.
    #
    # Quem a mantém: `ManageParticipants` na criação e `SyncSessionStartsAt` na remarcação do bloco
    # — os dois únicos caminhos em que o par (presença, horário) nasce ou muda. `allow_nil? false`
    # é deliberado: um caminho novo que esqueça de preenchê-la falha **alto**, em vez de sumir em
    # silêncio do histórico do paciente.
    attribute :session_starts_at, :utc_datetime, allow_nil?: false, public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :appointment, Api.Scheduling.Appointment, allow_nil?: false
    belongs_to :patient, Api.Records.Patient, allow_nil?: false

    # O pacote que originou esta sessão (D11: pacote é por **participante**, não do bloco —
    # não existe "pacote de turma"). Nulo = sessão avulsa.
    #
    # H64 (Onda 5): era `attribute :package_id, :uuid` **sem FK nenhuma** — "gancho da Fatia 3",
    # escrito quando `Package` ainda não era tabela. Virou relação de verdade agora que é: o
    # projeto já tratava a coluna como referência (a massa por pacote opera sobre presenças por
    # ela), só sem o banco garantir nada. `attribute_writable?`/`public?` preservam a superfície
    # anterior — `accept [:package_id]` nas ações continua valendo.
    belongs_to :package, Api.Packages.Package do
      attribute_writable? true
      public? true
    end

    # As **irmãs**: as outras presenças do mesmo pacote (inclusive esta). Existe para uma pergunta
    # só — "de que sessão do pacote estamos falando?" —, respondida pela calculate
    # `:package_sessao`. É auto-referência por `package_id` nos dois lados, então presença avulsa
    # (`package_id` nulo) não casa nada, que é o comportamento desejado.
    has_many :package_siblings, __MODULE__ do
      source_attribute :package_id
      destination_attribute :package_id
    end

    # O inverso do `belongs_to :attendance` de `Api.Messaging.Message`. Existe para **uma**
    # pergunta — "o paciente respondeu sobre esta sessão?" —, respondida pelo agregado
    # `:resposta_do_paciente`.
    #
    # É relação de verdade, e não agregado desrelacionado com `parent(id)`: a lição medida está
    # três linhas abaixo, em `:package_sessao`. O agregado sem relação perde o tenant no caminho
    # do AshSql e a subquery volta vazia — sintoma calado, com o dado ao lado carregado.
    has_many :messages, Api.Messaging.Message
  end

  calculations do
    # O mesmo predicado do `viva?/1`, para quem pergunta ao **banco** (`filter: [viva?: true]`) em
    # vez de a uma lista já carregada. `expr` desce para o SQL.
    calculate :viva?, :boolean, expr(status not in ^@mortas)

    # ---- "de que sessão do pacote estamos falando?" (o cartão da agenda) ----
    #
    # O bloco carregava só o `package_id` — um UUID, que não diz nem que é pacote nem qual sessão
    # é. Estas três respondem isso sem uma segunda leitura na fronteira: descem no mesmo SELECT
    # das presenças, e por isso saem iguais pelas quatro portas do bloco (GET, POST, transição e
    # push do canal), que é o que o moduledoc do `ApiWeb.AgendaJSON` exige.
    calculate :package_nome, :string, expr(package.nome)
    calculate :package_total, :integer, expr(package.total)

    # O que o **drawer** pergunta e o `sessao/total` não responde: faltar nesta sessão consome uma
    # do pacote (RN-30/31)? É a pergunta do balcão, e a resposta é um `boolean` do pacote.
    #
    # O saldo (`package.restantes`) chegou a viajar aqui e **saiu**: o drawer deixou de exibi-lo
    # (a caixa dizia três coisas onde cabiam duas), e campo que ninguém lê é payload morto — com
    # agravante, porque `restantes` deriva do agregado `usadas` e custava uma subquery por presença
    # em toda leitura da agenda. Se voltar a ser exibido, volta em uma linha.
    calculate :package_falta_punitiva, :boolean, expr(package.falta_punitiva)

    # A posição CRONOLÓGICA desta sessão dentro do pacote: quantas sessões do mesmo pacote começam
    # até ela (inclusive). Contar em vez de guardar um índice é o que faz o número continuar certo
    # depois de uma remarcação — a sessão que foi para depois da seguinte troca de lugar com ela,
    # e um `indice` gravado na criação passaria a mentir. É o mesmo raciocínio do `usadas` do
    # pacote, que o protótipo mantinha à mão e dessincronizava (`package.ex:15`).
    #
    # Conta pela relação `:package_siblings` (auto-referência por `package_id`), e não por um
    # agregado sem relação sobre a própria tabela: **medido** — o agregado desrelacionado perde o
    # tenant no caminho do AshSql (`handle_attribute_multitenancy` compara o ref a `nil` e avisa),
    # e a subquery voltava vazia, dando `sessao: nil` com o pacote carregado ao lado. Pela relação,
    # o corte por `clinic_id` (ADR-017) desce junto.
    calculate :package_sessao,
              :integer,
              expr(
                count(package_siblings,
                  query: [filter: expr(session_starts_at <= parent(session_starts_at))]
                )
              )
  end

  aggregates do
    # A **última** resposta do paciente ao link desta sessão (doc 52 §5) — `nil` quando ele não
    # respondeu nada. É a estrelinha do card da agenda.
    #
    # A **última**, e isso é o ponto: `StampReply` preserva o instante da primeira resposta mas
    # sobrescreve a resposta em si, porque quem confirmou e depois clicou em "preciso remarcar"
    # mudou de ideia. Mostrar a primeira deixaria uma estrela no bloco de quem pediu remarcação —
    # justamente o caso que exige ação.
    #
    # **Sem filtro de `not is_nil`, e isso é o `include_nil?: false` do Ash trabalhando.** Uma
    # sessão tem confirmação **e** lembrete, e o paciente costuma responder a um só: sem pular os
    # nulos, o lembrete sem resposta seria a linha mais recente e apagaria da tela a confirmação
    # que existe na anterior. O `first` do Ash já os pula por construção — `include_nil?` é `false`
    # por padrão e o ash_sql escolhe um agregado que ignora NULL (`aggregate.ex`, o comentário do
    # `array_agg`). Um filtro aqui seria a mesma regra escrita duas vezes, uma delas inerte.
    #
    # A dependência é real, então está presa por teste: ligar `include_nil?` deixa vermelho o
    # "uma mensagem mais nova SEM resposta não apaga a resposta que existe".
    first :resposta_do_paciente, :messages, :resposta do
      sort respondido_em: :desc
    end
  end

  identities do
    # O mesmo paciente duas vezes na mesma turma é sempre erro (e quebraria o contador N/cap).
    #
    # `pre_check? true` não é enfeite: sob RLS o Postgres **omite o DETAIL** do
    # `unique_violation`, e o AshPostgres lê `error.postgres.detail` para transformar a
    # violação em erro de campo — sem DETAIL, estoura `KeyError` e o 422 vira 500. Já mordeu
    # em `appointment_type.ex:172` e `schedule_exception.ex:120`.
    identity :one_per_patient_per_appt, [:appointment_id, :patient_id] do
      pre_check? true
      message "este paciente já está neste agendamento"
    end
  end
end
