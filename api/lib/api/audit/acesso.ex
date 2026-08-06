defmodule Api.Audit.Acesso do
  @moduledoc """
  A trilha de **leitura** (doc 63, D-Aud6) — a metade da auditoria que o `AshPaperTrail` nunca
  respondeu, e que o [`06 §4`](../../../docs/06-seguranca-e-lgpd.md) cobra em letras claras:
  *"acesso a dado de saúde é auditável — **não só a escrita, a leitura também**"*.

  Ler não produz changeset, então não há change que capture: quem grava é o caminho da leitura,
  no ponto em que o acesso de fato é concedido.

  Dois eventos hoje:

    * `visualizou_ficha` — abrir a ficha completa de um paciente;
    * `visualizou` (`resource: :attachment`) — a emissão da **URL assinada** do anexo. É o
      instante certo: quem tem a URL tem os bytes, mesmo que a tela nunca chegue a renderizar.

  ## A deduplicação, e por que ela é o que torna isso aceitável

  A objeção contra auditar leitura é concreta: um `INSERT` por abertura de ficha, na tela mais
  usada da recepção. Uma ficha revisitada quatro vezes em dez minutos são quatro linhas que
  contam a mesma história e triplicam a tabela que já é a que mais cresce.

  A janela de **30 minutos** por `(clínica, usuário, registro, ação)` troca esse `INSERT` por um
  **índice-hit**: o `audit_events_record_index` responde "já registrei isto?" sem varrer nada. O
  que se perde é a contagem de aberturas; o que se preserva — e é o que a LGPD pergunta — é
  *quem teve acesso a quê, e quando*.

  A janela é comparada contra `scope.now` (ADR-009), não contra o relógio de parede: é o que
  torna o comportamento testável sem o teste depender do momento em que roda.

  ## Falhar aqui não derruba a leitura

  Ao contrário da captura de escrita (`Api.Audit.Capture`, que roda **dentro** da transação de
  propósito), aqui o registro é melhor-esforço: um erro ao gravar a trilha não pode impedir a
  recepção de abrir uma ficha. A assimetria é deliberada — uma escrita não auditada corrompe o
  histórico, uma leitura não auditada é uma linha faltando num log.
  """

  require Ash.Query
  require Logger

  # 30 minutos. Mora aqui, num lugar só, pelo mesmo motivo da retenção.
  @janela_minutos 30

  @doc "A janela de deduplicação, em minutos."
  def janela_minutos, do: @janela_minutos

  @doc """
  Registra que alguém **abriu a ficha** de um paciente.

  Chamado da fronteira (o `show` de `/api/patients/:id`), não do domínio: o que se audita é o
  acesso da PESSOA à ficha completa, e as leituras internas de `Patient` (a agenda resolvendo
  nomes, o relatório contando faltas) não são isso — auditá-las encheria a trilha de ruído de
  máquina e afogaria o sinal.
  """
  def ficha_visualizada(%Api.Scope{} = scope, %{id: id, nome: nome}) do
    registrar(scope, :patient, id, nome, "visualizou_ficha", %{"patient_id" => id})
  end

  @doc """
  Registra um toque em anexo — `:visualizou` (emissão da URL assinada), `:enviou`, `:renomeou`
  ou `:removeu`.

  As escritas também passam por aqui, e não pelo `Capture`: `Api.Records` chama estes pontos com
  o anexo **já** carregado, e a trilha guarda o `nome` do anexo no momento do evento para a linha
  continuar legível depois que ele for removido.

  **Anexo não é deduplicado** — nem a visualização. A dedup existe para a ficha, que a recepção
  reabre dezenas de vezes por dia; baixar um laudo é raro e é o evento que mais interessa contar.
  "Quantas vezes fulano baixou este exame" é uma pergunta legítima da LGPD, e uma janela de 30
  minutos a apagaria. Volume não é argumento aqui: uma linha por download é ordens de grandeza
  menos do que uma por abertura de tela.
  """
  def anexo_tocado(%Api.Scope{} = scope, acao, anexo) do
    meta = %{"patient_id" => anexo.patient_id, "attachment_id" => anexo.id}

    registrar(scope, :attachment, anexo.id, anexo.nome, to_string(acao), meta,
      tipo: tipo_do_anexo(acao),
      dedup?: false
    )
  end

  @doc """
  O mesmo que `anexo_tocado/3`, mas **propaga a falha** em vez de engolir.

  Existe para o caminho do **download**, que é o único em que a trilha é pré-condição do acesso e
  não registro posterior: a URL assinada dá ao portador os bytes de um laudo, e a LGPD pergunta
  "quem baixou". Emitir a URL sem conseguir gravar quem a pediu é entregar o dado sem rastro.

  Até o doc 96 (B-5) isso era só uma promessa de docstring: `Api.Records` tinha um
  `registrar_evento!/3` que era clone **byte a byte** do `registrar_evento/3` sem bang, e os dois
  caíam no `gravar/7`, que termina em `Logger.warning` + `:ok` e **nunca** levanta. Três lugares
  — o nome com `!`, o `@doc` de `attachment_download/2` e a implementação — diziam duas coisas
  diferentes, e a que valia era a mais frouxa.

  Os demais eventos de acesso seguem best-effort de propósito (ver `gravar/7`): abrir uma ficha
  não pode falhar porque a trilha falhou. O download é a exceção, e é deliberada.
  """
  def anexo_tocado!(%Api.Scope{} = scope, acao, anexo) do
    meta = %{"patient_id" => anexo.patient_id, "attachment_id" => anexo.id}

    registrar(scope, :attachment, anexo.id, anexo.nome, to_string(acao), meta,
      tipo: tipo_do_anexo(acao),
      dedup?: false,
      propagar?: true
    )
  end

  @doc """
  Registra uma **autorização negada** (doc 61 §3b) — o quarto evento que o `06 §4` pede e que
  alimenta a detecção de abuso do `06 §8`.

  Hoje um 403 vira resposta e some: não há como perceber alguém varrendo a clínica por IDOR. O
  projeto já **achou** um furo dessa classe (`/api/availability`, T-P1), e ele veio de auditoria
  manual — nada no sistema o teria acusado sozinho.

  Deduplicado pela mesma janela, e por um motivo prático: sem isso um cliente em laço transforma
  a trilha num log de acesso e a poda passa a ser a única coisa que a segura.
  """
  def acesso_negado(%Api.Scope{} = scope, caminho) when is_binary(caminho),
    do: acesso_negado(scope, caminho, caminho)

  @doc """
  O mesmo, com a **rota normalizada** separada do caminho cru.

  A dedup para eventos sem `record_id` casa por `label` — e enquanto o label era o path cru, com
  os UUIDs dentro, ela nunca casava justamente no caso que esta função existe para detectar:
  varredura por IDOR produz **um path distinto por tentativa** (doc 96, B-7). O resultado era o
  oposto do desenhado: uma linha por request na tabela que mais cresce do sistema, mais uma query
  síncrona de dedup a cada 403. O mecanismo anti-abuso amplificava o abuso.

  O `label` passa a ser a rota agrupável (`/api/patients/:id`), que é o que dedupa; o caminho cru
  continua em `meta["caminho"]`, que é o que permite investigar **qual** id foi tentado.

  A normalização é responsabilidade de quem conhece o roteador — a fronteira HTTP —, e não do
  domínio: `Api.Audit` não deve saber o que é um path do Phoenix.
  """
  def acesso_negado(%Api.Scope{} = scope, rota, caminho)
      when is_binary(rota) and is_binary(caminho) do
    registrar(scope, :seguranca, nil, rota, "acesso_negado", %{"caminho" => caminho}, tipo: :deny)
  end

  # ---- interno ----

  defp registrar(scope, resource, record_id, label, acao, meta, opts \\ [])

  defp registrar(%Api.Scope{clinic_id: nil}, _r, _id, _l, _a, _m, _o), do: :ok

  defp registrar(%Api.Scope{} = scope, resource, record_id, label, acao, meta, opts) do
    tipo = Keyword.get(opts, :tipo, :read)
    dedup? = Keyword.get(opts, :dedup?, true)

    if dedup? and ja_registrado?(scope, resource, record_id, label, acao) do
      :ok
    else
      gravar(scope, resource, record_id, label, acao, tipo, meta,
        propagar?: Keyword.get(opts, :propagar?, false)
      )
    end
  end

  # A dedup tem DUAS chaves possíveis, porque nem todo evento tem registro. Enquanto havia só
  # a primeira cláusula (`record_id == nil -> false`), o `:seguranca` — que é justamente o que
  # não tem id — passava direto: a dedup do 403 estava anunciada em dois comentários e **nunca
  # rodava**. Medido antes do conserto: 100 requests negados idênticos → 100 linhas.
  defp ja_registrado?(scope, resource, nil, label, acao) when is_binary(label) do
    consultar(scope, :recent_duplicate_by_label, %{
      resource: resource,
      label: Api.Audit.rotulo(label),
      action: acao,
      user_id: scope.user && scope.user.id,
      since: desde(scope)
    })
  end

  defp ja_registrado?(_scope, _resource, nil, _label, _acao), do: false

  defp ja_registrado?(scope, resource, record_id, _label, acao) do
    consultar(scope, :recent_duplicate, %{
      resource: resource,
      record_id: record_id,
      action: acao,
      user_id: scope.user && scope.user.id,
      since: desde(scope)
    })
  end

  defp desde(scope), do: DateTime.add(scope.now, -@janela_minutos * 60, :second)

  defp consultar(scope, acao, args) do
    Api.Tenancy.in_clinic(scope, fn ->
      Api.Audit.Event
      |> Ash.Query.for_read(acao, args, tenant: scope.clinic_id, authorize?: false)
      |> Ash.exists?(authorize?: false)
    end)
  end

  # Melhor-esforço **observável**. O moduledoc defende não derrubar a leitura por causa da
  # trilha, e a defesa continua de pé — mas "melhor-esforço" e "sem rastro nenhum" não são a
  # mesma coisa. Antes o retorno era descartado e a função devolvia `:ok` incondicionalmente:
  # a metade da auditoria que o `06 §4` cobra por nome podia falhar 100% em produção sem nada
  # acender. Foi assim que um caminho longo demais evadiu a trilha do 403 em silêncio.
  defp gravar(scope, resource, record_id, label, acao, tipo, meta, opts) do
    Api.Audit.record_event(
      %{
        resource: resource,
        record_id: record_id,
        label: Api.Audit.rotulo(label),
        action: acao,
        action_type: tipo,
        user_id: scope.user && scope.user.id,
        user_label: Api.Audit.rotulo(scope.user && scope.user.nome),
        at: scope.now,
        diff: [],
        meta: meta
      },
      tenant: scope.clinic_id,
      authorize?: false
    )
    |> case do
      {:ok, _evento} ->
        :ok

      {:error, erro} ->
        # **Sem `Exception.message/1` aqui.** A mensagem de um `Ash.Error.Invalid` carrega o
        # VALOR que falhou — e neste caminho o valor é o nome do paciente cuja ficha foi aberta,
        # ou o nome do anexo. Logar isso trocaria uma falha silenciosa por um vazamento de PII
        # no log, que é pior. O que se registra é o suficiente para investigar: qual evento e
        # quais campos recusaram.
        Logger.warning(
          "trilha de acesso não gravada (#{resource}/#{acao}): campos #{inspect(campos(erro))}"
        )

        # `propagar?` é o que separa os dois contratos (doc 96, B-5): best-effort em toda leitura
        # de tela, e **fail-closed** no download de anexo, onde a trilha é pré-condição do acesso.
        if Keyword.get(opts, :propagar?, false), do: {:error, erro}, else: :ok
    end
  end

  # Só os NOMES dos campos que a validação recusou — nunca os valores.
  defp campos(%{errors: errors}) when is_list(errors) do
    errors |> Enum.map(&Map.get(&1, :field)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp campos(erro), do: [erro.__struct__]

  defp tipo_do_anexo(:visualizou), do: :read
  defp tipo_do_anexo(:enviou), do: :create
  defp tipo_do_anexo(:removeu), do: :destroy
  defp tipo_do_anexo(_), do: :update
end
