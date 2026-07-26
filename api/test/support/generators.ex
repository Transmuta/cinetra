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
  """

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
end
