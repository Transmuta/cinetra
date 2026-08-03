defmodule Api.DeployHorizontalidadeTest do
  @moduledoc """
  A armadilha da segunda réplica (M7, doc 101 §4.5).

  O stack de produção roda **instância única** dos três serviços, e isso está registrado como
  decisão (ADR-023, `docs/04 §12`). O problema não é a decisão — é que a linha que a desfaz custa
  **cinco caracteres** (`replicas: 2` no `compose.dokploy.yml`) e não acende nada em lugar nenhum.

  ## O que quebra no dia em que a segunda réplica subir, em ordem de gravidade

  1. **O tempo real para de funcionar para metade dos usuários.** `Phoenix.PubSub` sobe com o
     adaptador PG2, cujo alcance é `Node.list()`. Sem cluster BEAM, um agendamento criado no nó A
     **nunca** chega ao assinante do canal da agenda no nó B. Ninguém vê erro: a tela simplesmente
     para de se atualizar sozinha para quem caiu no outro nó, e o suporte recebe "às vezes some";
  2. **A presença (F5) mente.** `ApiWeb.Presence` viaja pelo mesmo PubSub — "quem mais está com
     este dia aberto" passa a mostrar só quem está no mesmo nó que você;
  3. **O cache de fuso da clínica não invalida.** `Api.Accounts.ClinicTimezone` guarda em
     `:persistent_term` (por-nó) e conta com o PubSub para avisar os outros — sem cluster, trocar
     o fuso corrige um nó e deixa o outro com o antigo até o próximo deploy;
  4. **Os limites de taxa dobram.** `Api.RateLimiter` e `Api.RateLimiter.Global` são Hammer/ETS,
     tabela por-nó; e o rate limit do `POST /api/client-error` do BFF é um `Map` na memória do
     processo. Com N réplicas o teto vira N × o teto — que é o item que o plano nomeou.

  **Os três primeiros falham calados**, e o primeiro é o mais caro do sistema. É por isso que este
  teste existe: o `DNS_CLUSTER_QUERY` já é lido pelo `runtime.exs` (e o `DNSCluster` já está na
  árvore de supervisão), mas **não é passado por nenhum compose**. A infraestrutura de cluster está
  pronta e desligada, o que é exatamente a configuração em que a armadilha é invisível.

  ## O que este teste NÃO faz

  Não impede réplicas, e não é essa a intenção: quando o volume pedir, a resposta é ligar o
  cluster e trocar os limitadores. O que ele impede é a réplica entrar **sozinha** — e a mensagem
  de falha é a lista acima, para que quem esbarrar nele saiba o que mais tem de mudar.
  """

  use ExUnit.Case, async: true

  alias Api.ComposeDeProducao, as: Compose

  @servicos ~w(db api web)

  setup_all do
    {:ok, compose: Compose.ler()}
  end

  # Anti-vacuidade: sem isto, renomear os serviços (ou o arquivo mudar de forma) faria todo o resto
  # deste módulo passar sem ter olhado nada — o mesmo modo de falha que o `servico/2` guarda por
  # dentro, mas visível como um teste próprio.
  test "o compose de produção ainda descreve os três serviços", %{compose: compose} do
    for nome <- @servicos, do: assert(length(Compose.servico(compose, nome)) > 10)
  end

  test "a API não sobe com réplica sem cluster BEAM", %{compose: compose} do
    api = Compose.servico(compose, "api")

    if Compose.replicas(api) > 1 do
      assert Enum.any?(api, &Regex.match?(~r/^\s+DNS_CLUSTER_QUERY:/, &1)),
             """
             O serviço `api` declara mais de uma réplica e não passa `DNS_CLUSTER_QUERY`.

             Sem cluster BEAM o `Phoenix.PubSub` não atravessa nós: um agendamento criado num nó \
             NUNCA chega ao assinante do canal da agenda no outro. Não há erro, log nem métrica — \
             a agenda apenas para de se atualizar sozinha para metade dos usuários.

             Junto com isso: a presença (F5) passa a mostrar só quem caiu no mesmo nó, e o cache \
             de fuso do `Api.Accounts.ClinicTimezone` deixa de invalidar entre nós.

             Ver o moduledoc deste arquivo para a lista inteira, e `docs/101 §4.5` para a medida \
             que justificou não ter migrado os limitadores antes da hora.
             """
    end
  end

  test "os limitadores por-nó não sobrevivem à segunda réplica", %{compose: compose} do
    api = Compose.replicas(Compose.servico(compose, "api"))
    web = Compose.replicas(Compose.servico(compose, "web"))

    assert api == 1 and web == 1,
           """
           Um serviço passou a ter mais de uma réplica (api: #{api}, web: #{web}) e os limitadores \
           de taxa continuam por-nó:

             * `Api.RateLimiter` e `Api.RateLimiter.Global` são Hammer/ETS — tabela por processo \
           BEAM, então o teto real vira N × o configurado;
             * o rate limit do `POST /api/client-error` (`web/src/routes/api/client-error/+server.ts`) \
           é um `Map` na memória do processo do adapter-node, com o mesmo efeito.

           O plano (doc 101, onda 4) pede as três mudanças JUNTAS — os dois limitadores e as \
           réplicas —, porque meia migração cria a ilusão do teto. Se a réplica é intencional, \
           mude os limitadores no mesmo PR e ajuste este teste com o número novo.
           """
  end
end
