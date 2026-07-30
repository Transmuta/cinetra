defmodule Api.Scheduling.Preparations.OwnAgendaOnly do
  @moduledoc """
  A7/D1: o papel `profissional` enxerga **só a própria** agenda; os demais papéis veem a
  clínica inteira.

  É uma preparation e não um `authorize_if`, porque a pergunta não é "pode ler?" e sim "quais
  linhas": `HasClinicRole` é `SimpleCheck` e devolve booleano — não filtra linhas.

  ## Por que mora no domínio, e não dentro do `Appointment`

  Nasceu específica do `Appointment` — e o irmão `Attendance` ficou de fora, vazando os pares
  (agendamento, paciente) da clínica inteira para qualquer profissional, inclusive os sem
  vínculo. O recorte é da **agenda**, não de uma tabela; por isso o módulo é um só e cada
  recurso diz apenas **onde** mora o `professional_id`:

      prepare Api.Scheduling.Preparations.OwnAgendaOnly                        # Appointment
      prepare {Api.Scheduling.Preparations.OwnAgendaOnly, via: :appointment}   # Attendance

  ## O fail-open que este módulo existe para evitar

  `Membership.professional_id` é `allow_nil? true` — o moduledoc do recurso o chama de
  *"UUID mole"*. Existe, portanto, membro com `papel: :profissional` e `professional_id: nil`.
  A implementação ingênua ("se tem professional_id, filtra") deixaria esse membro **sem
  filtro nenhum**, ou seja, vendo a agenda inteira da clínica — exatamente o oposto da regra.

  Aqui o caso fecha: sem `professional_id`, o filtro é impossível de satisfazer e a leitura
  devolve lista vazia. Fail-**closed**. Tem teste dedicado nos dois recursos (doc 25 §4).
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @typedoc """
  O recorte da agenda para um vínculo, respondido **antes** de virar filtro:

    * `:clinica_inteira` — papel que vê tudo (`owner`·`admin`·`recepcao`);
    * `{:so_este_profissional, id}` — o papel `profissional`, com vínculo de diretório;
    * `:agenda_nenhuma` — `profissional` sem `professional_id` (o fail-closed do "UUID mole");
    * `:sem_vinculo` — não há membership resolvível (chamada interna, seed) — **não** é o mesmo
      que `:agenda_nenhuma`: aqui não há recorte a aplicar, ver `prepare/3`.
  """
  @type recorte ::
          :clinica_inteira
          | {:so_este_profissional, Ecto.UUID.t()}
          | :agenda_nenhuma
          | :sem_vinculo

  @impl true
  def prepare(query, opts, context) do
    case recorte(Map.get(context, :actor), Map.get(context, :tenant) || query.tenant, query) do
      :agenda_nenhuma ->
        # Fail-closed: profissional sem vínculo de diretório não vê agenda nenhuma.
        Ash.Query.filter(query, false)

      {:so_este_profissional, professional_id} ->
        filter_own(query, opts[:via], professional_id)

      _ ->
        query
    end
  end

  @doc """
  A **mesma** regra do filtro, respondida como valor — para quem precisa dela fora de uma query.

  Existe por causa do `ApiWeb.AgendaChannel`: no modo `signal` (Semana e Mês) o canal só precisa
  saber **se** este assinante enxerga o bloco, não o bloco. Reler o agendamento inteiro para
  jogar fora o resultado eram as 6 queries do D-H; perguntar aqui custa zero, porque a membership
  já vem carregada no escopo do `join`.

  O ponto de manter isto neste módulo é que o recorte A7 continua com **uma** autoridade: quem
  filtra linhas (`prepare/3`) e quem responde sim/não saem da mesma função. Reimplementar a
  comparação de `professional_id` no canal seria recriar a assimetria leitura×escrita que o
  achado (b) do doc 26 fechou.
  """
  # Papel e `professional_id` são **por-tenant** — o mesmo usuário é profissional numa clínica
  # e admin em outra — então não dá para derivá-los do actor sozinho. Quem resolve é
  # `Api.Accounts.ActiveMembership`, a MESMA fonte que a escrita usa (`OwnProfessionalColumn`).
  #
  # Antes daqui saía direto do `Api.Scope`, e era esse o achado (b) do doc 26: a leitura
  # acreditava no escopo, a escrita consultava o banco. Agora as duas fazem a mesma pergunta ao
  # mesmo módulo — que continua reusando o escopo no caminho feliz, mas conferindo.
  #
  # Sem membership resolvível (chamada interna, seed) não há recorte: quem chama de dentro,
  # sem actor ou sem tenant, está fora da fronteira HTTP e já respondeu por si. É o
  # `:sem_vinculo` — e por isso ele é um valor **distinto** de `:agenda_nenhuma`: quem lê pela
  # fronteira (o canal) trata a ausência de vínculo como "não empurra", quem chama de dentro
  # (seed, cascata) segue sem filtro.
  #
  # O caso que só apareceu ao MEDIR a requisição real: a query de `load:` de relacionamento
  # (o `load: [:attendances]` da agenda) não herda o contexto da query de cima — só a chave
  # `:shared`. Lendo o `Api.Scope` direto do contexto, esta preparation recebia `nil` ali,
  # devolvia "sem papel" e **não filtrava nada**.
  #
  # Duas ressalvas, porque a versão sem elas soa mais grave do que é. Primeira: não era
  # explorável, e não é só que "não vazou" — as `attendances` chegam sempre penduradas em
  # `Appointment`s que o filtro do pai já recortou, então não há entrada pela qual a falta do
  # filtro aninhado se manifeste. Segunda: por isso mesmo, **nenhum teste de comportamento a
  # pega** — tentou-se, e o teste passa igual com o código antigo. O que se corrigiu é a
  # garantia deixar de ser acidental: ela era consequência do pai, agora é regra do filho.
  #
  # Quem faz isso é o fallback ao banco em `ActiveMembership` — não o canal `:shared`, que é
  # só a economia de query do achado (g). Tirar o `:shared` deixa isto correto e mais lento.
  @spec recorte(term(), term(), term()) :: recorte()
  def recorte(actor, tenant, subject \\ nil) do
    case Api.Accounts.ActiveMembership.fetch(actor, tenant, subject) do
      {:ok, %{papel: :profissional, professional_id: nil}} -> :agenda_nenhuma
      {:ok, %{papel: :profissional, professional_id: id}} -> {:so_este_profissional, id}
      {:ok, _membership} -> :clinica_inteira
      :error -> :sem_vinculo
    end
  end

  defp filter_own(query, nil, professional_id),
    do: Ash.Query.filter(query, professional_id == ^professional_id)

  defp filter_own(query, :appointment, professional_id),
    do: Ash.Query.filter(query, appointment.professional_id == ^professional_id)
end
