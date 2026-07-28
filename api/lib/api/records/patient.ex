defmodule Api.Records.Patient do
  @moduledoc """
  O paciente da clínica — recurso **por-tenant** via **atributo** (`strategy :attribute`,
  ADR-017): mora na tabela única `patients`, com a coluna `clinic_id`. O Ash injeta
  `WHERE clinic_id = <tenant ativo>` em toda query e preenche o `clinic_id` na criação a
  partir do tenant do escopo. Estruturalmente é um irmão de `Api.Directory.Professional`.

  ## Ficha cadastral (fatia Pacientes, 2026-07-17)

  Cobre as 8 seções do formulário do protótipo (`renderPacienteForm`,
  [`:2010`](../../../interface/Movimento.dc.html#L2010), `SECTIONS`
  [`:2028`](../../../interface/Movimento.dc.html#L2028)): identificação, endereço/e-mail,
  emergência, dados profissionais, atendimento, convênio, preferências e consentimento.
  Decisões da fatia (validadas com o usuário; ver `docs/10` D16–D19 para a base de produto):

    * **Sem cifra.** Todos os campos são texto puro — inclusive CPF e RG. Reverte a lista de
      campos cifrados de `06 §3.1`/`01 §4.6` (a cifra mata a busca por documento da recepção)
      e alinha paciente e profissional (ambos em claro, D18).
    * **Tags como texto puro.** As `tags` clínicas ficam num `{:array, :string}` aqui, **não**
      num recurso `ClinicalTag` cifrado — mesma escolha pragmática da cifra. O prontuário
      completo + LGPD Art. 11 (tags cifradas, anexos, Consent versionado) continua v2 (D16).
    * **Médico/CRM sem field policy.** São sensíveis, mas o RBAC do recurso já basta: só
      owner/admin escrevem e todo membro lê (recusada a opção A do D17 — sem field-level
      policy no projeto). Profissional é somente-leitura porque não é owner/admin.
    * **Consentimento = dois booleanos** (`lgpd`, `comunicacao`), não o recurso `Consent`
      versionado (v2). É o que o protótipo guarda ([`:109`](../../../interface/Movimento.dc.html#L109)).
    * **Só avisar duplicados.** Sem `identity` única em CPF/telefone — o front avisa "possível
      duplicado" ([`:2014`](../../../interface/Movimento.dc.html#L2014)), mas não barra.
    * **Arquivar, não apagar** (como `Professional`/`AppointmentType`): `deactivate`/`reactivate`
      sobre `ativo`, sem `destroy`. `Package`/`Attendance`/`WaitlistEntry` apontarão para cá.

  `faltas` (aggregate sobre `Attendance`), pacotes, histórico e anexos **não** entram aqui: os
  recursos que os alimentam (agenda F1/F2, pacotes F3, anexos v2) ainda não existem — a ficha
  e a lista degradam sem eles, como Profissionais adiou o `futureConflicts`.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Records,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @campos [
    :nome,
    :nome_social,
    :cpf,
    :rg,
    :genero,
    :estado_civil,
    :nascimento,
    :responsavel,
    :tel,
    :email,
    :cep,
    :endereco,
    :numero,
    :complemento,
    :bairro,
    :cidade,
    :uf,
    :emergencia_nome,
    :emergencia_parentesco,
    :emergencia_tel,
    :profissao,
    :empresa,
    :atend_tipo,
    :convenio,
    :carteirinha,
    :convenio_validade,
    :medico,
    :crm,
    :como_conheceu,
    :prefs,
    :tags,
    :lgpd,
    :comunicacao,
    :cor_indice,
    :ativo
  ]

  postgres do
    table "patients"
    repo Api.Repo

    # Apagar a clínica apaga seus pacientes (o tenant é a clínica; sem ela o Patient não tem
    # sentido) — mesma decisão de cascade do Professional (auditoria doc 13, causa D).
    references do
      reference :clinic, on_delete: :delete
    end

    # A RLS injeta `WHERE clinic_id = <tenant>` em TODA query (ADR-018) e `clinic_id` não é
    # indexado por padrão; sem índice cada leitura por-tenant vira seq scan (auditoria doc 13,
    # causa C). O **composto** `(clinic_id, inserted_at)` serve os três usos de uma vez: o
    # recorte por tenant (coluna líder), a FK do cascade, e a ORDENAÇÃO da página — com `LIMIT`
    # ele troca "bitmap scan + sort de tudo" por index scan (medido no doc 24: 18,7ms → 0,078ms).
    # Por isso o índice só de `clinic_id` sai: o composto o cobre.
    custom_indexes do
      index [:clinic_id, :inserted_at]
    end
  end

  actions do
    defaults [:read]

    # A lista da tela: paginada, filtrada e buscada **no servidor**. Paciente é a entidade que
    # cresce sem limite (ao contrário de profissionais/tipos), então aqui o carrega-tudo não
    # serve. `countable` devolve o total do recorte para o "X–Y de Z" da tela.
    read :list do
      argument :q, :string

      argument :status, :atom do
        constraints one_of: [:todos, :ativos, :inativos, :resp]
        default :todos
      end

      pagination offset?: true, countable: true, default_limit: 50, max_page_size: 200

      prepare Api.Records.Preparations.FilterPatients
    end

    create :create do
      primary? true
      accept @campos
    end

    # `require_atomic? false` nas escritas: o `SetTenantGuc` seta a GUC de tenant num
    # `before_action`, incompatível com update atômico. Custo nulo — o controller busca o
    # registro antes de escrever (fetch-then-update, para poder devolver 404).
    update :update do
      primary? true
      accept @campos
      require_atomic? false
    end

    # Arquivar (não apagar): só a transição de estado, como `Professional.deactivate`.
    update :deactivate do
      accept []
      require_atomic? false
      change set_attribute(:ativo, false)
    end

    update :reactivate do
      accept []
      require_atomic? false
      change set_attribute(:ativo, true)
    end
  end

  # ADR-016: leitura para qualquer membro ativo do tenant; escrita só owner/admin. O
  # `clinic_id` vem do tenant ativo (escopo), nunca do corpo. Isolamento entre clínicas já é
  # garantido pelo filtro por atributo + RLS (ADR-017/018); a policy adiciona o RBAC. Sem
  # field policy: médico/CRM são sensíveis, mas ninguém abaixo de admin escreve e todo membro
  # lê a ficha (D16: "todos os papéis visualizam"; opção A do D17 recusada).
  policies do
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin], clinic_from: :tenant}
    end
  end

  preparations do
    # Ordem estável (por criação), como o diretório de profissionais — sem ORDER BY o Postgres
    # devolve na ordem que quiser e a lista pisca entre requisições. O `id` entra como
    # desempate: sob paginação, duas linhas com o mesmo `inserted_at` poderiam repetir ou
    # sumir entre páginas. (Com timestamp em microssegundos o empate é improvável; o desempate
    # é o que torna a ordem *total*, e o índice composto cobre a coluna líder da ordenação.)
    prepare build(sort: [inserted_at: :asc, id: :asc])
  end

  changes do
    # Toda escrita seta a GUC de tenant dentro da própria transação: sem ela a RLS barra o
    # INSERT/UPDATE no servidor real (NOBYPASSRLS). O change é compartilhado pelos três
    # domínios por-tenant — mora em `Api.Tenancy`, que é de ninguém.
    change Api.Tenancy.SetTenantGuc
  end

  # Por-tenant por atributo: o tenant é o `clinic_id`. Toda ação exige o tenant no escopo; o
  # Ash filtra por clinic_id (isolamento lógico) e o preenche no create.
  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    # Identificação (seção 'ident'). Só o nome é obrigatório — o rodapé do form diz "nenhum
    # campo é obrigatório, salve e complete depois" ([`:2080`]).
    attribute :nome, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :nome_social, :string, public?: true, constraints: [max_length: 120]
    attribute :cpf, :string, public?: true, constraints: [max_length: 20]
    attribute :rg, :string, public?: true, constraints: [max_length: 30]
    attribute :genero, :string, public?: true, constraints: [max_length: 30]
    attribute :estado_civil, :string, public?: true, constraints: [max_length: 30]
    attribute :nascimento, :date, public?: true
    # Responsável legal (aparece no form quando o paciente é menor de idade, dado de terceiro).
    attribute :responsavel, :string, public?: true, constraints: [max_length: 160]

    # Endereço & e-mail (seção 'contato'). `email` é contato, não login (paciente não acessa).
    attribute :tel, :string, public?: true, constraints: [max_length: 30]
    attribute :email, :string, public?: true, constraints: [max_length: 160]
    attribute :cep, :string, public?: true, constraints: [max_length: 12]
    attribute :endereco, :string, public?: true, constraints: [max_length: 160]
    attribute :numero, :string, public?: true, constraints: [max_length: 20]
    attribute :complemento, :string, public?: true, constraints: [max_length: 80]
    attribute :bairro, :string, public?: true, constraints: [max_length: 80]
    attribute :cidade, :string, public?: true, constraints: [max_length: 80]
    attribute :uf, :string, public?: true, constraints: [max_length: 2]

    # Contato de emergência (seção 'emergencia', dado de terceiro).
    attribute :emergencia_nome, :string, public?: true, constraints: [max_length: 120]
    attribute :emergencia_parentesco, :string, public?: true, constraints: [max_length: 40]
    attribute :emergencia_tel, :string, public?: true, constraints: [max_length: 30]

    # Dados profissionais (seção 'profissional').
    attribute :profissao, :string, public?: true, constraints: [max_length: 60]
    attribute :empresa, :string, public?: true, constraints: [max_length: 120]

    # Atendimento (seção 'atendimento'): como a clínica cobra + encaminhamento médico. `medico`/
    # `crm` são sensíveis, protegidos pelo RBAC do recurso (sem field policy, ver moduledoc).
    attribute :atend_tipo, Api.Records.AttendanceType,
      allow_nil?: false,
      public?: true,
      default: :particular

    attribute :medico, :string, public?: true, constraints: [max_length: 120]
    attribute :crm, :string, public?: true, constraints: [max_length: 40]
    # Canal de aquisição (marketing, não LGPD Art. 11).
    attribute :como_conheceu, :string, public?: true, constraints: [max_length: 60]

    # Convênio do paciente (seção 'convenio') — registrado mesmo em atendimento particular.
    attribute :convenio, :string, public?: true, constraints: [max_length: 120]
    attribute :carteirinha, :string, public?: true, constraints: [max_length: 40]
    # Validade é MM/AAAA (máscara `maskMY`), string e não date.
    attribute :convenio_validade, :string, public?: true, constraints: [max_length: 10]

    # Preferências clínicas (seção 'clinico'). `prefs` = ids de profissionais preferidos (não
    # há FK: é preferência de agendamento, some sozinha se o profissional sumir). `tags` =
    # condições clínicas em texto puro (decisão da fatia).
    attribute :prefs, {:array, :uuid}, public?: true, default: []
    attribute :tags, {:array, :string}, public?: true, default: []

    # Consentimento (seção 'consentimento'). Dois booleanos, não o Consent versionado (v2).
    #
    # `lgpd` é o termo de tratamento de dado e nasce **falso**: é declaração de que a clínica
    # colheu o aceite, e presumir isso seria justamente o que a lei não deixa.
    attribute :lgpd, :boolean, allow_nil?: false, default: false, public?: true

    # `comunicacao` nasce **verdadeiro** (decisão de 2026-07-27, doc 52 §11.1), e o motivo não é
    # conveniência: o que sai por este canal é **operacional** — confirmar e lembrar de uma sessão
    # que o próprio paciente marcou, o que é execução do serviço contratado (LGPD, Art. 7º, V), não
    # marketing. Exigir caixa marcada para "sua sessão é amanhã às 14h" não protege ninguém e
    # quebra a funcionalidade.
    #
    # Duas condições sustentam essa leitura, e as duas são de fora deste arquivo:
    #
    #   * **o escopo não escorrega** — o que sai são os `Api.Messaging.MessageKind` operacionais,
    #     ligados a um agendamento existente. Campanha, aniversário e reengajamento pedem flag
    #     PRÓPRIA; reusar esta é como uma decisão defensável vira indefensável;
    #   * **opt-out sempre vence** (`Api.Messaging.OptOut`) e não é apagável editando a ficha.
    #
    # O default do Ash sozinho não muda nada na prática — todo paciente nasce pelo formulário, que
    # manda o valor. O par é `web/src/lib/components/patients/PatientForm.svelte`.
    attribute :comunicacao, :boolean, allow_nil?: false, default: true, public?: true

    # Índice de cor do avatar na agenda (1-based, `patientColor` :316 faz `(ci-1) % 7`).
    attribute :cor_indice, :integer,
      allow_nil?: false,
      public?: true,
      default: 1,
      constraints: [min: 1, max: 99]

    attribute :ativo, :boolean, allow_nil?: false, default: true, public?: true

    timestamps()
  end

  relationships do
    # clinic_id é a coluna de tenant (FK -> clinics.id, garante integridade).
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false

    # A presença por participante (`Attendance`) alimenta o agregado `faltas`. Relação
    # cross-domínio: `Attendance` mora em `Api.Scheduling`, e o `belongs_to :patient` de lá é o
    # outro lado desta.
    has_many :attendances, Api.Scheduling.Attendance
  end

  aggregates do
    # doc 25 §4: o `faltas` que o moduledoc dizia estar de fora *"porque os recursos que os
    # alimentam ainda não existem"*. Agregado, **nunca** contador denormalizado — o protótipo
    # mantinha `p.faltas` na mão ([`:1041`]) e dessincronizava. Conta presença `:faltou` **não**
    # justificada: justificar é o que faz a falta parar de contar (`set_falta_justificada`).
    count :faltas, :attendances do
      filter expr(status == :faltou and falta_justificada == false)
    end
  end
end
