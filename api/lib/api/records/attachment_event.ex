defmodule Api.Records.AttachmentEvent do
  @moduledoc """
  A trilha dos anexos: **uma linha por toque** — envio, visualização, renomeação e remoção.

  ## Por que uma tabela própria, e não `AshPaperTrail`

  A trilha do projeto (`Api.Scheduling.TrailMixin`) registra **escritas**: ela existe para
  responder "quem mudou este agendamento". A pergunta que a LGPD faz sobre anexo é outra e mais
  dura — *"quem **leu** o laudo?"* — e leitura não produz versão nenhuma. Os docs cobram isso
  duas vezes ([`05 §5.5`](../../../docs/05-observabilidade-e-producao.md): *"cada acesso a anexo
  fica na trilha LGPD, que é exatamente o que o protótipo não tem"*;
  [`06 §7.2`](../../../docs/06-seguranca-e-lgpd.md), item b), e o AshPaperTrail simplesmente não
  responde a ela.

  Uma tabela de eventos responde às duas de uma vez, com um bônus: o `:visualizou` é gravado no
  momento em que a **URL assinada é emitida**, que é o instante em que o acesso de fato é
  concedido — não quando o usuário abre a tela.

  ## Por que quase nada aqui é FK

  Só `clinic_id` tem chave estrangeira. `attachment_id`, `patient_id` e `user_id` são colunas
  `uuid` cruas, de propósito: **o registro precisa sobreviver ao que ele registra**. Uma FK para
  `attachments` com `CASCADE` apagaria a prova de quem leu o laudo junto com o laudo — que é o
  contrário de auditoria; e com `RESTRICT` impediria a remoção do anexo. Guardar o `nome` do
  anexo no momento do evento é parte da mesma ideia: a linha continua legível depois que o anexo
  não existe mais.
  """
  use Ash.Resource,
    otp_app: :api,
    domain: Api.Records,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "attachment_events"
    repo Api.Repo

    references do
      reference :clinic, on_delete: :delete
    end

    custom_indexes do
      # Um índice só: serve o recorte por tenant (coluna líder, obrigatório sob RLS), a pergunta
      # "quem tocou neste anexo" e a ordem cronológica. Um segundo índice para o feed por clínica
      # só entra quando existir tela que o leia — é a lição do D-2 (índice que ninguém lê é peso
      # em todo INSERT, e aqui todo *acesso* é um INSERT).
      index [:clinic_id, :attachment_id, :inserted_at]
    end
  end

  actions do
    defaults [:read, create: [:acao, :attachment_id, :patient_id, :user_id, :nome]]
  end

  policies do
    # Ler a trilha é owner/admin, a mesma régua da tela de auditoria (doc 25 §11.2): recepção
    # opera anexos, mas não audita quem os leu.
    policy action_type(:read) do
      authorize_if {Api.Accounts.Checks.HasClinicRole,
                    roles: [:owner, :admin], clinic_from: :tenant}
    end

    # Ninguém escreve de fora. A gravação é do próprio sistema (`Api.Records.registrar_evento/4`,
    # com `authorize?: false`), e uma trilha que a aplicação autenticada pode editar não é
    # trilha. Explícito, e não por omissão: se alguém expuser esta ação num controller, o 403
    # aparece na hora em vez de a linha ser forjável.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  changes do
    change Api.Tenancy.SetTenantGuc
  end

  multitenancy do
    strategy :attribute
    attribute :clinic_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :acao, Api.Records.AttachmentEventAction, allow_nil?: false, public?: true

    # Colunas cruas, sem FK — ver o moduledoc.
    attribute :attachment_id, :uuid, allow_nil?: false, public?: true
    attribute :patient_id, :uuid, allow_nil?: false, public?: true
    attribute :user_id, :uuid, public?: true

    # Instantâneo do nome no momento do evento: a linha tem de continuar legível depois que o
    # anexo for removido.
    attribute :nome, :string, allow_nil?: false, public?: true, constraints: [max_length: 200]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :clinic, Api.Accounts.Clinic, allow_nil?: false
  end
end
