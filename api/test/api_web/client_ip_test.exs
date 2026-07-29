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

  describe "ordem de confiança" do
    test "o header confiável configurado vence o x-forwarded-for" do
      # Na Fly a edge SOBRESCREVE `fly-client-ip`, então ele é à prova de spoof e tem prioridade.
      assert ClientIp.get(conn([{"fly-client-ip", "1.1.1.1"}, {"x-forwarded-for", "2.2.2.2"}])) ==
               "1.1.1.1"
    end

    test "sem o header confiável, cai no x-forwarded-for" do
      assert ClientIp.get(conn([{"x-forwarded-for", "2.2.2.2"}])) == "2.2.2.2"
    end

    test "sem header nenhum, cai no peer da conexão" do
      assert ClientIp.get(conn([], {203, 0, 113, 9})) == "203.0.113.9"
    end

    test "header vazio não engole o próximo da cadeia" do
      assert ClientIp.get(conn([{"fly-client-ip", ""}, {"x-forwarded-for", "2.2.2.2"}])) ==
               "2.2.2.2"
    end

    test "x-forwarded-for com vários hops usa o primeiro (o cliente)" do
      assert ClientIp.get(conn([{"x-forwarded-for", "2.2.2.2, 10.0.0.1, 10.0.0.2"}])) == "2.2.2.2"
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
