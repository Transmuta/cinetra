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

  @doc "Mais um profissional na clínica do `ctx`."
  def profissional!(ctx, nome \\ "Dr. Y"),
    do: Directory.create_professional!(nome, %{}, tenant: ctx.clinic.id, actor: ctx.owner)

  @doc "Mais um paciente na clínica do `ctx`."
  def paciente!(ctx, nome \\ "Paciente"),
    do: Records.create_patient!(nome, %{}, tenant: ctx.clinic.id, actor: ctx.owner)

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
