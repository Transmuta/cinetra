defmodule Api.Audit.Capture do
  @moduledoc """
  O change que grava **um evento por escrita auditável** (doc 63 §3). É a única porta de escrita
  da trilha e substitui o `AshPaperTrail` como mecanismo de captura.

      change {Api.Audit.Capture, resource: :patient, label: :nome}

  Opções:

    * `:resource` (obrigatório) — o `Api.Audit.ResourceKind` da linha;
    * `:label` — o atributo do registro que dá o nome legível (`:nome`, `:titulo`). Pode ser uma
      lista, e a primeira chave não-nula vence (`[:nome_social, :nome]`), ou
      `{:load, :user, :nome}` para os recursos cujo nome mora num vizinho — é o caso do
      `Membership`, que não tem nome próprio e cuja linha precisa dizer *de quem* o acesso foi
      revogado. Custa uma leitura, e só nesses (convite/troca de papel/revogação são raros);
    * `:meta` — atributos copiados para o contexto da linha (`[:patient_id, :starts_at]`), que é
      o que a tela usa para montar a frase e o link "ver na agenda";
    * `:tenant_from` — de qual campo do resultado sai o `clinic_id` da linha. Default
      `:clinic_id`, que serve todo recurso por-tenant. `Clinic` e `Membership` **não** têm bloco
      `multitenancy` (o `changeset.tenant` deles é nulo), e no `Clinic` o tenant é o próprio
      `:id` — daí a opção existir em vez de ser adivinhada;
    * `:keep` — FKs que **ficam** no diff, apesar da regra `*_id` (abaixo). É para a FK que é uma
      decisão de alguém, e não um vínculo estrutural: trocar o profissional de um bloco ao
      remarcar é a única coisa que mudou naquela escrita, e sem isto a linha saía com o diff
      vazio (medido: três remarcações no banco de dev, todas mudas). O uuid é resolvido por NOME
      na leitura, junto com o de `meta`;
    * `:skip_unchanged` — nomes de ação (átomos) cuja escrita **derivada** só vira linha quando
      de fato mudou algo. É o caso de `add_participant`/`remove_participant` no agendamento: a
      composição da turma muda na PRESENÇA (que tem linha própria, e é a única que diz de quem se
      fala), e no bloco sobrava um "Adicionou um participante" com **diff vazio** — uma linha que
      ocupa espaço sem informar nada. Vale só para `update`: num `create` o diff vazio ainda
      significa "nasceu", e num `destroy` ele é a regra.

  ## A cascata que a decisão já contou

  Um fato só merece **uma** linha. Cancelar um bloco de quatro pessoas é uma decisão: escrevia
  cinco linhas no mesmo segundo (o bloco e as quatro presenças que apenas o refletem). Pausar um
  pacote de dez sessões escrevia onze. Marcar uma falta escrevia duas — a presença e o rollup do
  desfecho do bloco, que é derivado dela.

  O silêncio dessas escritas não é opção deste change: é um **marcador no contexto**, posto por
  quem dispara a cascata. Duas rotas, porque são dois mecanismos:

    * `context: %{audit_cascade: true}` — na própria escrita filha, quando é o nosso código que a
      chama (`CascadeToAttendances`, `RollupBlockStatus`, o `set_pkg_hold` do pacote);
    * `context: %{shared: %{audit_cascade_children: true}}` — no PAI, quando quem dispara a filha é
      o Ash (`manage_relationship`, em `ManageParticipants`) e não há onde pôr contexto na filha.
      `shared` é o único pedaço que o Ash repassa, e é lido junto com o `accessing_from` que ele
      carimba só na filha — sem esse par o marcador calaria o próprio pai, que é justamente a linha
      que se quer preservar (o `set_context` do Ash espelha o `shared` no topo do contexto de quem
      o põe).

  A regra que decide quem cala: **quem decidiu conta, o reflexo cala**. Cancelar/reabrir um bloco é
  decisão do bloco → as presenças calam. Entrar, sair ou faltar é decisão sobre a presença → o
  bloco cala (o rollup do desfecho e as linhas de diff vazio de `add`/`remove_participant`).

  ## Roda no `after_action` — dentro da transação

  Deliberado. Se a gravação do evento falhar, a escrita de negócio falha junto e volta inteira.
  A alternativa (`after_transaction`) perderia eventos em silêncio quando o INSERT da trilha
  falhasse — e uma auditoria que perde evento sem avisar é pior do que não ter auditoria, porque
  o silêncio dela é lido como "não aconteceu".

  ## O diff sai daqui pronto

  `changeset.attributes` é o que de fato mudou; `changeset.data` é o antes e `result` é o depois.
  Num `create` o `data` é o struct vazio, então tudo entra com `from: nil` — que é a leitura
  correta. Num `destroy` não há "depois": a linha fica com o diff vazio e é o `action_type` que
  conta a história.

  Campos de `Api.Audit.Sensiveis` entram **sem valor** (D-Aud4), e `clinic_id`/timestamps ficam
  de fora: o primeiro é o tenant (está na coluna), os outros são ruído em toda linha.

  ## `authorize?: false`, e não é atalho

  A policy do `Event` proíbe escrita para **todo mundo** (`forbid_if always()`), de propósito. A
  trilha é gravada pelo sistema e por mais nada; passar pela policy aqui só significaria ter de
  abrir uma exceção que a aplicação autenticada poderia depois usar para forjar linha.
  """
  use Ash.Resource.Change

  # Campos que nunca viram linha de diff. Três grupos, e a lista vem da tela anterior (doc 25
  # §11.4) — não é invenção nova:
  #
  #   * **timestamps, tenant e a PK** — ruído em toda linha; o tenant e o `id` já são colunas da
  #     própria trilha (`clinic_id`, `record_id`), então repeti-los no diff é dizer duas vezes.
  #     `:id` precisa ser explícito: a regra `*_id` abaixo **não** o pega, e foi assim que ele
  #     apareceu como primeira linha do diff de todo `create`;
  #   * **`version`** — contador de locking otimista, incrementado a cada escrita: apareceria em
  #     100% das entradas dizendo nada;
  #   * **FKs por-uuid** (regra `*_id`, abaixo) — um diff `<uuid> → <uuid>` não diz nada a quem
  #     lê a tela, e o contexto que importa (qual paciente, qual profissional) viaja em `meta`,
  #     onde é resolvido por NOME na leitura.
  #
  # `:ignore` no `use` acrescenta os específicos de um recurso — `ends_at` do agendamento, por
  # exemplo, que é derivado de `starts_at` + duração e dobraria a linha de todo remarcar.
  @ignorados [:id, :inserted_at, :updated_at, :clinic_id, :version]

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :resource) do
      {:ok, resource} when is_atom(resource) -> {:ok, opts}
      _ -> {:error, "Api.Audit.Capture exige `resource:` (um Api.Audit.ResourceKind)"}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      registrar(changeset, result, opts, context)
      {:ok, result}
    end)
  end

  defp registrar(changeset, result, opts, context) do
    resource = Keyword.fetch!(opts, :resource)

    diff =
      diff(
        changeset,
        result,
        resource,
        Keyword.get(opts, :ignore, []),
        Keyword.get(opts, :keep, [])
      )

    if silenciar?(changeset, diff, Keyword.get(opts, :skip_unchanged, [])) do
      :ok
    else
      gravar(changeset, result, resource, diff, opts, context)
    end
  end

  # As duas formas de silêncio: a cascata que a decisão já contou (o marcador, sempre) e a escrita
  # derivada que não mudou nada (`:skip_unchanged`).
  defp silenciar?(changeset, diff, skip) do
    cascata_ja_contada?(changeset) or derivada_muda?(changeset, diff, skip)
  end

  # Ver "A cascata que a decisão já contou" no moduledoc. A segunda cláusula exige o par
  # `accessing_from` + marcador: só o FILHO que o Ash dispara por relação gerenciada leva o
  # carimbo, e é ele que separa a filha do pai que pôs a marca.
  defp cascata_ja_contada?(%{context: %{audit_cascade: true}}), do: true

  defp cascata_ja_contada?(%{context: %{accessing_from: %{}, audit_cascade_children: true}}),
    do: true

  defp cascata_ja_contada?(_changeset), do: false

  # Ver `:skip_unchanged` no moduledoc.
  defp derivada_muda?(%{action: %{type: :update, name: name}}, [], skip), do: name in skip
  defp derivada_muda?(_changeset, _diff, _skip), do: false

  defp gravar(changeset, result, resource, diff, opts, context) do
    Api.Audit.record_event!(
      %{
        resource: resource,
        action_type: changeset.action.type,
        action: to_string(changeset.action.name),
        record_id: Map.get(result, :id),
        label: Api.Audit.rotulo(label(result, Keyword.get(opts, :label))),
        user_id: ator_id(context),
        user_label: Api.Audit.rotulo(ator_nome(context)),
        at: agora(changeset),
        diff: diff,
        meta: meta(result, Keyword.get(opts, :meta, []))
      },
      tenant: tenant(changeset, result, Keyword.get(opts, :tenant_from, :clinic_id)),
      authorize?: false
    )
  end

  # ---- o diff ----

  defp diff(changeset, result, resource, extras, mantidos) do
    changeset.attributes
    |> Map.keys()
    |> Enum.reject(&ignorar?(&1, extras, mantidos))
    |> Enum.sort()
    |> Enum.flat_map(&linha(&1, changeset.data, result, resource))
  end

  defp ignorar?(field, extras, mantidos) do
    cond do
      field in extras -> true
      field in mantidos -> false
      field in @ignorados -> true
      true -> String.ends_with?(Atom.to_string(field), "_id")
    end
  end

  defp linha(field, antes, depois, resource) do
    de = Map.get(antes, field)
    para = Map.get(depois, field)

    cond do
      de == para -> []
      Api.Audit.Sensiveis.redigir?(resource, field) -> [redigida(field)]
      true -> [%{field: to_string(field), from: dump(de), to: dump(para)}]
    end
  end

  defp redigida(field), do: %{field: to_string(field), redacted: true}

  # O valor vai para uma coluna `jsonb`, então tudo que não é escalar JSON precisa virar texto
  # AQUI — se um `%Date{}` chegasse cru ao Jason, a escrita da trilha derrubaria a escrita de
  # negócio junto (é o preço de gravar dentro da transação, e é o preço certo).
  defp dump(nil), do: nil
  defp dump(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp dump(value) when is_atom(value), do: to_string(value)
  defp dump(%Date{} = value), do: Date.to_iso8601(value)
  defp dump(%Time{} = value), do: Time.to_iso8601(value)
  defp dump(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp dump(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp dump(%Decimal{} = value), do: Decimal.to_string(value)
  defp dump(value) when is_list(value), do: Enum.map(value, &dump/1)

  defp dump(%{} = value) when not is_struct(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), dump(v)} end)

  defp dump(value), do: inspect(value)

  # ---- contexto da linha ----

  defp label(nil, _field), do: nil
  defp label(_result, nil), do: nil

  # O nome mora num vizinho (`Membership` → `user.nome`). `authorize?: false` porque isto é
  # detalhe interno da gravação, já dentro da transação e do tenant — o precedente do
  # enriquecimento da própria trilha.
  defp label(result, {:load, rel, field}) do
    case Ash.load(result, rel, authorize?: false) do
      {:ok, loaded} -> loaded |> Map.get(rel) |> label(field)
      _ -> nil
    end
  end

  defp label(result, fields) when is_list(fields) do
    Enum.find_value(fields, &label(result, &1))
  end

  defp label(result, field) when is_atom(field) do
    case Map.get(result, field) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp meta(result, fields) do
    Map.new(fields, fn field -> {to_string(field), dump(Map.get(result, field))} end)
  end

  defp ator_id(%{actor: %{id: id}}) when is_binary(id), do: id
  defp ator_id(_), do: nil

  defp ator_nome(%{actor: %{nome: nome}}) when is_binary(nome) and nome != "", do: nome
  defp ator_nome(%{actor: %{email: email}}) when is_binary(email), do: to_string(email)
  defp ator_nome(_), do: nil

  # O relógio do escopo (ADR-009), não `utc_now`: é o que torna a janela de dedup da D-Aud6
  # testável sem o teste depender do relógio de parede.
  defp agora(changeset) do
    case changeset.context do
      %{now: %DateTime{} = now} -> now
      _ -> DateTime.utc_now()
    end
  end

  # De qual clínica é o evento. **O registro vence o tenant da requisição**, e a ordem importa.
  #
  # Era o contrário (`changeset.tenant || …`), e isso vazava entre tenants: quem já tem clínica
  # ativa e cria uma segunda passa `scope:`, o `Api.Scope` implementa `get_tenant`, então
  # `changeset.tenant` chega preenchido com a clínica ANTIGA — e o evento de criação da nova
  # caía na trilha da anterior. Dois estragos de uma vez: o nome de uma organização aparecendo
  # no `/auditoria` de outra (e a RLS não pega, porque a linha foi gravada *legitimamente*
  # dentro do tenant errado), e a clínica nova nascendo sem o registro do próprio nascimento.
  #
  # Para todo recurso por-tenant os dois valores são idênticos (o Ash preenche `clinic_id` a
  # partir do tenant), então inverter não muda nada onde já estava certo — só conserta onde o
  # registro **é** o tenant (`Clinic`, via `tenant_from: :id`) ou onde não há tenant na
  # requisição (`Membership`, que não tem bloco `multitenancy`).
  #
  # Nulo aqui **levanta** no `record_event!`, e é o que se quer: um evento que não sabe de qual
  # clínica é não pode ser gravado (a RLS o rejeitaria de qualquer forma) e não deve ser
  # descartado em silêncio.
  defp tenant(changeset, result, tenant_from) do
    Map.get(result, tenant_from) || changeset.tenant
  end
end
