defmodule Api.Generators do
  use Ash.Generator

  @moduledoc """
  As fábricas de dado de teste — **uma** definição do "clínica com dono, profissional, tipo e
  paciente", que doze arquivos de teste vinham escrevendo cada um a seu modo.

  Nasce do bate-volta da Onda 3 ([doc 43](../../../docs/43-bate-volta-onda-3.md) §5e): eram doze
  `defp setup_clinic` privadas, ~25 linhas cada, e nenhum `Ash.Generator` — contra o que
  `.claude/rules/ash.md` manda. O custo não é o teclado: quando o onboard passou a semear os cinco
  tipos de atendimento, ou quando `Api.Scope` ganhou `now:`, foi preciso caçar as doze.

  ## Como usa

  `Api.DataCase` já importa este módulo, então dentro de um teste:

      ctx = clinica()                       # %{owner, clinic, scope, prof, tipo, paciente}
      ctx = clinica(tipo: [grupo: true, capacidade: 4])
      outro = profissional!(ctx, "Dr. Y")
      p2 = paciente!(ctx, "Segundo")
      recep = escopo_de_membro!(ctx, :recepcao)

  ## Por que funções e não `changeset_generator`

  Os geradores de `Ash.Generator` produzem *dado de um recurso*; o que estes testes precisam é de
  um **contexto composto** (usuário → clínica → membership → `Api.Scope`), em que cada passo é uma
  ação de domínio com efeito próprio (`onboard` semeia tipos, cria membership de owner). Fábrica é
  a forma certa para isso — o `use Ash.Generator` fica pelo `sequence/2` e pelos geradores de
  recurso que vierem.

  Unicidade vem de `System.unique_integer([:positive])`: é global ao nó, o que a suíte async exige
  (ver a seção "Preventing Deadlocks in Concurrent Tests" de `.claude/rules/ash.md`).

  ## As fábricas de SESSÃO

  `usuario!/1` registra direto pelo domínio — é o que o teste de domínio precisa. Quem testa a
  fronteira (controller, canal) precisa de **sessão de verdade**, com o token que o
  `AshAuthentication` põe em `metadata`, e para isso o caminho tem de ser o magic link inteiro.
  Essa ida-e-volta estava copiada, byte a byte, em **catorze** arquivos de teste (I67): quatorze
  `defp sign_in`, quatorze `defp email`, e onze `defp member_session` que só divergiam no prefixo
  do e-mail. `sign_in!/1` e `sessao_de_membro!/4` são elas, uma vez.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records

  @doc """
  Uma clínica pronta para agendar: dono, clínica (com o onboard de verdade, que semeia os tipos e
  o membership de owner), `Api.Scope` do dono, um profissional, um tipo de atendimento e um
  paciente.

  Opções:

    * `:dono` — nome do usuário dono (default `"Dono"`);
    * `:prof` — nome do profissional (default `"Dra. X"`);
    * `:paciente` — nome do paciente (default `"Paciente"`);
    * `:tipo` — atributos do tipo de atendimento (ver `tipo!/2`), por exemplo
      `[grupo: true, capacidade: 4]` para uma turma;
    * `:now` — o instante do escopo (relógio injetado, D1).
  """
  def clinica(opts \\ []) do
    owner = usuario!(Keyword.get(opts, :dono, "Dono"))
    clinic = Accounts.onboard_clinic!("Clínica #{unico()}", %{}, actor: owner)
    ctx = %{owner: owner, clinic: clinic, scope: escopo(owner, clinic, opts)}

    Map.merge(ctx, %{
      prof: profissional!(ctx, Keyword.get(opts, :prof, "Dra. X")),
      tipo: tipo!(ctx, Keyword.get(opts, :tipo, [])),
      paciente: paciente!(ctx, Keyword.get(opts, :paciente, "Paciente"))
    })
  end

  @doc "Um usuário novo, com e-mail globalmente único."
  def usuario!(nome \\ "Dono"),
    do: Accounts.register_user!(nome, "u#{unico()}@example.com", authorize?: false)

  @doc """
  O `Api.Scope` de um usuário numa clínica. `opts[:now]` injeta o relógio (D1) — é o que os testes
  de série usam para se colocar antes/depois das sessões.
  """
  def escopo(user, clinic, opts \\ []) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)

    case Keyword.get(opts, :now) do
      nil -> Api.Scope.with_membership(user, membership)
      now -> Api.Scope.with_membership(user, membership, now: now)
    end
  end

  @doc "O mesmo escopo do `ctx`, com o relógio em `now` — o `scope_at` que sete arquivos copiavam."
  def escopo_em(ctx, %DateTime{} = now), do: escopo(ctx.owner, ctx.clinic, now: now)

  @doc """
  Um usuário **membro** da clínica com o papel pedido, e o escopo dele. `professional_id` vincula o
  membro a uma coluna da agenda — é o que o recorte A7 (`OwnAgendaOnly`) usa, e sem ele um
  `:profissional` não enxerga sessão nenhuma.
  """
  def escopo_de_membro!(ctx, papel, professional_id \\ nil) do
    user = usuario!(to_string(papel))

    {:ok, membership} =
      Accounts.invite_member(
        %{
          papel: papel,
          user_id: user.id,
          clinic_id: ctx.clinic.id,
          professional_id: professional_id
        },
        authorize?: false
      )

    {:ok, _} = Accounts.accept_invite(membership, authorize?: false)
    escopo(user, ctx.clinic)
  end

  @doc """
  Mais um profissional na clínica do `ctx`.

  Com telefone pelo mesmo motivo de `paciente!/2`: a `Api.Validations.TelObrigatorio` vale para os
  dois cadastros (D6), e sem isto toda fábrica do projeto estouraria em validação.
  """
  def profissional!(ctx, nome \\ "Dr. Y"),
    do:
      Directory.create_professional!(nome, %{tel: telefone_unico()},
        tenant: ctx.clinic.id,
        actor: ctx.owner
      )

  @doc """
  Mais um paciente na clínica do `ctx`.

  Já nasce com telefone porque ele **é obrigatório** desde a fase 2 da comunicação (doc 52 §9):
  sem isto, toda fábrica de teste do projeto passaria a estourar em validação. É a razão de esta
  fábrica existir num lugar só — a mudança que quebraria doze `defp setup_clinic` custou uma linha.
  """
  def paciente!(ctx, nome \\ "Paciente"),
    do:
      Records.create_patient!(nome, %{tel: telefone_unico()},
        tenant: ctx.clinic.id,
        actor: ctx.owner
      )

  @doc """
  Um celular brasileiro válido e globalmente único (`+5511 9XXXX-XXXX`).

  Celular, e não fixo, porque é o que faz o paciente ser alcançável por WhatsApp — teste que
  precise do contrário (fixo cai para o e-mail) escreve o número na mão, e o faz de propósito.
  """
  def telefone_unico do
    sufixo = unico() |> rem(100_000_000) |> Integer.to_string() |> String.pad_leading(8, "0")

    "+55119" <> sufixo
  end

  @doc """
  Um paciente **sem telefone** — a ficha legada que existia antes de o campo virar obrigatório.

  Escreve direto pelo repo, contornando a ação: é o único jeito de produzir a linha que o D6(b)
  deixa viva no banco e cobra no próximo save. Sem isto não haveria como testar o `:sem_canal`
  nem a própria cobrança da validação, porque a ação recusa criar o caso.
  """
  def paciente_legado_sem_tel!(ctx, attrs \\ %{}) do
    paciente = paciente_com(ctx, attrs)

    {1, _} =
      Api.Repo.update_all(
        from(p in "patients", where: p.id == type(^paciente.id, :binary_id)),
        set: [tel: nil]
      )

    %{paciente | tel: nil}
  end

  @doc """
  Um tipo de atendimento. Os defaults são os do individual de 50 min; `[grupo: true, capacidade: 4]`
  faz a turma. O nome leva sufixo único porque o tipo tem identity por nome na clínica — e o
  onboard já semeou cinco.
  """
  def tipo!(ctx, attrs \\ []) do
    attrs =
      %{
        nome: "Sessão #{unico()}",
        duracao_minutos: 50,
        cor: "#0FB5A6",
        icon: "Activity"
      }
      |> Map.merge(Map.new(attrs))

    Directory.create_appointment_type!(attrs, tenant: ctx.clinic.id, actor: ctx.owner)
  end

  @doc """
  Um agendamento na clínica do `ctx`, com um participante.

  Opções: `:paciente` (default o do `ctx`), `:prof`, `:tipo`, `:quando` (default amanhã às 10h no
  fuso da clínica) e `:scope`. Devolve o `Appointment` já com `attendances` carregadas — quem
  agenda quase sempre precisa da presença logo em seguida (é ela a âncora da comunicação, doc 52
  §3, e o alvo das ações de presença da A2).
  """
  def agendamento!(ctx, opts \\ []) do
    paciente = Keyword.get(opts, :paciente, ctx.paciente)
    scope = Keyword.get(opts, :scope, ctx.scope)

    {:ok, appointment} =
      Api.Scheduling.schedule_appointment(
        %{
          starts_at: Keyword.get(opts, :quando, amanha_as(ctx, 10)),
          professional_id: Keyword.get(opts, :prof, ctx.prof).id,
          appointment_type_id: Keyword.get(opts, :tipo, ctx.tipo).id,
          patient_ids: [paciente.id]
        },
        scope: scope
      )

    Api.Repo.with_clinic(ctx.clinic.id, fn ->
      Ash.load!(appointment, [:attendances], authorize?: false, tenant: ctx.clinic.id)
    end)
    |> elem(1)
  end

  @doc """
  Um instante UTC correspondente a `hora` local de amanhã na clínica do `ctx`.

  Amanhã e não hoje porque metade das regras da agenda olha para o relógio ("já começou", "abre
  vaga", "lembrete N horas antes"), e um teste ancorado em "hoje às 10h" muda de significado
  conforme a hora em que a suíte roda.
  """
  def amanha_as(ctx, hora) do
    amanha =
      Date.add(DateTime.to_date(DateTime.shift_zone!(DateTime.utc_now(), ctx.clinic.timezone)), 1)

    {:ok, local} = DateTime.new(amanha, Time.new!(hora, 0, 0), ctx.clinic.timezone)
    DateTime.shift_zone!(local, "Etc/UTC")
  end

  @doc """
  Um paciente com atributos escolhidos — `comunicacao`, `email`, `tel`, `nome`.

  Existe porque a fatia de comunicação (doc 52) precisa de paciente **com contato e
  consentimento** em todo teste, e a versão privada disso nasceu copiada em seis arquivos — uma
  delas já divergindo no contrato (aceitava `:nome`, as outras não). É o mesmo motivo do
  `escopo_em/2`: helper de teste copiado é helper que diverge.
  """
  def paciente_com(ctx, attrs) do
    {nome, attrs} = Map.pop(Map.new(attrs), :nome, "P#{unico()}")

    Records.update_patient!(paciente!(ctx, nome), attrs,
      tenant: ctx.clinic.id,
      actor: ctx.owner
    )
  end

  @doc "As mensagens de um agendamento, sob a GUC — a leitura que os testes da fatia 52 repetem."
  def mensagens(ctx, appt) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Messaging.list_messages_for_appointment!(appt.id,
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end

  @doc "Relê uma mensagem sob a GUC — o par de `mensagens/2` para asserção de estado."
  def recarregar_mensagem(ctx, message) do
    Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
      Api.Messaging.get_message!(message.id, tenant: ctx.clinic.id, authorize?: false)
    end)
  end

  @doc "Inteiro único no nó — a defesa contra deadlock em teste async."
  def unico, do: System.unique_integer([:positive])

  @doc """
  Um e-mail globalmente único. O prefixo é só para leitura do log de teste — a unicidade vem do
  `unico/0`.

      iex> Api.Generators.email_unico("appt") =~ ~r/^appt-\\d+@example\\.com$/
      true
  """
  def email_unico(prefixo \\ "u"), do: "#{prefixo}-#{unico()}@example.com"

  @doc """
  Sessão de verdade: pede o magic link, lê o token do e-mail que caiu na caixa de teste e troca
  por um `User` **com o token de sessão em `metadata`** — que é o que
  `AshAuthentication.Plug.Helpers.store_in_session/2` precisa.

  `register?: true` cria o usuário se ele ainda não existe, que é o caso de todo teste.
  """
  def sign_in!(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  @doc "Um usuário novo, já com sessão. O par de `usuario!/1` para quem testa a fronteira."
  def usuario_com_sessao!(prefixo \\ "u"), do: prefixo |> email_unico() |> sign_in!()

  @doc """
  Um membro **convidado por e-mail e com o convite aceito**, já com sessão.

  Vai pelo convite por e-mail (e não por `user_id`, como `escopo_de_membro!/3`) porque é o caminho
  que a fronteira exercita: o usuário nasce do convite. `professional_id` vincula o membro a uma
  coluna da agenda — sem ele, um `:profissional` não enxerga sessão nenhuma (A7).
  """
  def sessao_de_membro!(owner, clinic, papel, professional_id \\ nil),
    do: owner |> convite_aceito!(clinic, papel, professional_id) |> elem(0)

  @doc "Como `sessao_de_membro!/4`, mas devolve `{user, membership}` — para quem revoga depois."
  def convite_aceito!(owner, clinic, papel, professional_id \\ nil) do
    addr = email_unico(to_string(papel))
    attrs = %{papel: papel, clinic_id: clinic.id, professional_id: professional_id}

    {:ok, pending} = Accounts.invite_member_by_email(addr, attrs, actor: owner)
    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, membership} = Accounts.accept_invite(pending, actor: user)

    {sign_in!(addr), membership}
  end
end
