defmodule ApiWeb.ClientIpTest do
  @moduledoc """
  A ordem de confiança do `ApiWeb.ClientIp` — a decisão de segurança que decide **qual header de
  proxy merece crédito**, e da qual dependem as duas chaves por IP do sistema (o limite global e
  o anti-spam de magic link).

  Ela não tinha teste nenhum: apagar o header do topo da cadeia, ou inverter a ordem, deixava a
  suíte inteira verde (bate-volta doc 68, causa B). O que este arquivo fixa é o contrato.
  """
  use ExUnit.Case, async: true

  alias ApiWeb.ClientIp

  defp conn(headers, peer \\ {127, 0, 0, 1}) do
    Enum.reduce(headers, %Plug.Conn{remote_ip: peer}, fn {k, v}, acc ->
      Plug.Conn.put_req_header(acc, k, v)
    end)
  end

  # A cadeia confiável é configuração de deploy e o default é vazio (só `x-forwarded-for`).
  # Os testes que exercitam a PRIORIDADE precisam, portanto, declarar a edge explicitamente —
  # é assim que um ambiente com edge de verdade se configura.
  defp com_edge_confiavel(header) do
    Application.put_env(:api, :trusted_client_ip_headers, [header])
    on_exit(fn -> Application.delete_env(:api, :trusted_client_ip_headers) end)
  end

  describe "ordem de confiança" do
    test "o header confiável configurado vence o x-forwarded-for" do
      # Uma edge que SOBRESCREVE o próprio header é à prova de spoof, então tem prioridade.
      com_edge_confiavel("cf-connecting-ip")

      assert ClientIp.get(conn([{"cf-connecting-ip", "1.1.1.1"}, {"x-forwarded-for", "2.2.2.2"}])) ==
               "1.1.1.1"
    end

    test "sem o header confiável, cai no x-forwarded-for" do
      assert ClientIp.get(conn([{"x-forwarded-for", "2.2.2.2"}])) == "2.2.2.2"
    end

    test "sem header nenhum, cai no peer da conexão" do
      assert ClientIp.get(conn([], {203, 0, 113, 9})) == "203.0.113.9"
    end

    test "header vazio não engole o próximo da cadeia" do
      com_edge_confiavel("cf-connecting-ip")

      assert ClientIp.get(conn([{"cf-connecting-ip", ""}, {"x-forwarded-for", "2.2.2.2"}])) ==
               "2.2.2.2"
    end

    # Regressão (auditoria doc 96, L-4). Ler o PRIMEIRO item entregava a chave de rate limit ao
    # atacante: o primeiro é o que o cliente escreveu, e cada salto só ACRESCENTA. Bastava
    # rotacionar o header a cada request para nunca estourar o teto — inclusive no limitador
    # anti-brute-force do magic link.
    #
    # Com 1 salto confiável (Traefik sozinho, a topologia atual), o cliente é o ÚLTIMO item: é o
    # que o Traefik observou, e o único que o cliente não escolhe.
    test "x-forwarded-for com vários hops: com 1 salto confiável, o cliente é o último" do
      assert ClientIp.get(conn([{"x-forwarded-for", "2.2.2.2, 10.0.0.1, 10.0.0.2"}])) ==
               "10.0.0.2"
    end

    test "o IP forjado pelo cliente NÃO vira chave" do
      # O atacante manda o header; o Traefik anexa o que viu de verdade.
      forjado = "1.1.1.1"
      real = "203.0.113.9"

      assert ClientIp.get(conn([{"x-forwarded-for", "#{forjado}, #{real}"}])) == real
    end

    test "com 2 saltos confiáveis, o cliente é o penúltimo" do
      # Quantos descartar depende da topologia, e não dá para adivinhar — por isso é config
      # explícita, que sobe JUNTO com a entrada de uma edge nova.
      Application.put_env(:api, :trusted_proxy_hops, 2)
      on_exit(fn -> Application.delete_env(:api, :trusted_proxy_hops) end)

      assert ClientIp.get(conn([{"x-forwarded-for", "2.2.2.2, 10.0.0.1, 10.0.0.2"}])) ==
               "10.0.0.1"
    end
  end

  describe "o default acompanha a topologia real" do
    test "o default NÃO confia em `fly-client-ip` (a edge da Fly saiu)" do
      # Regressão da migração Fly→Dokploy. O default era `["fly-client-ip"]`, e nenhum ambiente
      # sobrescreve `:trusted_client_ip_headers` — então em produção, sob Traefik, quem escreve
      # esse header é o PRÓPRIO cliente: ninguém o sobrescreve nem o remove. Com ele no topo da
      # cadeia, forjar `Fly-Client-IP` a cada request dá uma chave de rate limit nova por request
      # e zera os dois limitadores (global e anti-spam do magic link), sem nada quebrar à vista.
      refute "fly-client-ip" in Application.get_env(:api, :trusted_client_ip_headers, []),
             "header de edge que não existe mais na topologia não pode ser confiável por default"

      forjado = conn([{"fly-client-ip", "1.1.1.1"}, {"x-forwarded-for", "2.2.2.2"}])
      assert ClientIp.get(forjado) == "2.2.2.2", "o header forjável não pode vencer no default"
    end
  end

  describe "a cadeia é configurável (o alvo do deploy mudou de edge)" do
    test "topologia sem a edge da Fly: o header dela deixa de ser confiável" do
      # Sob Traefik/Dokploy NINGUÉM escreve nem remove `fly-client-ip` — mantê-lo no topo da
      # cadeia entregaria a chave do limite para o cliente escrever (bate-volta doc 68, causa B).
      Application.put_env(:api, :trusted_client_ip_headers, ["x-forwarded-for"])
      on_exit(fn -> Application.delete_env(:api, :trusted_client_ip_headers) end)

      forjado = conn([{"fly-client-ip", "1.1.1.1"}, {"x-forwarded-for", "2.2.2.2"}])
      assert ClientIp.get(forjado) == "2.2.2.2", "o header não-confiável não pode vencer"
    end
  end
end
