defmodule Api.Directory.Professional do
  @moduledoc """
  O profissional que atende — recurso **por-tenant** via **atributo** (`strategy
  :attribute`, ADR-017): mora na tabela única `professionals`, com a coluna `clinic_id`.
  O Ash injeta `WHERE clinic_id = <tenant ativo>` em toda query e preenche o `clinic_id`
  na criação a partir do tenant do escopo.

  Uma pessoa que atende em 2 clínicas é 2 registros `Professional` (um por `clinic_id`),
  ligados ao mesmo `User` via `Membership.professional_id`.

  ## Ficha completa (fatia Profissionais, 2026-07-17)

  Cobre as 6 seções do formulário do protótipo (`renderProfForm`,
  [`:2955`](../../../interface/Movimento.dc.html#L2955)): identificação, contato/localização,
  dados técnicos, contratuais/bancários, horário de atendimento e cor/status. Decisões da
  fatia:

    * **Sem cifra.** Todos os campos são texto puro — inclusive CPF, RG e dados bancários.
      Isto **reverte** a lista de campos cifrados de `06 §3.1` (a cifra mata a busca `ILIKE`
      da recepção) e alinha profissional e paciente (ambos em claro, D18).
    * **Sem repasse.** Guardamos os dados bancários como cadastro, mas **não** modelamos
      `remuneracao`/repasse/preço — faturamento é v2.
    * **Diretório separado do acesso.** Cadastrar aqui **não** cria login: o vínculo com um
      `User` é feito na tela Equipe & acessos (`Membership.professional_id`). Um profissional
      pode existir sem acesso (Thiago/Carla no seed do protótipo).
    * **Identificação duplicada BARRA** (revisão de 2026-07-29, reverte a decisão original da
      fatia): CPF, telefone e e-mail preenchidos são únicos por clínica (`identities` no fim do
      arquivo), a mesma régua da ficha do paciente. **CREFITO fica de fora** — ninguém pediu, e
      o registro profissional tem forma livre demais (UF, pontuação) para virar chave sem
      canonicalização própria. O aviso "possível duplicado" do formulário continua, dizendo
      *quem* já tem o valor.
    * **Arquivar, não apagar** (como `AppointmentType`/T2): `deactivate`/`reactivate` sobre
      `ativo`, sem `destroy` — `Appointment`/`ProfessionalHours`/exceções apontam para cá.

  O horário semanal e as folgas moram fora daqui: `Api.Scheduling.ProfessionalHours` (a grade)
  e `Api.Scheduling.ScheduleException` (exceções de data). `segue_horario_clinica` decide o
  *default* da grade.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Directory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  @campos [
    :nome,
    :nome_exibicao,
    :nascimento,
    :cpf,
    :rg,
    :estado_civil,
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
    :emergencia_tel,
    :profissao,
    :crefito,
    :registro_uf,
    :ano_conclusao,
    :especialidades,
    :sub,
    :vinculo,
    :razao_social,
    :cnpj,
    :banco,
    :agencia,
    :conta,
    :conta_tipo,
    :pix,
    :cor_indice,
    :segue_horario_clinica,
    :ativo
  ]

  postgres do
    table "professionals"
    repo Api.Repo

    # Apagar a clínica apaga seus profissionais (decisão da auditoria doc 13, causa D):
    # o tenant é a clínica; sem ela o Professional não tem sentido.
    references do
      reference :clinic, on_delete: :delete
    end

    # A RLS injeta `WHERE clinic_id = <tenant>` em TODA query desta tabela (ADR-018) — e
    # `clinic_id` não é indexado por padrão. Sem este índice, cada leitura por-tenant é seq
    # scan conforme a tabela cresce (auditoria doc 13, causa C).
    custom_indexes do
      index [:clinic_id]
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @campos
      validate Api.Validations.TelObrigatorio

      # A validação vem antes da canonicalização de propósito: é ela que produz a mensagem de erro
      # com o valor que a pessoa digitou. Canonicalizar é o que faz as identities abaixo valerem —
      # `(11) 98765-4321` e `11987654321` são o mesmo número e strings diferentes. O telefone do
      # profissional não passava por aqui antes (só a ficha do paciente normalizava).
      change {Api.Changes.Canonicalizar, campo: :cpf}
      change {Api.Changes.Canonicalizar, campo: :tel}
      change {Api.Changes.Canonicalizar, campo: :email}
    end

    # `require_atomic? false` nas escritas: o `SetTenantGuc` seta a GUC de tenant num
    # `before_action`, incompatível com update atômico. Custo nulo — o controller já busca o
    # registro antes de escrever (fetch-then-update para poder devolver 404).
    update :update do
      primary? true
      accept @campos
      require_atomic? false
      validate Api.Validations.TelObrigatorio

      # Mesma régua da criação — e é aqui que o cadastro antigo, salvo com máscara antes desta
      # mudança, passa a guardar o valor canônico no fluxo natural (sem backfill).
      change {Api.Changes.Canonicalizar, campo: :cpf}
      change {Api.Changes.Canonicalizar, campo: :tel}
      change {Api.Changes.Canonicalizar, campo: :email}
    end

    # Arquivar (não apagar): só a transição de estado, como `AppointmentType.archive`.
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
  # `clinic_id` vem do tenant ativo (escopo), nunca do corpo. Isolamento entre clínicas
  # já é garantido pelo filtro por atributo + RLS (ADR-017/018); a policy adiciona o RBAC.
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
    # Ordem estável (por criação), como o catálogo de tipos — sem ORDER BY o Postgres
    # devolve na ordem que quiser e a lista pisca entre requisições.
    prepare build(sort: [inserted_at: :asc])

    # P1: o papel `profissional` só enxerga o próprio registro (na agenda e no diretório) —
    # os demais papéis veem a clínica inteira. Recorte análogo ao A7 dos agendamentos.
    prepare Api.Directory.Preparations.OwnProfessionalOnly
  end

  changes do
    # Toda escrita seta a GUC de tenant dentro da própria transação: sem ela a RLS barra o
    # INSERT/UPDATE no servidor real (NOBYPASSRLS). Ver o moduledoc do change.
    change Api.Tenancy.SetTenantGuc

    # A trilha (doc 63). Os dados bancários (`banco`, `agencia`, `conta`, `pix`) e `cpf`/`rg`/
    # `cnpj` entram REDIGIDOS (`Api.Audit.Sensiveis`, D-Aud4).
    #
    # É o caso que o `06 §4` cita nominalmente ("alterar dados bancários do profissional") e o
    # único campo do sistema onde a alteração tem efeito financeiro direto — o repasse cai em
    # outra conta. "Quem trocou o PIX" passa a ser respondível; "para qual conta", não, e essa
    # troca é a D-Aud4.
    change {Api.Audit.Capture, resource: :professional, label: [:nome_exibicao, :nome]},
      on: [:create, :update, :destroy]
  end

  # Por-tenant por atributo: o tenant é o `clinic_id`. Toda ação exige o tenant no
  # escopo; o Ash filtra por clinic_id (isolamento lógico) e o preenche no create.
  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    # Identificação pessoal (renderProfForm seção 'ident').
    attribute :nome, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :nome_exibicao, :string, public?: true, constraints: [max_length: 120]
    attribute :nascimento, :date, public?: true
    attribute :cpf, :string, public?: true, constraints: [max_length: 20]
    attribute :rg, :string, public?: true, constraints: [max_length: 30]
    attribute :estado_civil, :string, public?: true, constraints: [max_length: 30]

    # Contato & localização (seção 'contato'). `email` aqui é dado de contato do cadastro,
    # NÃO o login — o acesso é modelado por `User`/`Membership`, à parte (ver moduledoc).
    attribute :tel, :string, public?: true, constraints: [max_length: 30]
    attribute :email, :string, public?: true, constraints: [max_length: 160]
    attribute :cep, :string, public?: true, constraints: [max_length: 12]
    attribute :endereco, :string, public?: true, constraints: [max_length: 160]
    attribute :numero, :string, public?: true, constraints: [max_length: 20]
    attribute :complemento, :string, public?: true, constraints: [max_length: 80]
    attribute :bairro, :string, public?: true, constraints: [max_length: 80]
    attribute :cidade, :string, public?: true, constraints: [max_length: 80]
    attribute :uf, :string, public?: true, constraints: [max_length: 2]
    # Contato de emergência (dado de terceiro).
    attribute :emergencia_nome, :string, public?: true, constraints: [max_length: 120]
    attribute :emergencia_tel, :string, public?: true, constraints: [max_length: 30]

    # Dados profissionais e técnicos (seção 'tecnicos'). Só o nome é obrigatório — o CREFITO
    # é opcional no cadastro (o form permite salvar e completar depois).
    attribute :profissao, :string, public?: true, constraints: [max_length: 60]
    attribute :crefito, :string, public?: true, constraints: [max_length: 40]
    attribute :registro_uf, :string, public?: true, constraints: [max_length: 2]
    attribute :ano_conclusao, :string, public?: true, constraints: [max_length: 4]
    attribute :especialidades, {:array, :string}, public?: true, default: []
    # Especialidade curta exibida na lista ("Ortopedia"). Derivada da 1ª especialidade no
    # protótipo, mas persistida à parte porque pode ser editada.
    attribute :sub, :string, public?: true, constraints: [max_length: 60]

    # Contratuais & financeiros (seção 'contrato'). Sem `remuneracao`/repasse — v2.
    attribute :vinculo, Api.Directory.ContractType, public?: true
    attribute :razao_social, :string, public?: true, constraints: [max_length: 160]
    attribute :cnpj, :string, public?: true, constraints: [max_length: 20]
    attribute :banco, :string, public?: true, constraints: [max_length: 80]
    attribute :agencia, :string, public?: true, constraints: [max_length: 20]
    attribute :conta, :string, public?: true, constraints: [max_length: 30]
    attribute :conta_tipo, :string, public?: true, constraints: [max_length: 20]
    attribute :pix, :string, public?: true, constraints: [max_length: 160]

    # Cor & status (seção 'sistema'). `cor_indice` é o índice na paleta da agenda (1-based,
    # `profColor` faz `(ci-1) % 7`); `segue_horario_clinica` decide o default da grade.
    attribute :cor_indice, :integer,
      allow_nil?: false,
      public?: true,
      default: 1,
      constraints: [min: 1, max: 99]

    attribute :segue_horario_clinica, :boolean, allow_nil?: false, default: true, public?: true
    attribute :ativo, :boolean, allow_nil?: false, default: true, public?: true

    timestamps()
  end

  relationships do
    # clinic_id é a coluna de tenant (FK -> clinics.id, garante integridade).
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false

    # A grade semanal do profissional (o que difere do horário da clínica).
    has_many :weekly_hours, Api.Scheduling.ProfessionalHours

    # Folgas/horários pontuais por data (exceções com professional_id preenchido).
    has_many :exceptions, Api.Scheduling.ScheduleException
  end

  # Identificação preenchida é única **na clínica** (reverte o "só avisar duplicados" da fatia) —
  # a mesma régua da ficha do paciente, e pela mesma razão: o cadastro em dobro divide agenda,
  # grade e histórico entre duas linhas que são a mesma pessoa. Como lá, o `clinic_id` entra na
  # unicidade automaticamente (tenancy por atributo), então o profissional multi-clínica
  # (ADR-014) continua podendo ser cadastro de duas clínicas.
  #
  # `pre_check?` pela razão documentada em `appointment_type.ex`: sob RLS o `unique_violation` vem
  # sem DETAIL e o AshPostgres estoura `KeyError` → 500 no lugar do 422.
  identities do
    identity :cpf_unico, [:cpf] do
      pre_check? true

      message "este CPF já está em outro profissional da clínica — se ele estiver arquivado, " <>
                "reative-o"
    end

    identity :tel_unico, [:tel] do
      pre_check? true

      message "este telefone já está em outro profissional da clínica — se ele estiver " <>
                "arquivado, reative-o"
    end

    identity :email_unico, [:email] do
      pre_check? true

      message "este e-mail já está em outro profissional da clínica — se ele estiver " <>
                "arquivado, reative-o"
    end
  end
end
