defmodule Api.Messaging.Message do
  @moduledoc """
  Uma mensagem **ao paciente** (doc 52 §4) — o registro do que a clínica tentou comunicar sobre
  uma sessão, e o que aconteceu com essa tentativa.

  ## O quarto plano

  Não confundir com `Api.Notifications.Notification` (doc 52 §1). Aquilo é caixa **por usuário
  logado**, entregue pelo banco, instantânea e gratuita. Isto sai **para fora do sistema**, para
  quem não tem login, é assíncrono, falível, custa por unidade e **volta** (o paciente responde).
  Os dois planos não compartilham modelo por isso.

  ## Âncora: a presença, não o bloco

  `attendance_id` é a âncora (doc 52 §3), e é a mesma lição que a A2 já cobrou uma vez com a
  falta: comunicação é com **uma pessoa**, e numa turma de 4 "confirmação enviada" no bloco é
  falso para os outros 3. Em atendimento individual há uma presença só e o resultado parece o do
  bloco; numa turma, é o único coerente.

  `appointment_id` vem junto, **denormalizado**, e não é redundância preguiçosa:

    * a timeline do drawer lê por bloco — sem ele, todo acesso vira join por `attendance`;
    * é o que permite reusar `Api.Scheduling.Preparations.OwnAgendaOnly` com `via: :appointment`
      sem tocar naquele módulo. O recorte A7 (profissional só vê a própria coluna) continua com
      **uma** autoridade, que é o ponto daquele moduledoc.

  ## Destino congelado

  `destino` é o e-mail/telefone **do momento do envio**, copiado — não lido da ficha na exibição.
  A ficha muda (paciente corrige o número) e o histórico não pode mudar junto: "enviamos para
  o número X" precisa continuar dizendo X depois que a ficha diz Y. Vale também como prova
  quando o paciente diz que não recebeu.

  ## Template + vars, não texto pronto

  O corpo renderizado **não** é gravado. Dois motivos, e o segundo é o que decide:

    * LGPD (§11) — o corpo tem dado de paciente; guardar template + variáveis mantém o histórico
      legível sem duplicar dado sensível numa segunda tabela;
    * é o encaixe da fase 2 (§2). O WhatsApp fora da janela de 24h exige template HSM aprovado
      pela Meta, com variáveis posicionais. Um corpo montado como string na fase 1 obrigaria a
      reescrever tudo isso; nascendo como `template` + `vars`, a fase 2 troca o adapter.

  ## Escrita é de sistema

  Como em `Notification`, não há policy de `create`/`update`: quem escreve é
  `Api.Messaging.Dispatch` (e o webhook), com `authorize?: false`. Quem pode **mandar enviar** é
  guardado na fronteira HTTP, e o `disparado_por_id` registra quem foi — nulo é automático.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Messaging,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Api.Messaging.MessageStatus

  postgres do
    table "messages"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete

      # A presença some (participante removido do bloco) → o registro da comunicação some junto.
      # Ele só existe para explicar aquela sessão daquela pessoa; órfão não diz nada a ninguém.
      reference :attendance, on_delete: :delete
      reference :appointment, on_delete: :delete

      # O paciente NÃO cai por aqui: `Patient` é arquivado, não apagado (decisão da fatia de
      # pacientes). Se um dia for apagado de fato, a mensagem vai junto — mesma leitura da
      # presença.
      reference :patient, on_delete: :delete

      # Quem disparou pode sair da clínica; o histórico não perde a linha por causa disso.
      # `:nilify` deixa "enviado por alguém que não está mais aqui", que é a verdade.
      reference :disparado_por, on_delete: :nilify
    end

    custom_indexes do
      # A timeline do drawer: as mensagens de um bloco, em ordem. É o único caminho de leitura
      # da UI, e roda a cada abertura do drawer.
      index [:clinic_id, :appointment_id, :inserted_at], name: "messages_appointment_index"

      # O webhook (§10.2/§7): casar o evento do provider com a linha. Sem tenant na primeira
      # coluna de propósito — o evento chega **sem** `clinic_id`, e é justamente esta busca que
      # o resolve. Por isso `all_tenants?: true`.
      index [:provider_message_id], all_tenants?: true, name: "messages_provider_id_index"

      # Apoio ao cascade das FKs sem índice próprio sob ADR-017 (mesma razão de `slot_holds`).
      #
      # As quatro estão aqui porque **as quatro são `ON DELETE CASCADE` ou `SET NULL`**, e o
      # planejador precisa de um índice com a coluna na **liderança** para o cascade não varrer.
      # `appointment_id` aparece no composto `messages_appointment_index`, mas em segunda posição:
      # medido com 100 mil linhas, o DELETE de um agendamento varria o índice inteiro (233 buffers,
      # 4,6 ms); `patient_id` não tinha índice nenhum e caía em Seq Scan (2.859 buffers, 55,9 ms).
      index [:attendance_id], all_tenants?: true
      index [:appointment_id], all_tenants?: true
      index [:patient_id], all_tenants?: true
      index [:disparado_por_id], all_tenants?: true
    end
  end

  # **Sem `AshPaperTrail`, e é decisão, não esquecimento.** A trilha existe para responder "quem
  # mudou o quê" quando o registro atual não conta a história — não é o caso aqui: `disparado_por_id`
  # diz quem mandou, e cada estado tem carimbo próprio (`enviado_em`, `entregue_em`, `falhou_em`).
  # A mensagem **é** o registro.
  #
  # E o custo seria real: cada mensagem recebe 2–4 updates de webhook, então a trilha nasceria com
  # 4× as linhas da tabela que mais vai crescer no sistema. O doc 43 §5f mediu a trilha em 3× a
  # tabela base e isso virou a poda diária; repetir o padrão de propósito, para gravar o que já
  # está gravado, seria construir a dívida sabendo.

  actions do
    defaults [:read]

    # A timeline de um bloco — o que a recepção lê no drawer (§6).
    read :for_appointment do
      description "As mensagens de um agendamento, em ordem cronológica."

      argument :appointment_id, :uuid, allow_nil?: false

      filter expr(appointment_id == ^arg(:appointment_id))

      # A7: o profissional só vê a comunicação da própria coluna. Reusa o recorte da agenda em
      # vez de recriá-lo — `via: :appointment` porque o `professional_id` mora no bloco.
      prepare {Api.Scheduling.Preparations.OwnAgendaOnly, via: :appointment}
      prepare build(sort: [inserted_at: :asc])
    end

    # Já existe uma mensagem deste tipo ESPERANDO para esta presença?
    #
    # É a pergunta da trava contra duplicata (§4): o botão do rodapé dispara para o bloco inteiro
    # e nada impedia o segundo clique de enfileirar a mesma confirmação de novo — dentro da janela
    # de silêncio, onde a primeira fica horas parada, isso vira uma pilha. Medido no dev de
    # 2026-07-28: quatro linhas idênticas para o mesmo paciente.
    #
    # Só `:pendente` conta. Uma já entregue **pode** ser reenviada de propósito (a recepção pede),
    # e uma que falhou precisa poder ser tentada de novo — a duplicata que não serve a ninguém é a
    # que ainda nem saiu.
    read :pending_for_attendance do
      description "As mensagens deste tipo ainda na fila para esta presença."

      argument :attendance_id, :uuid, allow_nil?: false
      argument :kind, Api.Messaging.MessageKind, allow_nil?: false

      filter expr(
               attendance_id == ^arg(:attendance_id) and kind == ^arg(:kind) and
                 status == :pendente
             )
    end

    # Tudo que ainda não saiu deste bloco — o que o ciclo de vida precisa retirar da fila quando o
    # fato muda (cancelar, excluir). Sem `kind`: se a sessão deixou de existir, **nenhum** aviso
    # sobre ela ainda vale, e listar os tipos aqui só criaria a chance de esquecer um.
    read :pending_for_appointment do
      description "As mensagens deste agendamento que ainda estão na fila."

      argument :appointment_id, :uuid, allow_nil?: false

      filter expr(appointment_id == ^arg(:appointment_id) and status == :pendente)
    end

    # Busca pelo id do provider — o caminho do webhook, que chega **sem tenant**.
    #
    # Quem chama é o webhook, que não tem sessão, com `authorize?: false`. O que impede um
    # terceiro de varrer a tabela por aqui é a assinatura do provider verificada antes (§10.2),
    # não esta ação.
    read :by_provider_id do
      description "Acha a mensagem pelo id que o provider devolveu (caminho do webhook)."

      argument :provider_message_id, :string, allow_nil?: false

      filter expr(provider_message_id == ^arg(:provider_message_id))
      get? true
    end

    # Sistema (`Dispatch`): a mensagem nasce `:pendente` e o job a envia.
    create :enqueue do
      description "Registra a mensagem a enviar; o envio é do `Api.Messaging.SendJob`."

      accept [
        :attendance_id,
        :appointment_id,
        :patient_id,
        :canal,
        :kind,
        :template,
        :vars,
        :destino,
        :disparado_por_id,
        :agendado_para
      ]

      change set_attribute(:status, :pendente)

      # `&DateTime.utc_now/0` e não `expr(now())`: a expressão só é avaliada no caminho atômico
      # (vira `now()` no SQL). Aqui ela chegaria como *valor* e o cast falharia — com um erro que
      # não aponta para a causa ("Could not cast input to datetime. Value: now()").
      change set_attribute(:enfileirado_em, &DateTime.utc_now/0)
      change Api.Tenancy.SetTenantGuc
    end

    # Sistema: o transporte aceitou a mensagem. Grava o id do provider, que é o que o webhook
    # usará para achar esta linha depois.
    update :mark_sent do
      description "Marca como enviada e grava o id do provider."

      accept [:provider, :provider_message_id]
      require_atomic? false

      change set_attribute(:status, :enviado)
      change set_attribute(:enviado_em, &DateTime.utc_now/0)
      change Api.Tenancy.SetTenantGuc
    end

    # Sistema (webhook e falha de envio): avança a máquina de entrega.
    #
    # O avanço é **monotônico** — ver `Api.Messaging.MessageStatus.avanca?/2`. Evento fora de
    # ordem é o caso comum, não a exceção: sem essa guarda um `sent` atrasado rebaixaria uma
    # mensagem já entregue.
    update :advance do
      description "Avança a máquina de entrega (só para a frente)."

      argument :novo_status, Api.Messaging.MessageStatus, allow_nil?: false
      argument :erro, :string, allow_nil?: true

      accept []
      require_atomic? false

      change Api.Messaging.Message.Changes.AdvanceStatus
      change Api.Tenancy.SetTenantGuc
    end

    # Sistema (ciclo de vida do bloco): tira da fila o que não pode mais sair.
    #
    # `filter status == :pendente` na leitura que alimenta esta ação já é a guarda principal; o
    # `validate` aqui fecha a chamada direta — descartar uma mensagem **entregue** apagaria o
    # registro de algo que o paciente de fato recebeu, e isso não é retirada da fila, é reescrever
    # a história.
    update :discard do
      description "Retira da fila uma mensagem que ainda não saiu."

      accept [:descarte_motivo]
      require_atomic? false

      validate attribute_equals(:status, :pendente) do
        message "só uma mensagem na fila pode ser descartada"
      end

      validate present(:descarte_motivo)

      change set_attribute(:status, :descartada)
      # `&DateTime.utc_now/0` e não `expr(now())` — mesmo motivo do `:enqueue` acima.
      change set_attribute(:descartada_em, &DateTime.utc_now/0)
      change Api.Tenancy.SetTenantGuc
    end

    # Sistema (link assinado, §5): o paciente respondeu.
    #
    # Fora da máquina de entrega de propósito — a resposta pode chegar depois de `:falhou`, quando
    # a confirmação falhou num canal e o paciente respondeu ao outro.
    #
    # Idempotente por comparação: responder duas vezes não reescreve o instante da primeira, mas
    # **atualiza a resposta** — quem confirmou e depois pediu remarcação mudou de ideia, e é a
    # segunda que vale.
    update :record_reply do
      description "Grava a resposta do paciente (confirmou / quer remarcar)."

      argument :resposta, Api.Messaging.MessageReply, allow_nil?: false

      accept []
      require_atomic? false

      change Api.Messaging.Message.Changes.StampReply
      change Api.Tenancy.SetTenantGuc
    end
  end

  policies do
    # Leitura: qualquer membro da clínica. O recorte de linhas do papel `profissional` é da
    # preparation (`OwnAgendaOnly`), não daqui — `HasClinicRole` é SimpleCheck e devolve
    # booleano, não filtra linhas. Mesma divisão de `Appointment`.
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole, roles: :any, clinic_from: :tenant}
    end

    # O webhook não tem sessão: ele chama com `authorize?: false`, que não passa por policy.
    # Esta linha existe para a ação não ficar sem policy nenhuma (= proibida) se um dia alguém
    # a chamar com actor.
    policy action(:by_provider_id) do
      authorize_if always()
    end
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id

    # **A leitura pode rodar sem tenant** — e isso é para o webhook, não para conveniência.
    #
    # O evento de entrega chega sem `clinic_id` (doc 52 §10.2) e a busca por `provider_message_id`
    # é justamente a que o descobre; com `global? false` o Ash recusaria a query antes de ela
    # chegar ao banco ("requires a tenant to be specified").
    #
    # O que impede isto de virar um buraco é que **a RLS continua fechando**: sem GUC nenhuma, a
    # policy de `messages` não casa linha alguma. As únicas formas de ler sem tenant são as duas
    # GUCs de porta única — `movimento.provider_message_id` (webhook) e `movimento.message_id`
    # (resposta do paciente) —, cada uma alcançando exatamente uma linha já identificada por um
    # segredo que o chamador provou possuir. Ou seja: aqui o Ash deixa passar e o Postgres decide.
    global? true
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :canal, Api.Messaging.MessageChannel, allow_nil?: false, public?: true
    attribute :kind, Api.Messaging.MessageKind, allow_nil?: false, public?: true

    # O nome do template e as variáveis que o preenchem. O corpo é renderizado na leitura por
    # `Api.Messaging.Templates` — ver o moduledoc.
    attribute :template, :string, allow_nil?: false, public?: true, constraints: [max_length: 80]
    attribute :vars, :map, allow_nil?: false, default: %{}, public?: true

    # E-mail ou telefone, congelado no envio. Ver o moduledoc.
    attribute :destino, :string, allow_nil?: false, public?: true, constraints: [max_length: 160]

    attribute :status, Api.Messaging.MessageStatus,
      allow_nil?: false,
      default: :pendente,
      public?: true

    # Quem transportou (`"resend"`, depois `"gupshup"`) e o id dele — a chave que o webhook usa
    # para achar esta linha.
    attribute :provider, :string, public?: true, constraints: [max_length: 40]
    attribute :provider_message_id, :string, public?: true, constraints: [max_length: 200]

    attribute :enfileirado_em, :utc_datetime, public?: true

    # Para quando o envio foi ADIADO pela janela de silêncio (§7). Nulo = sai agora.
    #
    # É o mesmo instante que vira `scheduled_at` no Oban, gravado aqui porque a tela precisa dele
    # e a tabela do Oban não é fonte de leitura da UI: ela é podada em 7 dias, o job some, e a
    # pergunta "por que não saiu?" continua de pé. Sem esta coluna a timeline mostrava só
    # "Na fila" e a recepção lia isso como falha — foi o que aconteceu no teste ao vivo de
    # 2026-07-28, com três mensagens corretamente adiadas para as 8h.
    attribute :agendado_para, :utc_datetime, public?: true
    attribute :enviado_em, :utc_datetime, public?: true
    attribute :entregue_em, :utc_datetime, public?: true
    attribute :lido_em, :utc_datetime, public?: true
    attribute :falhou_em, :utc_datetime, public?: true
    attribute :erro, :string, public?: true, constraints: [max_length: 300]

    attribute :respondido_em, :utc_datetime, public?: true
    attribute :resposta, Api.Messaging.MessageReply, public?: true

    # A retirada da fila (ver `MessageStatus` e `DescarteMotivo`). Carimbo próprio pelo mesmo
    # motivo dos outros estados: `instanteDoStatus` da timeline mostra o instante mais avançado
    # que a mensagem alcançou, e sem esta coluna ela mostraria a hora em que a mensagem ENTROU na
    # fila para explicar por que ela saiu dela.
    attribute :descartada_em, :utc_datetime, public?: true
    attribute :descarte_motivo, Api.Messaging.DescarteMotivo, public?: true

    timestamps()
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
    belongs_to :attendance, Api.Scheduling.Attendance, allow_nil?: false
    belongs_to :appointment, Api.Scheduling.Appointment, allow_nil?: false
    belongs_to :patient, Api.Records.Patient, allow_nil?: false

    # Nulo = automático (criação do bloco ou cron). Preenchido = alguém clicou.
    belongs_to :disparado_por, Api.Accounts.User
  end

  @doc """
  A mensagem chegou ao destino? Usada pela timeline e pelo "reenviar": `:pendente`/`:enviado` são
  estados em trânsito, e só `:falhou` é motivo para o botão pedir atenção.

  O `case` é deliberado: `MessageStatus.ordem/1` devolve `nil` em `:falhou`, e uma comparação
  direta (`ordem(status) >= ordem(:entregue)`) diria **true** para mensagem falhada — no
  ordenamento de termos do Elixir todo átomo é maior que todo número.
  """
  def entregue?(%{status: status}) do
    case MessageStatus.ordem(status) do
      nil -> false
      n -> n >= MessageStatus.ordem(:entregue)
    end
  end
end
