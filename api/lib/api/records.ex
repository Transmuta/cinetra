defmodule Api.Records do
  @moduledoc """
  Domínio dos cadastros de paciente da clínica — recursos **por-tenant** por atributo
  (`strategy :attribute` sobre `clinic_id`, ADR-017): `Patient` (a ficha cadastral da v1),
  `Attachment` (anexos). A trilha de acesso a eles mora em `Api.Audit` desde o doc 63 —
  era um recurso próprio aqui (`AttachmentEvent`) que nenhuma rota expunha.

  `ClinicalTag` cifrado e `Consent` versionado seguem em v2 (D16). **`Attachment` saiu do v2**
  em 2026-07-27 — o ADR-013 o listava explicitamente entre os adiados, e a emenda está no
  [`51`](../../../docs/51-ficha-anexos-e-storage.md).

  Os wrappers `*_clinic_patient` centralizam o `Api.Repo.with_clinic/2` aqui (na camada de
  domínio) para leitura, espelhando `Api.Directory`. A **escrita** não passa por
  `with_clinic`: ela seta a GUC dentro da própria transação via
  `Api.Tenancy.SetTenantGuc` (ver o moduledoc do change) — envolvê-la quebraria o
  caminho de erro (viraria 500 em vez de 422).
  """
  use Ash.Domain, otp_app: :api

  # Leitura sob RLS (o corte de tenancy é compartilhado — ver `Api.Tenancy`).
  import Api.Tenancy, only: [in_clinic: 2]
  # `expr/1` dos filtros das contagens por segmento.
  import Ash.Expr, only: [expr: 1]

  require Ash.Query

  alias Api.Records.Attachment
  alias Api.Records.Attachment.Conteudo
  alias Api.Records.Patient

  resources do
    resource Api.Records.Patient do
      define :create_patient, action: :create, args: [:nome]
      define :list_patients, action: :read
      define :list_patients_page, action: :list
      define :get_patient, action: :read, get_by: [:id]
      define :update_patient, action: :update
      define :deactivate_patient, action: :deactivate
      define :reactivate_patient, action: :reactivate
    end

    resource Api.Records.Attachment do
      define :list_attachments, action: :for_patient, args: [:patient_id]
      define :get_attachment, action: :read, get_by: [:id]
      define :start_attachment_row, action: :start
      define :confirm_attachment_row, action: :confirm
      define :rename_attachment_row, action: :rename
      define :destroy_attachment_row, action: :destroy
    end
  end

  @doc """
  Uma **página** da lista de pacientes da clínica ativa, já filtrada e buscada no servidor
  (ver `Api.Records.Preparations.FilterPatients`). Devolve `%Ash.Page.Offset{}` — `results`,
  `count` (total do recorte), `limit`, `offset`, `more?`.

  Opções: `:q` (busca), `:status` (`:todos`/`:ativos`/`:inativos`/`:resp`), `:limit`, `:offset`.
  Os limites (padrão, teto e teto de offset) são de `Api.Pagination` — o teto do offset existe
  por robustez, não por performance: sem ele um `?page=` gigante chega cru no Postgrex, que
  recusa qualquer coisa fora do int64 e derruba a request com 500.
  """
  def list_clinic_patients(%Api.Scope{} = scope, opts \\ []) do
    args = %{q: Keyword.get(opts, :q), status: Keyword.get(opts, :status, :todos)}

    in_clinic(scope, fn ->
      list_patients_page!(args, scope: scope, page: Api.Pagination.page_opts(opts))
    end)
  end

  @doc """
  Contagens por segmento para a sidebar (Todos / Ativos / Inativos / Com responsável).

  Precisa vir do servidor: com a lista paginada, contar o que chegou contaria só a página.
  **Independe da busca** — são "quantos pacientes existem em cada segmento", como o
  `sbPacientes` do protótipo ([`:1437`](../../../interface/Movimento.dc.html#L1437)), que conta
  sobre o cadastro inteiro e não sobre o termo digitado.

  Os quatro segmentos saem numa **única** query (`count(*) FILTER (WHERE …)`) via
  `Ash.aggregate`: contar um por vez varria as mesmas páginas de heap quatro vezes (medido no
  doc 24 §7: 29,1ms → 10,4ms). E continua dentro do Ash — policies e a ação `:list` valem
  igual, então contador e lista não podem divergir.
  """
  def clinic_patient_counts(%Api.Scope{} = scope) do
    in_clinic(scope, fn ->
      Api.Records.Patient
      |> Ash.Query.for_read(:list, %{}, scope: scope)
      |> Ash.aggregate!(
        [
          {:todos, :count, []},
          {:ativos, :count, [query: [filter: expr(ativo == true)]]},
          {:inativos, :count, [query: [filter: expr(ativo == false)]]},
          {:resp, :count, [query: [filter: expr(not is_nil(responsavel) and responsavel != "")]]}
        ],
        scope: scope
      )
    end)
  end

  @doc """
  Uma ficha da clínica ativa por id. De outra clínica é indistinguível de inexistente (o
  filtro por atributo não a enxerga) → `{:ok, nil}`, que o controller traduz em 404.

  `:load` é **opt-in** e existe por causa de `faltas`. Este lookup é a porta de entrada de seis
  chamadores (a ficha, o histórico, os anexos e as três escritas), e só um deles mostra o número.
  Carregá-lo aqui por padrão punha um `LEFT JOIN LATERAL` sobre `attendances` em todos —
  **inclusive no `PATCH`**, onde ninguém o lê. Medido no bate-volta: +67 buffers e ~0,9 ms por
  chamada, três vezes por abertura de ficha.
  """
  def fetch_clinic_patient(%Api.Scope{} = scope, id, opts \\ []) when is_binary(id) do
    # Um id malformado (não-UUID, ex.: link velho/typo) é indistinguível de inexistente: vira
    # {:ok, nil} → 404, e não o `InvalidArgument` que o `get` levanta e viraria 500 no controller.
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        load = Keyword.get(opts, :load, [])

        in_clinic(scope, fn ->
          get_patient(id, scope: scope, not_found_error?: false, load: load)
        end)

      :error ->
        {:ok, nil}
    end
  end

  @doc "Cria um paciente no cadastro da clínica ativa do escopo (só o nome é obrigatório)."
  def create_clinic_patient(%Api.Scope{} = scope, attrs) do
    {nome, rest} = Map.pop(attrs, :nome)
    create_patient(nome, rest, scope: scope)
  end

  @doc "Atualiza (parcialmente) uma ficha da clínica ativa."
  def update_clinic_patient(%Api.Scope{} = scope, patient, attrs) do
    update_patient(patient, attrs, scope: scope)
  end

  @doc "Arquiva um paciente (some da lista de ativos, sem apagar)."
  def deactivate_clinic_patient(%Api.Scope{} = scope, patient) do
    deactivate_patient(patient, %{}, scope: scope)
  end

  @doc "Reativa um paciente arquivado."
  def reactivate_clinic_patient(%Api.Scope{} = scope, patient) do
    reactivate_patient(patient, %{}, scope: scope)
  end

  @doc """
  Quais dos `ids` **não** são pacientes desta clínica (inclui os inexistentes).

  Espelha `Api.Directory.professional_in_clinic?/2`, e existe pelo mesmo motivo: id de
  paciente que chega no corpo de uma ação de **outro** recurso (o `patient_ids` do
  agendamento) não passa por lookup escopado nenhum, então nada o impede de ser de outra
  clínica. Devolver os intrusos, e não um booleano, é o que permite ao chamador dizer no 422
  *quais* ids ele recusou.

  Abre a própria transação com a GUC setada — a leitura precisa atravessar a RLS, e sob
  `mix test` (sandbox como `postgres`, BYPASSRLS) a falta disso passaria despercebida.
  """
  def patients_outside_clinic(ids, clinic_id) when is_list(ids) and is_binary(clinic_id) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    {:ok, found} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_patients!(
          tenant: clinic_id,
          authorize?: false,
          query: [filter: [id: [in: ids]]]
        )
      end)

    ids -- Enum.map(found, & &1.id)
  end

  @doc """
  Quais dos `ids` são pacientes desta clínica **arquivados** (doc 25 §7).

  Separado de `patients_outside_clinic/2` porque as duas perguntas têm respostas diferentes na
  fronteira: id de outra clínica não pode nem ser confirmado como existente, enquanto "está
  arquivado" é informação que o operador precisa ver para saber que basta reativar.

  Abre a própria transação com a GUC (mesma razão da irmã): sem ela a leitura volta vazia sob a
  RLS no servidor real — e **passa** no `mix test`, onde o sandbox conecta como `postgres`
  (BYPASSRLS). Voltar vazia aqui significaria "nenhum arquivado", ou seja, a validação
  desligada em produção e verde na suíte.
  """
  def inactive_patients(ids, clinic_id) when is_list(ids) and is_binary(clinic_id) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    {:ok, found} =
      Api.Repo.with_clinic(clinic_id, fn ->
        list_patients!(
          tenant: clinic_id,
          authorize?: false,
          query: [filter: [id: [in: ids], ativo: false]]
        )
      end)

    Enum.map(found, & &1.id)
  end

  # ============================ Anexos (doc 51) ============================
  #
  # O ciclo de vida do anexo mora aqui, e não no controller, porque cada passo é uma dupla
  # "banco + bucket" cuja ORDEM é a garantia de segurança (ver `Api.Records.Attachment`). Espalhar
  # isso pela camada HTTP seria espalhar a garantia.

  @doc "Os anexos disponíveis de um paciente da clínica ativa, do mais novo para o mais antigo."
  def list_patient_attachments(%Api.Scope{} = scope, %Patient{id: patient_id}) do
    in_clinic(scope, fn -> list_attachments!(patient_id, scope: scope) end)
  end

  @doc """
  Um anexo da clínica ativa por id. De outra clínica é indistinguível de inexistente → `{:ok, nil}`
  (o filtro por atributo não a enxerga), e id malformado idem — mesma escada de
  `fetch_clinic_patient/2`.
  """
  def fetch_clinic_attachment(%Api.Scope{} = scope, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        in_clinic(scope, fn -> get_attachment(id, scope: scope, not_found_error?: false) end)

      :error ->
        {:ok, nil}
    end
  end

  @doc """
  Abre um upload: valida o declarado, cria a linha `:pendente` e devolve a URL de `PUT` assinada.

  ## As duas ordens que importam

  **A clínica do paciente é casada na cabeça da função.** O `clinic_id` aparece duas vezes no
  padrão — no escopo e no paciente — então só há cláusula se forem o mesmo. É o furo cross-tenant
  que a fila de espera ensinou (doc 29), resolvido sem query: não existe caminho em que um
  `%Patient{}` de outra clínica gere anexo nesta.

  **A linha vem antes da URL.** Se a assinatura viesse primeiro e a criação falhasse, existiria
  uma URL válida para uma chave sem dono — o browser subiria e o objeto ficaria órfão no bucket,
  invisível ao sistema. Na ordem certa, o pior caso é linha `:pendente` sem objeto, que
  `Api.Housekeeping.PruneAttachments` recolhe.
  """
  def start_attachment(scope, patient, attrs)

  def start_attachment(
        %Api.Scope{clinic_id: clinic_id} = scope,
        %Patient{clinic_id: clinic_id, id: patient_id},
        attrs
      ) do
    with :ok <- storage_pronto(),
         :ok <- Conteudo.validar_declarado(attrs.content_type, attrs.bytes),
         :ok <- checar_cota(scope, patient_id) do
      # O id é gerado aqui porque a chave do objeto **deriva dele** — e a chave precisa existir
      # já no INSERT, para nunca haver linha sem destino conhecido.
      id = Ash.UUIDv7.generate()
      chave = Conteudo.chave(clinic_id, patient_id, id, attrs.content_type)

      with {:ok, anexo} <-
             start_attachment_row(
               %{
                 id: id,
                 chave: chave,
                 patient_id: patient_id,
                 nome: attrs.nome,
                 content_type: attrs.content_type,
                 bytes: attrs.bytes
               },
               scope: scope
             ),
           {:ok, upload} <- Api.Storage.presign_put(chave, attrs.content_type, attrs.bytes) do
        {:ok, anexo, upload}
      end
    end
  end

  def start_attachment(%Api.Scope{}, %Patient{}, _attrs), do: {:error, :patient_outside_clinic}

  @doc """
  Fecha o upload: confere o que **de fato** chegou ao bucket e libera o anexo.

  Duas leituras no storage — `HEAD` para o tamanho real e um `GET` de 16 bytes para a assinatura
  do formato — e a decisão de `Conteudo.conferir/4`. O que reprova é **descartado**: objeto
  apagado e linha destruída na mesma chamada, para não sobrar nem lixo nem estado ambíguo.

  A conferência é síncrona de propósito: sem antivírus ([`50 §D-6`](../../../docs/50-debitos-tecnicos.md)),
  ela custa dois round-trips e não justifica um job. Quando a varredura entrar, isto vira Oban e
  o enum ganha `:rejeitado`.
  """
  def confirm_attachment(%Api.Scope{} = scope, %Attachment{} = anexo) do
    with :ok <- autorizar(scope, anexo, :confirm) do
      confirmar(scope, anexo)
    end
  end

  # Já resolvido: **no-op**, sem storage e sem trilha. `confirm` é a transição `:pendente →
  # :disponivel`, e transição que já aconteceu não acontece de novo.
  #
  # Idempotente (`{:ok, anexo}`) em vez de erro porque a chamada legítima que se repete é a
  # retentativa: o browser terminou o `PUT`, a resposta do confirm se perdeu na rede, ele repete.
  # Devolver 422 aí faria o usuário reenviar um arquivo que já está no bucket.
  #
  # Sem esta cláusula, cada POST repetido gravava mais um evento `:enviou` e gastava mais duas
  # idas ao R2 — medido no bate-volta: 5 POSTs → 5 eventos. E reabria a conferência sobre bytes
  # que podem ter sido trocados depois da primeira aprovação, com o poder de **descartar** um
  # anexo válido.
  #
  # Fica DEPOIS de `autorizar/3`, e não numa cláusula de `confirm_attachment/2`: um no-op que
  # dispensa a autorização seria a única porta da fatia que responde `{:ok, _}` a quem a policy
  # recusa. Não vaza nada (quem chama já tem o struct em mãos), mas quebra a uniformidade que o
  # teste de defesa-em-profundidade afirma — e uniformidade é o que torna a regra verificável.
  defp confirmar(_scope, %Attachment{status: :disponivel} = anexo), do: {:ok, anexo}

  defp confirmar(scope, anexo) do
    case verificar(anexo) do
      {:ok, reais} ->
        gravar_confirmacao(scope, anexo, reais)

      # **Só** conteúdo reprovado leva ao descarte. Foi por misturar os dois casos que um
      # `Forbidden` chegava a apagar um laudo válido.
      {:error, motivo} ->
        descartar(scope, anexo, motivo)
    end
  end

  defp gravar_confirmacao(scope, anexo, bytes_reais) do
    case confirm_attachment_row(anexo, %{bytes: bytes_reais, content_type: anexo.content_type},
           scope: scope
         ) do
      {:ok, confirmado} ->
        registrar_evento(scope, :enviou, confirmado)
        {:ok, confirmado}

      # Falha na ESCRITA não descarta nada: os bytes conferidos estão íntegros no bucket, e
      # apagá-los transformaria um erro recuperável (tentar de novo) em perda de arquivo.
      erro ->
        erro
    end
  end

  # O que de fato chegou ao bucket: tamanho real e assinatura do formato. Devolve o tamanho
  # confirmado, que é o que vai para a coluna (o declarado já não interessa).
  defp verificar(anexo) do
    with {:ok, %{bytes: reais}} <- Api.Storage.head(anexo.chave),
         {:ok, amostra} <- Api.Storage.get_range(anexo.chave, 0, Conteudo.amostra() - 1),
         :ok <- Conteudo.conferir(anexo.content_type, anexo.bytes, reais, amostra) do
      {:ok, reais}
    end
  end

  @doc """
  URL assinada de leitura — e a linha de trilha que a LGPD exige.

  O evento `:visualizou` é gravado **na emissão da URL**, que é o instante em que o acesso é
  concedido (não quando a tela abre). E é gravado com a versão que levanta: se a trilha não pode
  ser escrita, o acesso não acontece. Auditoria que falha em silêncio é pior que auditoria
  nenhuma, porque dá a impressão de existir.
  """
  def attachment_download(%Api.Scope{} = scope, %Attachment{} = anexo) do
    with {:ok, %{url: url, expira_em: expira_em}} <-
           Api.Storage.presign_get(anexo.chave, anexo.nome, anexo.content_type),
         # A ordem importa: a URL é montada (nada saiu do servidor ainda), a trilha é gravada, e
         # só então a URL é devolvida. Se a gravação falhar, a URL **não vai** para o cliente.
         :ok <- registrar_evento!(scope, :visualizou, anexo) do
      {:ok, %{url: url, expira_em: expira_em}}
    end
  end

  @doc "Renomeia o rótulo do anexo. A chave do objeto no bucket é imutável."
  def rename_attachment(%Api.Scope{} = scope, %Attachment{} = anexo, nome) do
    with {:ok, renomeado} <- rename_attachment_row(anexo, %{nome: nome}, scope: scope) do
      registrar_evento(scope, :renomeou, renomeado)
      {:ok, renomeado}
    end
  end

  @doc """
  Remove o anexo — **os bytes primeiro, a linha depois**.

  Invertida, a ordem produziria o único órfão que o sistema não sabe encontrar: objeto no bucket
  sem linha no banco. Nesta, uma falha no meio deixa a linha viva apontando para um objeto que já
  foi — o download dá 404, o usuário repete a remoção, e o `delete` do R2 é idempotente. Feio,
  visível e recuperável, que é o que se quer de um modo de falha.

  **Mas a ordem cobra um preço**, e ele custou um bug: com o objeto indo primeiro, a policy do
  `destroy` só reprovaria *depois* de os bytes terem ido embora — um `profissional` chamando o
  domínio direto não removeria a linha, mas teria apagado o laudo. Daí `autorizar/3` na frente:
  **nada toca o bucket antes de a autorização passar**. Vale igual para `confirm_attachment/2`.
  """
  def delete_attachment(%Api.Scope{} = scope, %Attachment{} = anexo) do
    with :ok <- autorizar(scope, anexo, :destroy),
         :ok <- Api.Storage.delete(anexo.chave),
         :ok <- destroy_attachment_row(anexo, %{}, scope: scope) do
      registrar_evento(scope, :removeu, anexo)
      :ok
    end
  end

  @doc """
  A trilha de um anexo (owner/admin) — quem tocou, o quê e quando.

  Delega para `Api.Audit`: a trilha do anexo deixou de ser uma tabela própria (doc 63). Fica como
  atalho nomeado porque "o histórico deste anexo" é uma pergunta da ficha, não do feed.
  """
  def list_clinic_attachment_events(%Api.Scope{} = scope, attachment_id) do
    %{entries: entries} =
      Api.Audit.list_events(scope, resource: :attachment, record_id: attachment_id)

    entries
  end

  # ---- interno ----

  defp storage_pronto do
    if Api.Storage.configured?(), do: :ok, else: {:error, :storage_unconfigured}
  end

  # A cota conta **tudo**, inclusive `:pendente` — é limite de abuso, e o abuso passa
  # justamente por abrir uploads sem terminá-los. A leitura da ficha (`:for_patient`) conta só
  # os disponíveis; são perguntas diferentes.
  defp checar_cota(scope, patient_id) do
    total =
      in_clinic(scope, fn ->
        Attachment
        |> Ash.Query.for_read(:read, %{}, scope: scope)
        |> Ash.Query.filter(patient_id == ^patient_id)
        |> Ash.count!(scope: scope)
      end)

    if total >= Conteudo.max_por_paciente(), do: {:error, :cota_excedida}, else: :ok
  end

  # "Este ator pode mesmo executar esta ação neste anexo?" — perguntado ANTES de qualquer efeito
  # colateral no bucket. A policy do recurso continua sendo a autoridade; isto só antecipa a
  # resposta dela para antes do ponto sem volta.
  #
  # Roda dentro de `in_clinic` porque o check (`HasClinicRole`) consulta `memberships`, que tem
  # RLS: sem a GUC a consulta volta vazia e a autorização diria "não" por engano — a armadilha
  # que o `mix test` não pega, porque o sandbox conecta como `postgres` (BYPASSRLS).
  defp autorizar(%Api.Scope{user: user, clinic_id: clinic_id} = scope, anexo, acao) do
    pode? =
      in_clinic(scope, fn ->
        Ash.can?({anexo, acao}, user, tenant: clinic_id, data: anexo)
      end)

    if pode?, do: :ok, else: {:error, Ash.Error.Forbidden.exception([])}
  end

  defp descartar(scope, anexo, motivo) do
    Api.Storage.delete(anexo.chave)
    destroy_attachment_row(anexo, %{}, scope: scope)
    {:error, motivo}
  end

  # A trilha do anexo mora em `audit_events` desde o doc 63 — a mesma tabela do resto do
  # sistema, e por isso a mesma tela. Antes era `Api.Records.AttachmentEvent`, uma tabela de
  # eventos própria: o desenho estava certo (PaperTrail não registra leitura), mas ela **não
  # tinha rota nenhuma** — o `:visualizou` era gravado a cada download e a resposta a "quem leu
  # o laudo da Maria?" só saía por `psql`.
  defp registrar_evento(scope, acao, anexo), do: Api.Audit.Acesso.anexo_tocado(scope, acao, anexo)

  # A versão que de fato propaga. Ela e a de cima eram clones byte a byte — o `!` era decoração
  # (doc 96, B-5), e o `@doc` de `attachment_download/2` prometia um fail-closed que não existia.
  defp registrar_evento!(scope, acao, anexo),
    do: Api.Audit.Acesso.anexo_tocado!(scope, acao, anexo)
end
